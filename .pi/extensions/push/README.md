# Pi `/push` extension

Adds a `/push` slash command for Pi that runs the full publish workflow
end‑to‑end through Pi's built‑in `bash` tool.

When invoked, `/push` injects the user message:

> Please run the full /push workflow (add → commit → push → wait CI → release).

It then switches to a synthetic internal model that emits a single `bash` tool
call. The bash tool result is recorded normally in the conversation.

## Workflow

The bash script logs `=== N/8 ... ===` banners so failure messages clearly say
which step broke.

1. **Check branch** — verify Git worktree, GitHub `origin`, and that `HEAD` is
   on a named branch (refuses detached HEAD).
2. **`git add -A`** — stage everything.
3. **Generate commit message** — heuristic conventional‑commit subject derived
   from `git diff --cached --name-status` (chooses `feat`/`fix`/`docs`/
   `test`/`chore` based on file types) plus an Added/Modified/Deleted/Renamed
   body. Skipped if nothing is staged.
4. **`git commit`** — commit the staged changes via `git commit -F -`. Skipped
   if the worktree was already clean.
5. **`git push origin HEAD:<current-branch>`** — never force‑pushes, never
   forces a different target branch.
6. **Wait for GitHub Actions** — uses `gh run list --commit <sha>` to find the
   runs triggered by the push, then `gh run watch --exit-status` on each. If
   any run fails, the script prints failing logs and aborts before creating
   any release. Skipped (with a warning) if `gh` is missing/unauthenticated
   or the repo has no `.github/workflows/`.
7. **Build release asset** — resolves the version from `_meta.lua`, then
   `package.json`, then a timestamp fallback. For KOReader‑style Lua plugins
   (`_meta.lua` + `main.lua`) it builds `<plugin>-<version>-<sha>.zip` from
   the tracked top‑level Lua files plus `askgpt/` and includes the SHA256 in
   the release notes. Refuses to overwrite an existing release tag.
8. **Create the GitHub release** — `gh release create <tag> [asset] --target
   <current-branch> --title <tag> --notes-file …` and prints the release URL.

## On failure

If the bash tool exits non‑zero the extension:

- restores the previously selected model and thinking level;
- restores the previous active tool set;
- sends the captured bash output back to the real model as a follow‑up,
  asking it to identify which step failed (using the `=== N/8 ===` banners),
  explain the likely cause, and suggest next steps — without re‑running
  commands unless the user asks.

## Safety notes

- pushes only to the current branch on `origin` (`HEAD:<branch>`);
- never runs `--force` / `--force-with-lease`;
- never rewrites history;
- skips the commit step if the worktree is clean (no empty commits);
- aborts the release if any GitHub Actions run for the pushed commit fails;
- refuses to overwrite an existing release tag;
- the bash call uses a 1800s timeout so CI has time to finish.
