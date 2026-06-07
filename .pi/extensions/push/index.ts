import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import {
	createAssistantMessageEventStream,
	type Api,
	type AssistantMessage,
	type AssistantMessageEventStream,
	type Context,
	type Model,
	type SimpleStreamOptions,
} from "@mariozechner/pi-ai";

const PROVIDER = "pi-push-extension";
const MODEL_ID = "push-command-runner";
const USER_MESSAGE = "Please run the full /push workflow (add → commit → push → wait CI → release).";

// /push runs an end-to-end publish workflow:
//   1. Check current branch (refuse detached HEAD).
//   2. git add -A.
//   3. Generate a conventional commit message from the staged diff.
//   4. git commit (skip if nothing staged).
//   5. git push origin HEAD:<branch>.
//   6. Wait for GitHub Actions runs triggered by the push (gh run watch); abort on failure.
//   7. Auto-bump patch version (方案 A): fetch tags, derive the next unused
//      version from the latest semver git tag/release, write it into
//      _meta.lua / package.json, commit & push, then wait for CI on the bump
//      commit. If HEAD is already pointed to by a semver tag that already has
//      a GitHub release (no new commits since last release), skip steps 8-9
//      gracefully instead of erroring (方案 C).
//   8. Build the release asset (KOReader-style zip when applicable) and create
//      a GitHub release for the new HEAD.
//   9. Wait for release-triggered GitHub Actions runs (event=release) to finish; abort on failure.
//
// Executed through Pi's normal built-in bash tool pipeline. On any failure the
// extension restores the user's selected model and asks it to explain the failure.
const PUSH_COMMAND = String.raw`set -euo pipefail

step() { printf '\n=== %s ===\n' "$*"; }

step "1/9 Check git worktree and current branch"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Error: not inside a Git worktree." >&2
  exit 1
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"
if [ -z "$REMOTE_URL" ]; then
  echo "Error: no origin remote configured." >&2
  exit 1
fi
case "$REMOTE_URL" in
  *github.com*) ;;
  *)
    echo "Error: origin does not appear to be a GitHub remote: $REMOTE_URL" >&2
    exit 1
    ;;
esac

BRANCH="$(git branch --show-current || true)"
if [ -z "$BRANCH" ]; then
  echo "Error: detached HEAD. Checkout a branch before /push." >&2
  exit 1
fi
echo "Worktree: $ROOT"
echo "Origin:   $REMOTE_URL"
echo "Branch:   $BRANCH"

step "2/9 git add -A"
git add -A
echo "Status after add:"
git status --short || true

step "3/9 Generate commit message"
# Detect whether we actually have staged changes.
if git diff --cached --quiet; then
  HAS_STAGED=0
else
  HAS_STAGED=1
fi

COMMIT_MSG=""
if [ "$HAS_STAGED" = "1" ]; then
  COMMIT_MSG="$(python3 - <<'PY'
import os
import subprocess

name_status = subprocess.check_output(
    ["git", "diff", "--cached", "--name-status"], text=True
).strip().splitlines()

added, modified, deleted, renamed = [], [], [], []
for line in name_status:
    parts = line.split("\t")
    if not parts:
        continue
    code = parts[0]
    if code.startswith("R") and len(parts) >= 3:
        renamed.append((parts[1], parts[2]))
    elif code.startswith("A") and len(parts) >= 2:
        added.append(parts[1])
    elif code.startswith("D") and len(parts) >= 2:
        deleted.append(parts[1])
    elif code.startswith("M") and len(parts) >= 2:
        modified.append(parts[1])
    elif len(parts) >= 2:
        modified.append(parts[1])

all_paths = (
    added
    + modified
    + deleted
    + [new for _, new in renamed]
)

def classify(paths):
    if not paths:
        return "chore"
    exts = {os.path.splitext(p)[1].lower() for p in paths}
    if exts <= {".md", ".rst", ".txt"}:
        return "docs"
    if all("test" in p.lower() or "spec" in p.lower() for p in paths):
        return "test"
    if exts <= {".yml", ".yaml", ".toml", ".json", ".ini", ".cfg"} or all(
        p.startswith(".github/") for p in paths
    ):
        return "chore"
    if exts <= {".lua", ".ts", ".tsx", ".js", ".jsx", ".py", ".go", ".rs"}:
        if added and not modified and not deleted:
            return "feat"
        if deleted and not modified and not added:
            return "chore"
        return "fix" if not added else "feat"
    return "chore"

prefix = classify(all_paths)

display = []
for p in all_paths[:3]:
    display.append(os.path.basename(p) or p)
extra = len(all_paths) - len(display)
summary = ", ".join(display)
if extra > 0:
    summary += f" (+{extra} more)"
if not summary:
    summary = "update repository"

subject = f"{prefix}: {summary}"
if len(subject) > 72:
    subject = subject[:69] + "..."

lines = [subject, ""]
if added:
    lines.append("Added:")
    lines += [f"  - {p}" for p in added]
if modified:
    lines.append("Modified:")
    lines += [f"  - {p}" for p in modified]
if deleted:
    lines.append("Deleted:")
    lines += [f"  - {p}" for p in deleted]
if renamed:
    lines.append("Renamed:")
    lines += [f"  - {old} -> {new}" for old, new in renamed]

print("\n".join(lines).rstrip())
PY
)"
  echo "Commit message:"
  printf '%s\n' "$COMMIT_MSG" | sed 's/^/  | /'
else
  echo "No staged changes; will skip git commit."
fi

step "4/9 git commit"
if [ "$HAS_STAGED" = "1" ]; then
  printf '%s\n' "$COMMIT_MSG" | git commit -F -
else
  echo "Skipped (working tree clean)."
fi

step "5/9 git push origin HEAD:$BRANCH"
git push origin "HEAD:$BRANCH"
COMMIT_FULL="$(git rev-parse HEAD)"
COMMIT_SHORT="$(git rev-parse --short HEAD)"
echo "Pushed commit: $COMMIT_FULL"

step "6/9 Wait for GitHub Actions"
if ! command -v gh >/dev/null 2>&1; then
  echo "Warning: GitHub CLI (gh) not installed; skipping Actions wait." >&2
  SKIP_CI=1
elif ! gh auth status >/dev/null 2>&1; then
  echo "Warning: gh is not authenticated; skipping Actions wait." >&2
  SKIP_CI=1
elif [ ! -d .github/workflows ] || [ -z "$(ls -A .github/workflows 2>/dev/null)" ]; then
  echo "No .github/workflows present; skipping Actions wait."
  SKIP_CI=1
else
  SKIP_CI=0
fi

if [ "$SKIP_CI" != "1" ]; then
  echo "Looking up workflow runs for $COMMIT_SHORT..."
  RUN_IDS=""
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    RUN_IDS="$(gh run list --branch "$BRANCH" --commit "$COMMIT_FULL" --limit 20 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)"
    if [ -n "$RUN_IDS" ]; then
      break
    fi
    echo "  (attempt $attempt) no runs yet, sleeping 3s..."
    sleep 3
  done

  if [ -z "$RUN_IDS" ]; then
    echo "Warning: no Actions runs detected for this commit after waiting; continuing." >&2
  else
    CI_FAILED=0
    for RID in $RUN_IDS; do
      echo "Watching run $RID..."
      if ! gh run watch "$RID" --exit-status --interval 5; then
        echo "Error: GitHub Actions run $RID failed." >&2
        gh run view "$RID" --log-failed || true
        CI_FAILED=1
      fi
    done
    if [ "$CI_FAILED" = "1" ]; then
      echo "Error: at least one GitHub Actions run failed; aborting release." >&2
      exit 1
    fi
    echo "All Actions runs succeeded."
  fi
fi

step "7/9 Auto-bump version & determine release"
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is required to create the release." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: GitHub CLI is not authenticated. Run: gh auth login" >&2
  exit 1
fi

# Ensure local semver tags reflect GitHub before deciding what is already
# released. This prevents stale local tags from reusing an existing release
# version (e.g. local latest v1.7.10 while GitHub already has v1.7.11).
echo "Fetching tags from origin..."
git fetch --tags origin >/dev/null 2>&1 || true

# ── 方案 C ──────────────────────────────────────────────────────────────────
# If HEAD is already pointed to by a semver tag that already has a GitHub
# release, there are no new commits since the last release → skip gracefully.
SKIP_RELEASE=0
TAG=""
RELEASE_VERSION=""
RELEASE_START_TS=""
HEAD_SEMVER_TAGS="$(git tag --points-at HEAD | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)"
if [ -n "$HEAD_SEMVER_TAGS" ]; then
  for HT in $HEAD_SEMVER_TAGS; do
    if gh release view "$HT" >/dev/null 2>&1; then
      echo "HEAD is already released as $HT with no new commits since."
      echo "Nothing new to release — skipping steps 8 and 9."
      TAG="$HT"
      SKIP_RELEASE=1
      break
    fi
  done
fi

if [ "$SKIP_RELEASE" = "0" ]; then
  # ── 方案 A ──────────────────────────────────────────────────────────────────
  # Compute the next patch version from the latest semver git tag, write it
  # into _meta.lua / package.json, and commit + push the bump.
  LATEST_TAG="$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"

  if [ -z "$LATEST_TAG" ]; then
    # No semver tags yet — seed from _meta.lua / package.json, or default.
    SEED=""
    if [ -f _meta.lua ]; then
      SEED="$(sed -nE 's/.*version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' _meta.lua | head -1 || true)"
    fi
    if [ -z "$SEED" ] && [ -f package.json ]; then
      SEED="$(python3 -c "import json; print(json.load(open('package.json')).get('version',''))" 2>/dev/null || true)"
    fi
    if [ -n "$SEED" ]; then
      LATEST_TAG="v$SEED"
    else
      LATEST_TAG="v0.0.0"
    fi
    echo "No previous semver tag found; seeding from: $LATEST_TAG"
  else
    echo "Latest semver tag: $LATEST_TAG"
  fi

  # Bump patch: v1.7.11 → v1.7.12
  RELEASE_VERSION="$(python3 - "$LATEST_TAG" <<'PY'
import sys, re
tag = sys.argv[1].lstrip("v")
m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(.*)', tag)
if not m:
    sys.exit(f"Cannot parse semver from tag: {sys.argv[1]}")
major, minor, patch, rest = m.groups()
print(f"{major}.{minor}.{int(patch) + 1}{rest}")
PY
)"
  TAG="v$RELEASE_VERSION"

  # Safety net: if the computed tag already exists locally/remotely or already
  # has a GitHub release, keep bumping patch until a free version is found.
  while gh release view "$TAG" >/dev/null 2>&1 || git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; do
    echo "Candidate $TAG already exists; bumping patch again."
    RELEASE_VERSION="$(python3 - "$TAG" <<'PY'
import sys, re
tag = sys.argv[1].lstrip("v")
m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(.*)', tag)
if not m:
    sys.exit(f"Cannot parse semver from tag: {sys.argv[1]}")
major, minor, patch, rest = m.groups()
print(f"{major}.{minor}.{int(patch) + 1}{rest}")
PY
)"
    TAG="v$RELEASE_VERSION"
  done
  echo "New release:        $TAG"

  # Write new version into _meta.lua (KOReader plugin manifest).
  if [ -f _meta.lua ]; then
    sed -i -E "s/(version[[:space:]]*=[[:space:]]*\")[^\"]*(\")/\\1$RELEASE_VERSION\\2/" _meta.lua
    echo "Updated _meta.lua → version = \"$RELEASE_VERSION\""
  fi

  # Write new version into package.json if present.
  if [ -f package.json ]; then
    python3 - "$RELEASE_VERSION" <<'PY'
import json, sys
path = 'package.json'
data = json.load(open(path))
data['version'] = sys.argv[1]
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PY
    echo "Updated package.json → version: \"$RELEASE_VERSION\""
  fi

  # Commit & push the version bump (only if files actually changed).
  git add -A
  if git diff --cached --quiet; then
    echo "Version file(s) unchanged (version managed elsewhere); no bump commit."
  else
    git commit -m "chore: bump version to $TAG"
    git push origin "HEAD:$BRANCH"
    COMMIT_FULL="$(git rev-parse HEAD)"
    COMMIT_SHORT="$(git rev-parse --short HEAD)"
    echo "Pushed bump commit: $COMMIT_FULL"

    if [ "$SKIP_CI" != "1" ]; then
      echo "Waiting for GitHub Actions on bump commit $COMMIT_SHORT..."
      RUN_IDS=""
      for attempt in 1 2 3 4 5 6 7 8 9 10; do
        RUN_IDS="$(gh run list --branch "$BRANCH" --commit "$COMMIT_FULL" --limit 20 --json databaseId --jq '.[].databaseId' 2>/dev/null || true)"
        if [ -n "$RUN_IDS" ]; then
          break
        fi
        echo "  (attempt $attempt) no bump commit runs yet, sleeping 3s..."
        sleep 3
      done

      if [ -z "$RUN_IDS" ]; then
        echo "Warning: no Actions runs detected for bump commit after waiting; continuing." >&2
      else
        CI_FAILED=0
        for RID in $RUN_IDS; do
          echo "Watching bump commit run $RID..."
          if ! gh run watch "$RID" --exit-status --interval 5; then
            echo "Error: GitHub Actions run $RID failed on bump commit." >&2
            gh run view "$RID" --log-failed || true
            CI_FAILED=1
          fi
        done
        if [ "$CI_FAILED" = "1" ]; then
          echo "Error: at least one bump commit GitHub Actions run failed; aborting release." >&2
          exit 1
        fi
        echo "All bump commit Actions runs succeeded."
      fi
    fi
  fi
fi

step "8/9 Build & publish release"
if [ "$SKIP_RELEASE" = "1" ]; then
  echo "Skipped (no new commits since $TAG)."
else
  TMP_DIR="$(mktemp -d)"
  cleanup_release_tmp() { rm -rf "$TMP_DIR"; }
  trap cleanup_release_tmp EXIT

  NOTES_PATH="$TMP_DIR/release-notes.md"
  ASSET_PATH=""
  ASSET_SHA=""

  if [ -f _meta.lua ] && [ -f main.lua ]; then
    if ! command -v python3 >/dev/null 2>&1; then
      echo "Error: python3 is required to build the KOReader plugin release zip." >&2
      exit 1
    fi
    PLUGIN_NAME="$(basename "$ROOT")"
    ASSET_NAME="$PLUGIN_NAME-$RELEASE_VERSION-$COMMIT_SHORT.zip"
    ASSET_PATH="$TMP_DIR/$ASSET_NAME"

    echo "Building release asset: $ASSET_NAME"
    python3 - "$ASSET_PATH" "$PLUGIN_NAME" <<'PY'
import pathlib
import subprocess
import sys
import zipfile

out = pathlib.Path(sys.argv[1])
plugin_name = sys.argv[2]
tracked = subprocess.check_output(['git', 'ls-files'], text=True).splitlines()
files = []
for name in tracked:
    path = pathlib.PurePosixPath(name)
    if not name.endswith('.lua'):
        continue
    if len(path.parts) == 1 or path.parts[0] == 'caudex':
        files.append(name)
if not files:
    raise SystemExit('No plugin Lua files found for release asset')
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED) as z:
    for name in sorted(files):
        z.write(name, f'{plugin_name}/{name}')
PY

    ASSET_SHA="$(sha256sum "$ASSET_PATH" | awk '{print $1}')"
    cat > "$NOTES_PATH" <<EOF
Automated release for commit $COMMIT_FULL.

## Asset SHA256

\`\`\`
$ASSET_SHA  $ASSET_NAME
\`\`\`
EOF
  else
    ASSET_NAME=""
    cat > "$NOTES_PATH" <<EOF
Automated release for commit $COMMIT_FULL.
EOF
  fi

  # Record timestamp so step 9 can filter release-triggered runs precisely.
  RELEASE_START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$ASSET_PATH" ]; then
    echo "Creating release $TAG with asset $ASSET_NAME..."
    gh release create "$TAG" "$ASSET_PATH" --target "$BRANCH" --title "$TAG" --notes-file "$NOTES_PATH"
  else
    echo "Creating release $TAG (no asset)..."
    gh release create "$TAG" --target "$BRANCH" --title "$TAG" --notes-file "$NOTES_PATH"
  fi

  RELEASE_URL="$(gh release view "$TAG" --json url --jq .url 2>/dev/null || true)"
  if [ -n "$RELEASE_URL" ]; then
    echo "Release created: $RELEASE_URL"
  else
    echo "Release created: $TAG"
  fi
fi

step "9/9 Wait for release-triggered workflows"
# Release-triggered runs (event=release) are scheduled by GitHub after
# gh release create returns. They share the same head_sha as the pushed
# commit but use event=release, so we can filter precisely. Runs created
# before RELEASE_START_TS belong to earlier releases of the same commit and
# are ignored.
if [ "$SKIP_RELEASE" = "1" ]; then
  echo "Skipped (no release was created)."
elif ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "gh unavailable; skipping release CI wait."
elif [ ! -d .github/workflows ] || [ -z "$(ls -A .github/workflows 2>/dev/null)" ]; then
  echo "No .github/workflows present; skipping release CI wait."
else
  echo "Looking up release-triggered runs for $COMMIT_SHORT (>= $RELEASE_START_TS)..."
  RELEASE_RUN_IDS=""
  # ~90s discovery window: release runs usually appear within 5-15s.
  for attempt in $(seq 1 30); do
    RELEASE_RUN_IDS="$(gh run list \
        --commit "$COMMIT_FULL" \
        --event release \
        --limit 20 \
        --json databaseId,createdAt \
        --jq ".[] | select(.createdAt >= \"$RELEASE_START_TS\") | .databaseId" \
        2>/dev/null || true)"
    if [ -n "$RELEASE_RUN_IDS" ]; then
      break
    fi
    echo "  (attempt $attempt) no release runs yet, sleeping 3s..."
    sleep 3
  done

  if [ -z "$RELEASE_RUN_IDS" ]; then
    echo "No release-triggered runs detected within 90s; assuming none configured."
  else
    CI_FAILED=0
    for RID in $RELEASE_RUN_IDS; do
      echo "Watching release run $RID..."
      if ! timeout 1800 gh run watch "$RID" --exit-status --interval 5; then
        echo "Error: release-triggered workflow run $RID failed or timed out." >&2
        gh run view "$RID" --log-failed || true
        CI_FAILED=1
      fi
    done
    if [ "$CI_FAILED" = "1" ]; then
      echo "Error: at least one release-triggered workflow failed." >&2
      exit 1
    fi
    echo "All release-triggered runs succeeded."
  fi
fi

echo "Exit code: 0"`;

type RunState = {
	toolCallId: string;
	restoreModel?: Model<any>;
	restoreThinkingLevel: ReturnType<ExtensionAPI["getThinkingLevel"]>;
	restoreTools: string[];
	failureOutput?: string;
};

function createAssistant(model: Model<Api>, stopReason: AssistantMessage["stopReason"]): AssistantMessage {
	return {
		role: "assistant",
		content: [],
		api: model.api,
		provider: model.provider,
		model: model.id,
		usage: {
			input: 0,
			output: 0,
			cacheRead: 0,
			cacheWrite: 0,
			totalTokens: 0,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
		},
		stopReason,
		timestamp: Date.now(),
	};
}

function textFromContent(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.map((block) => {
			if (block && typeof block === "object" && (block as any).type === "text") {
				return String((block as any).text ?? "");
			}
			return "";
		})
		.join("\n")
		.trim();
}

function findRunToolResult(context: Context, toolCallId: string): any | undefined {
	for (let i = context.messages.length - 1; i >= 0; i--) {
		const message = context.messages[i] as any;
		if (message?.role === "toolResult" && message.toolCallId === toolCallId) {
			return message;
		}
	}
	return undefined;
}

function streamText(model: Model<Api>, text: string): AssistantMessageEventStream {
	const stream = createAssistantMessageEventStream();
	const output = createAssistant(model, "stop");
	output.content.push({ type: "text", text });

	queueMicrotask(() => {
		stream.push({ type: "start", partial: output });
		stream.push({ type: "text_start", contentIndex: 0, partial: output });
		stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial: output });
		stream.push({ type: "text_end", contentIndex: 0, content: text, partial: output });
		stream.push({ type: "done", reason: "stop", message: output });
		stream.end();
	});

	return stream;
}

function streamPushToolCall(model: Model<Api>, toolCallId: string): AssistantMessageEventStream {
	const stream = createAssistantMessageEventStream();
	const output = createAssistant(model, "toolUse");
	const toolCall = {
		type: "toolCall" as const,
		id: toolCallId,
		name: "bash",
		arguments: {},
	};
	output.content.push(toolCall);

	queueMicrotask(() => {
		stream.push({ type: "start", partial: output });
		stream.push({ type: "toolcall_start", contentIndex: 0, partial: output });
		// CI wait can take a while; give the bash tool plenty of time.
		const args = { command: PUSH_COMMAND, timeout: 1800 };
		toolCall.arguments = args;
		stream.push({ type: "toolcall_delta", contentIndex: 0, delta: JSON.stringify(args), partial: output });
		stream.push({ type: "toolcall_end", contentIndex: 0, toolCall, partial: output });
		stream.push({ type: "done", reason: "toolUse", message: output });
		stream.end();
	});

	return stream;
}

function failureAdvicePrompt(output: string): string {
	return `The /push extension failed during the add → commit → push → CI → release workflow.

Please read the recorded bash output below, identify which step failed (the script logs "=== N/9 ... ===" banners), explain the likely cause, and give concise, actionable next steps for the user. Do not rerun any commands unless the user asks.

Bash output:
\`\`\`
${output || "(no output captured)"}
\`\`\``;
}

export default function pushExtension(pi: ExtensionAPI) {
	let activeRun: RunState | undefined;

	pi.registerProvider(PROVIDER, {
		baseUrl: "http://localhost/pi-push-extension",
		apiKey: "pi-push-extension-local",
		api: "pi-push-extension-api",
		models: [
			{
				id: MODEL_ID,
				name: "Pi /push Command Runner",
				reasoning: false,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 8192,
				maxTokens: 1024,
			},
		],
		streamSimple(model, context, _options?: SimpleStreamOptions) {
			if (!activeRun) {
				return streamText(model, "This synthetic model is only used internally by the /push command.");
			}

			const toolResult = findRunToolResult(context, activeRun.toolCallId);
			if (!toolResult) {
				return streamPushToolCall(model, activeRun.toolCallId);
			}

			const output = textFromContent(toolResult.content);
			if (toolResult.isError) {
				activeRun.failureOutput = output;
				const suffix = output ? " The bash output is in the tool result above." : "";
				return streamText(
					model,
					`/push failed.${suffix} I will restore your selected model and ask it to diagnose the failure. No force push was attempted.`,
				);
			}

			const suffix = output ? " The bash output is in the tool result above." : "";
			return streamText(
				model,
				`/push completed: staged → committed as needed → pushed → CI checked/skipped → release created or skipped if HEAD was already released → release CI checked/skipped.${suffix} Push used \`git push origin HEAD:<branch>\` (no force push).`,
			);
		},
	});

	pi.registerCommand("push", {
		description: "Add, commit, push current branch, wait for CI, then build & publish a GitHub release",
		handler: async (_args, ctx) => {
			if (!ctx.isIdle()) {
				ctx.ui.notify("/push can only start when Pi is idle.", "warning");
				return;
			}
			if (activeRun) {
				ctx.ui.notify("/push is already running.", "warning");
				return;
			}
			if (!ctx.model) {
				ctx.ui.notify("Select a model before /push so Pi can restore it afterward.", "warning");
				return;
			}

			const syntheticModel = ctx.modelRegistry.find(PROVIDER, MODEL_ID);
			if (!syntheticModel) {
				ctx.ui.notify("/push synthetic provider was not registered. Try /reload.", "error");
				return;
			}

			const previousTools = pi.getActiveTools();
			if (!previousTools.includes("bash")) {
				pi.setActiveTools([...previousTools, "bash"]);
				if (!pi.getActiveTools().includes("bash")) {
					pi.setActiveTools(previousTools);
					ctx.ui.notify("/push requires the built-in bash tool, but it is not available.", "error");
					return;
				}
			}

			activeRun = {
				toolCallId: `push-${Date.now().toString(36)}`,
				restoreModel: ctx.model,
				restoreThinkingLevel: pi.getThinkingLevel(),
				restoreTools: previousTools,
			};

			const switched = await pi.setModel(syntheticModel);
			if (!switched) {
				pi.setActiveTools(previousTools);
				activeRun = undefined;
				ctx.ui.notify("/push could not switch to its synthetic command runner.", "error");
				return;
			}

			pi.sendUserMessage(USER_MESSAGE);
		},
	});

	pi.on("agent_end", async () => {
		if (!activeRun) return;

		const run = activeRun;
		activeRun = undefined;
		pi.setActiveTools(run.restoreTools);

		if (run.restoreModel) {
			await pi.setModel(run.restoreModel);
			pi.setThinkingLevel(run.restoreThinkingLevel);
		}

		if (run.failureOutput !== undefined) {
			pi.sendUserMessage(failureAdvicePrompt(run.failureOutput), { deliverAs: "followUp" });
		}
	});
}
