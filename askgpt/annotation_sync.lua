-- Web highlight ↔ KOReader native annotation sync (Phase 1–3)
--
-- Phase 1: find text, write annotation.
-- Phase 2: improved candidate scoring (prefix/suffix/chapter/progression),
--          structured conflict reporting, short-text conservatism.
-- Phase 3: bidirectional sync — push local note/color changes back to
--          book-aware; apply tombstones both ways (reader-web deletes pulled,
--          KOReader deletes pushed via delete_highlight_only).
--
-- Scoring breakdown (max 120 pts):
--   (a) prefix similarity:       0–40 pts
--   (b) suffix similarity:       0–40 pts
--   (c) chapter match/proximity: 0–20 pts  (new in Phase 2)
--   (d) progression proximity:   0–20 pts  (improved: estimates from XPointer)
--
-- Disambiguation:
--   Single candidate → always resolved.
--   Multiple candidates → requires best_score >= MIN_SCORE AND margin >= threshold.
--   Short text (< SHORT_TEXT_CHARS chars OR < SHORT_TEXT_WORDS words) uses
--   SHORT_MARGIN instead of MIN_MARGIN (more conservative).

local AiClient = require("askgpt.ai_client")
local Util     = require("askgpt.util")
local logger   = require("logger")

local AnnotationSync = {}

local PENDING_DELETES_SETTING = "bookaware_pending_deletes"

-- ── color mapping ─────────────────────────────────────────────────────────

-- Maps book-aware colors to KOReader annotation colors.
-- Shared set: yellow, green, blue, red, purple, gray.
-- gray = KOReader e-ink default (saved_color = "gray" on non-color screens).
local COLOR_MAP = {
  yellow = "yellow",
  green  = "green",
  blue   = "blue",
  red    = "red",
  purple = "purple",
  gray   = "gray",
}

-- ── Phase 2 disambiguation constants ──────────────────────────────────────

local MIN_SCORE        = 10   -- multi-candidate: best must clear this floor
local MIN_MARGIN       = 15   -- multi-candidate: gap required for normal text
local SHORT_TEXT_CHARS = 8    -- exact text shorter than this is "short"
local SHORT_TEXT_WORDS = 3    -- or fewer words → short
local SHORT_MARGIN     = 45   -- short text needs a larger gap to auto-resolve

-- ── text helpers ──────────────────────────────────────────────────────────

-- True if exact text is short enough to warrant conservative disambiguation.
local function is_short_text(exact)
  if #exact < SHORT_TEXT_CHARS then return true end
  local words = 0
  for _ in exact:gmatch("%S+") do
    words = words + 1
    if words >= SHORT_TEXT_WORDS then return false end
  end
  return true
end

-- Shared-substring n-gram similarity between two strings, 0–1.
local function text_similarity(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return 0 end
  a = a:lower():sub(1, 300)
  b = b:lower():sub(1, 300)
  if a == "" or b == "" then return 0 end
  if a == b then return 1.0 end
  local la = #a
  local step = math.max(2, math.floor(math.min(la, #b) / 25))
  local hits, total = 0, 0
  for i = 1, la - step + 1, step do
    local chunk = a:sub(i, i + step - 1)
    if b:find(chunk, 1, true) then hits = hits + 1 end
    total = total + 1
  end
  return total > 0 and (hits / total) or 0
end

-- Estimate total-publication progression (0-1) from an XPointer.
local function estimate_progression(ui, xp)
  local ok_p, page = pcall(function() return ui.document:getPageFromXPointer(xp) end)
  if not ok_p or not page then return nil end
  local ok_c, count = pcall(function() return ui.document:getPageCount() end)
  if not ok_c or not count or count == 0 then return nil end
  return (page - 1) / count
end

-- Resolve the TOC chapter title for an XPointer position.
local function get_chapter_for_xpointer(ui, xp)
  if not ui.toc then return nil end
  local ok_p, page = pcall(function() return ui.document:getPageFromXPointer(xp) end)
  if not ok_p or not page then return nil end
  local ok1, t = pcall(function() return ui.toc:getTocTitleByPage(page) end)
  if ok1 and type(t) == "string" and t ~= "" then return t end
  local ok2, ft = pcall(function() return ui.toc:getFullTocTitleByPage(page) end)
  if ok2 and type(ft) == "string" and ft ~= "" then return ft end
  return nil
end

-- ── Phase 2 candidate scoring ─────────────────────────────────────────────

local function score_candidate(ui, candidate, hl)
  local score = 0

  -- (a) prefix similarity: 0–40 pts
  if type(hl.prefix) == "string" and hl.prefix ~= ""
      and type(candidate.prev_text) == "string" then
    score = score + text_similarity(candidate.prev_text, hl.prefix) * 40
  end

  -- (b) suffix similarity: 0–40 pts
  if type(hl.suffix) == "string" and hl.suffix ~= ""
      and type(candidate.next_text) == "string" then
    score = score + text_similarity(candidate.next_text, hl.suffix) * 40
  end

  -- (c) chapter match: 0–20 pts
  if type(hl.chapter) == "string" and hl.chapter ~= "" then
    local cand_ch = get_chapter_for_xpointer(ui, candidate.start)
    if type(cand_ch) == "string" and cand_ch ~= "" then
      score = score + text_similarity(cand_ch, hl.chapter) * 20
    end
  end

  -- (d) progression proximity: 0–20 pts
  --     Use candidate.progression if present; otherwise estimate from XPointer.
  local prog = type(candidate.progression) == "number" and candidate.progression
    or estimate_progression(ui, candidate.start)
  if prog and type(hl.total_progression) == "number" then
    score = score + (1 - math.min(1, math.abs(prog - hl.total_progression))) * 20
  end

  return score
end

-- ── disambiguation judgment ───────────────────────────────────────────────

-- Returns (ok, reason) for a multi-candidate result set.
-- n >= 2.  Returns true/"" on success, false/detail_string on conflict.
local function check_disambiguation(exact, n, best_score, second_score)
  local margin      = best_score - second_score
  local needed      = is_short_text(exact) and SHORT_MARGIN or MIN_MARGIN
  local short_label = is_short_text(exact) and "short" or "normal"

  if best_score < MIN_SCORE then
    return false, string.format(
      "%d candidates; best=%.1f second=%.1f margin=%.1f; "
        .. "insufficient context score (best < min=%d)",
      n, best_score, second_score, margin, MIN_SCORE)
  end
  if margin < needed then
    return false, string.format(
      "%d candidates; best=%.1f second=%.1f margin=%.1f; "
        .. "%s text, margin too small (need %d)",
      n, best_score, second_score, margin, short_label, needed)
  end
  return true, nil
end

-- ── write a native KOReader annotation ───────────────────────────────────

-- sha256 is stored in the annotation for Phase 3 push/tombstone tracking.
local function write_annotation(ui, hl, pos0_xp, pos1_xp, sha256)
  local Event = require("ui/event")
  -- Resolve color: backend color first, then KOReader's own saved_color.
  local native_default = (ui.view and ui.view.highlight
    and type(ui.view.highlight.saved_color) == "string"
    and ui.view.highlight.saved_color ~= "")
      and ui.view.highlight.saved_color or "gray"
  local color = (type(hl.color) == "string" and hl.color ~= ""
    and COLOR_MAP[hl.color]) or native_default
  local synced_note = (type(hl.note) == "string" and hl.note ~= "") and hl.note or ""
  local item = {
    page    = pos0_xp,
    pos0    = pos0_xp,
    pos1    = pos1_xp,
    text    = hl.exact,
    note    = synced_note ~= "" and synced_note or nil,
    drawer  = "lighten",
    color   = color,
    chapter = (type(hl.chapter) == "string" and hl.chapter ~= "") and hl.chapter or nil,
    -- Phase 3: backend tracking fields (persisted with annotation)
    bookaware_highlight_id = hl.id,
    bookaware_sha256       = sha256,
    bookaware_synced_color = color,
    bookaware_synced_note  = synced_note,
  }
  local index = ui.annotation:addItem(item)
  ui:handleEvent(Event:new("AnnotationsModified",
    { item, nb_highlights_added = 1, index_modified = index }))
  return index
end

-- ── backend annotation identity helpers ──────────────────────────────────

local function find_synced_annotation(ui, sha256, highlight_id)
  if type(highlight_id) ~= "string" or highlight_id == "" then return nil end
  if type(ui.annotation) ~= "table"
      or type(ui.annotation.annotations) ~= "table" then
    return nil
  end
  for i, ann in ipairs(ui.annotation.annotations) do
    if ann.bookaware_highlight_id == highlight_id
        and ann.bookaware_sha256 == sha256 then
      return ann, i
    end
  end
  return nil
end

-- ── SHA256 resolution ─────────────────────────────────────────────────────

local function get_sha256(ui)
  if not ui then return nil end
  if ui.doc_settings and type(ui.doc_settings.readSetting) == "function" then
    local ok, v = pcall(function()
      return ui.doc_settings:readSetting("file_sha256")
    end)
    if ok and type(v) == "string" and v ~= "" then return v end
  end
  if ui.document and type(ui.document.file) == "string" and ui.document.file ~= "" then
    local ok, digest = pcall(Util.sha256_file, ui.document.file)
    if ok and type(digest) == "string" and digest ~= "" then return digest end
  end
  return nil
end

-- ── Phase 3: shared helpers ──────────────────────────────────────────────

-- Number of words of context to grab on each side of a selection. KOReader
-- itself uses 5 for translation context; the same magnitude is plenty for
-- text-quote anchoring on the web side (~30-60 characters typically).
local CONTEXT_WORDS = 5

-- Extract `prefix` (text immediately before pos0) and `suffix` (text
-- immediately after pos1) for a KOReader annotation. Returns ("", "") on
-- failure — anchor-by-text on reader-web still works without context, just
-- with lower precision, so this never raises.
--
-- IMPORTANT: pass `restore_selection=false` here, not true.
--
-- CreDocument:getSelectedWordContext's `restore_selection=true` branch calls
-- getTextFromXPointers(pos0, pos1, true) which re-marks pos0..pos1 as the
-- *current crengine selection* and draws it on the next refresh. In
-- ReaderHighlight that is correct because pos0..pos1 *is* the user's live
-- selection. Here we are iterating over historical annotations during a
-- background sync; passing true would draw a blue selection rectangle on
-- whichever annotation was processed last. Passing false is the right
-- behaviour: we do not want to touch the on-screen selection at all.
--
-- The race the previous comment worried about (user mid-tap during auto-sync
-- losing their selection) does happen, but the affected window is small and
-- the alternative (always-on stray selection) is worse and more visible.
local function extract_context(ui, pos0_xp, pos1_xp)
  if not ui or not ui.document or type(ui.document.getSelectedWordContext) ~= "function" then
    return "", ""
  end
  if type(pos0_xp) ~= "string" or type(pos1_xp) ~= "string" then
    return "", ""
  end
  local ok, prev, nxt = pcall(
    ui.document.getSelectedWordContext, ui.document,
    "", CONTEXT_WORDS, pos0_xp, pos1_xp, false)
  if not ok then return "", "" end
  return type(prev) == "string" and prev or "",
         type(nxt)  == "string" and nxt  or ""
end

-- Stable idempotency key for a local annotation. The key is derived from
-- (sha256, pos0, pos1, exact) so that repeating the same POST after a network
-- failure does not create duplicates on the backend.
--
-- Raises if SHA256 is unavailable (which would force a low-entropy fallback
-- key whose collisions would silently de-duplicate distinct annotations on
-- the backend). ffi/sha2 ships with every real KOReader build, so this is
-- only expected to fire in broken environments and must be loud.
local function make_client_id(sha256, ann)
  local pos0 = type(ann.pos0) == "string" and ann.pos0 or ""
  local pos1 = type(ann.pos1) == "string" and ann.pos1 or ""
  local text = type(ann.text) == "string" and ann.text or ""
  local payload = (sha256 or "") .. "|" .. pos0 .. "|" .. pos1 .. "|" .. text
  local digest, err = Util.sha256_string(payload)
  if type(digest) ~= "string" or digest == "" then
    error("make_client_id: cannot derive idempotency key without SHA256: " .. tostring(err))
  end
  return "koreader-" .. digest:sub(1, 32)
end

-- Fetch the set of backend highlight IDs that have been tombstoned. Pulled
-- once and shared between push_new / push_changes / apply_tombstones so a
-- single sync round does not race against itself (e.g. PATCHing a record
-- that is about to be tombstoned).
local function fetch_deleted_ids(sha256)
  local result = AiClient.listHighlights(sha256, nil, true)
  local all_hls = (type(result) == "table" and type(result.highlights) == "table")
    and result.highlights or {}
  local deleted_ids = {}
  for _, hl in ipairs(all_hls) do
    if type(hl.id) == "string"
        and type(hl.deleted_at) == "string" and hl.deleted_at ~= "" then
      deleted_ids[hl.id] = true
    end
  end
  return deleted_ids
end

local function read_pending_deletes(ui)
  if not ui or not ui.doc_settings
      or type(ui.doc_settings.readSetting) ~= "function" then
    return {}
  end
  local pending = ui.doc_settings:readSetting(PENDING_DELETES_SETTING)
  local ids = {}
  if type(pending) ~= "table" then return ids end

  -- Current format is an array of backend highlight ids. Also accept a map
  -- shape for forwards/backwards compatibility with development builds.
  for k, v in pairs(pending) do
    if type(v) == "string" and v ~= "" then
      ids[v] = true
    elseif type(k) == "string" and k ~= "" and v then
      ids[k] = true
    end
  end
  return ids
end

local function save_pending_deletes(ui, ids)
  if not ui or not ui.doc_settings
      or type(ui.doc_settings.saveSetting) ~= "function" then
    return
  end
  local list = {}
  for id in pairs(ids or {}) do
    table.insert(list, id)
  end
  table.sort(list)
  ui.doc_settings:saveSetting(PENDING_DELETES_SETTING, list)
end

local function queue_pending_delete(ui, highlight_id)
  if type(highlight_id) ~= "string" or highlight_id == "" then return 0 end
  local ids = read_pending_deletes(ui)
  if ids[highlight_id] then return 0 end
  ids[highlight_id] = true
  save_pending_deletes(ui, ids)
  return 1
end

local function drain_pending_deletes(ui, sha256)
  if type(sha256) ~= "string" or sha256 == "" then
    return { deleted = 0, failed = 0 }
  end
  local ids = read_pending_deletes(ui)
  local deleted, failed, changed = 0, 0, false
  for id in pairs(ids) do
    local ok = pcall(AiClient.deleteHighlight, sha256, id, "koreader")
    if ok then
      ids[id] = nil
      deleted = deleted + 1
      changed = true
    else
      failed = failed + 1
    end
  end
  if changed then save_pending_deletes(ui, ids) end
  return { deleted = deleted, failed = failed }
end

-- ── Phase 3a: push new KOReader-originated highlights ─────────────────────

-- Upload local annotations that have no bookaware_highlight_id yet. Only
-- EPUB (rolling) annotations are eligible because reader-web/book-aware can
-- only render text-quote anchors with XPointer positions.
--
-- On success the backend-assigned id and synced state are written back to
-- the annotation so subsequent push_changes/apply_tombstones can recognise it.
--
-- Per-annotation failures are caught (so a single bad row does not abort the
-- whole batch) but their details are logged via KOReader's logger and also
-- propagated in the returned `errors` table for surfacing to the UI.
--
-- Note: re-creating a highlight that the user previously tombstoned on the
-- web is intentionally allowed. The backend excludes deleted rows from
-- client_id idempotency (see book-aware test "client_id reused after
-- tombstone is treated as new highlight"), so a fresh row is created —
-- which matches the user's intent of having a visible highlight again.
local function push_new(ui, sha256)
  if type(ui.annotation) ~= "table"
      or type(ui.annotation.annotations) ~= "table" then
    return { created = 0, failed = 0, errors = {} }
  end
  if not ui.rolling then
    -- Without XPointer positions we cannot construct a usable anchor.
    return { created = 0, failed = 0, errors = {} }
  end

  local created, failed = 0, 0
  local errors = {}
  for _, ann in ipairs(ui.annotation.annotations) do
    local bid = type(ann.bookaware_highlight_id) == "string" and ann.bookaware_highlight_id or nil
    -- Skip annotations that already have a backend id (handled by push_changes).
    -- Also skip annotations missing the data we need to anchor remotely.
    if not bid
        and type(ann.text) == "string" and ann.text ~= ""
        and type(ann.pos0) == "string" and type(ann.pos1) == "string"
    then
      local client_id_for_log
      local ok_p, err = pcall(function()
        local client_id = make_client_id(sha256, ann)
        client_id_for_log = client_id

        local prefix, suffix = extract_context(ui, ann.pos0, ann.pos1)

        local page_str = ""
        local ok_pg, pn = pcall(function()
          return ui.document:getPageFromXPointer(ann.pos0)
        end)
        if ok_pg and pn then page_str = tostring(pn) end

        local total_progression
        local ok_total, total = pcall(function()
          local count = ui.document:getPageCount()
          if type(count) == "number" and count > 0 and type(pn) == "number" then
            -- Half-open convention: page 1 → 0.0, last page → (n-1)/n (never
            -- exactly 1.0). This intentionally matches estimate_progression()
            -- above; both directions of the sync use the same value for the
            -- same XPointer so disambiguation scoring stays consistent
            -- whether the candidate is computed locally or read from a row
            -- KOReader previously uploaded.
            return (pn - 1) / count
          end
        end)
        if ok_total and type(total) == "number" then
          total_progression = total
        end

        local color = type(ann.color) == "string" and ann.color ~= "" and ann.color or nil
        local note  = type(ann.note)  == "string" and ann.note  ~= "" and ann.note  or nil

        local payload = {
          exact     = ann.text,
          prefix    = prefix,
          suffix    = suffix,
          chapter   = type(ann.chapter) == "string" and ann.chapter ~= "" and ann.chapter or nil,
          color     = color,
          note      = note,
          source    = "koreader",
          client_id = client_id,
          total_progression = total_progression,
          koreader  = {
            status = "resolved",
            pos0   = ann.pos0,
            pos1   = ann.pos1,
            page   = page_str,
          },
        }

        local resp = AiClient.createHighlight(sha256, payload)
        if type(resp) ~= "table" or type(resp.highlight) ~= "table"
            or type(resp.highlight.id) ~= "string" then
          error("createHighlight returned no highlight.id")
        end

        -- Persist backend identity + synced baseline. We do NOT mutate the
        -- annotation's note/color (the local value is the source of truth).
        ann.bookaware_highlight_id = resp.highlight.id
        ann.bookaware_sha256       = sha256
        ann.bookaware_client_id    = client_id
        ann.bookaware_synced_color = type(ann.color) == "string" and ann.color or ""
        ann.bookaware_synced_note  = type(ann.note)  == "string" and ann.note  or ""
        created = created + 1
      end)
      if not ok_p then
        failed = failed + 1
        local detail = {
          client_id = client_id_for_log,
          exact     = (type(ann.text) == "string" and ann.text:sub(1, 60)) or "",
          message   = tostring(err),
        }
        table.insert(errors, detail)
        -- Logs land in crash.log via KOReader's logger; this is the project's
        -- convention for partial-success batch diagnostics.
        logger.warn("[book-aware] push_new failed for highlight",
          detail.client_id or "(unknown client_id)", "-", detail.message)
      end
    end
  end
  return { created = created, failed = failed, errors = errors }
end

-- ── Phase 3b: push local note/color changes ──────────────────────────────

-- Push note/color changes that were made in KOReader back to the backend.
-- Only annotations with bookaware_highlight_id whose color or note differ
-- from the last synced values are sent. `skip_ids` is the set of backend
-- highlight ids that have been tombstoned this round and should not be
-- patched (avoids a 404/410 storm and confusing "failed" counts).
--
-- Field-level diff is intentional: we never include unchanged fields in the
-- PATCH. This prevents the previous behavior where a local color change
-- would also push the (possibly stale) note value and silently overwrite
-- newer changes the web client had made to it.
local function push_changes(ui, sha256, skip_ids)
  if type(ui.annotation) ~= "table"
      or type(ui.annotation.annotations) ~= "table" then
    return { pushed = 0, failed = 0 }
  end
  local pushed, failed = 0, 0
  for _, ann in ipairs(ui.annotation.annotations) do
    local bid     = type(ann.bookaware_highlight_id) == "string" and ann.bookaware_highlight_id or nil
    local ann_sha = type(ann.bookaware_sha256)       == "string" and ann.bookaware_sha256       or nil
    if bid and ann_sha == sha256 and not (skip_ids and skip_ids[bid]) then
      local cur_color = type(ann.color) == "string" and ann.color or ""
      local cur_note  = type(ann.note)  == "string" and ann.note  or ""
      local syn_color = type(ann.bookaware_synced_color) == "string" and ann.bookaware_synced_color or ""
      local syn_note  = type(ann.bookaware_synced_note)  == "string" and ann.bookaware_synced_note  or ""
      local color_changed = cur_color ~= syn_color and cur_color ~= ""
      local note_changed  = cur_note  ~= syn_note
      if color_changed or note_changed then
        local ok_p = pcall(function()
          local patch = { updated_by = "koreader" }
          if color_changed then patch.color = cur_color end
          -- note is sent only when changed; empty string deliberately clears
          -- the backend note when the user removed it locally.
          if note_changed  then patch.note  = cur_note  end
          AiClient.updateHighlight(ann_sha, bid, patch)
          if color_changed then ann.bookaware_synced_color = cur_color end
          if note_changed  then ann.bookaware_synced_note  = cur_note  end
          pushed = pushed + 1
        end)
        if not ok_p then failed = failed + 1 end
      end
    end
  end
  return { pushed = pushed, failed = failed }
end

-- ── Phase 3c: apply tombstones from book-aware ────────────────────────────

-- Remove local annotations whose backend highlight has deleted_at set.
-- `deleted_ids` is the set previously fetched by fetch_deleted_ids(); pass
-- it in to keep all phases of a sync round consistent.
local function apply_tombstones(ui, sha256, deleted_ids)
  if type(ui.annotation) ~= "table"
      or type(ui.annotation.annotations) ~= "table" then
    return 0
  end
  if not deleted_ids or not next(deleted_ids) then return 0 end

  -- Remove matching local annotations. Mirror KOReader's own removal event
  -- shape (see KOReader ReaderBookmark:removeItemByIndex): include the
  -- removed item and a negative index_modified so ReaderAnnotation does not
  -- treat this as an edit. Add a book-aware origin marker so our plugin's
  -- onAnnotationsModified hook can distinguish a web-side tombstone being
  -- applied locally from a real user-initiated local deletion.
  local Event       = require("ui/event")
  local annotations = ui.annotation.annotations
  local removed     = 0
  local i = 1
  while i <= #annotations do
    local ann     = annotations[i]
    local bid     = type(ann.bookaware_highlight_id) == "string" and ann.bookaware_highlight_id or nil
    local ann_sha = type(ann.bookaware_sha256)       == "string" and ann.bookaware_sha256       or nil
    if bid and ann_sha == sha256 and deleted_ids[bid] then
      local removed_item = table.remove(annotations, i)
      removed = removed + 1
      ui:handleEvent(Event:new("AnnotationsModified", {
        removed_item,
        nb_highlights_added = -1,
        index_modified = -i,
        bookaware_origin = "tombstone_apply",
      }))
    else
      i = i + 1
    end
  end

  return removed
end

-- Repair mode: pull all active backend highlights and recreate any local
-- annotation missing its book-aware identity. This is intentionally separate
-- from normal sync, which only consumes pending web highlights.
local function repair_missing(ui, sha256)
  local result = AiClient.listHighlights(sha256)
  local highlights = (type(result) == "table" and type(result.highlights) == "table")
    and result.highlights or {}

  local repaired, skipped, failed = 0, 0, 0
  for _, hl in ipairs(highlights) do
    local ok = pcall(function()
      if type(hl) ~= "table" or type(hl.id) ~= "string" or hl.id == ""
          or type(hl.exact) ~= "string" or hl.exact == ""
          or hl.deleted_at then
        skipped = skipped + 1
        return
      end
      if find_synced_annotation(ui, sha256, hl.id) then
        skipped = skipped + 1
        return
      end

      local k = type(hl.koreader) == "table" and hl.koreader or {}
      local pos0_xp = type(k.pos0) == "string" and k.pos0 or nil
      local pos1_xp = type(k.pos1) == "string" and k.pos1 or nil

      -- Resolved KOReader rows already contain native anchors; use them
      -- directly so repair does not depend on text search disambiguation.
      if not pos0_xp or not pos1_xp then
        local results = ui.document:findAllText(hl.exact, true, 8, 200, false)
        if not results or #results == 0 then
          failed = failed + 1
          return
        end
        local winner = results[1]
        pos0_xp = type(winner.start) == "string" and winner.start or nil
        pos1_xp = type(winner["end"]) == "string" and winner["end"] or nil
      end

      if not pos0_xp or not pos1_xp then
        failed = failed + 1
        return
      end

      write_annotation(ui, hl, pos0_xp, pos1_xp, sha256)
      repaired = repaired + 1
    end)

    if not ok then failed = failed + 1 end
  end

  return { repaired = repaired, skipped = skipped, failed = failed }
end

-- ── public API ────────────────────────────────────────────────────────────

-- Sync web highlights for the currently open book.
-- Phase 1/2: pull pending highlights, locate in document, write native annotations.
-- Phase 3a: push local note/color changes back to book-aware.
-- Phase 3b: apply tombstones — remove annotations deleted via reader-web.
-- Returns { resolved, conflict, failed, pushed, created, removed } counts.
-- Raises on fatal errors (no document, can't determine SHA256, network failure).
function AnnotationSync.sync(ui)
  if not ui or not ui.document then
    error("AnnotationSync.sync: no open document")
  end
  if not ui.annotation then
    error("AnnotationSync.sync: ui.annotation not available (EPUB rolling reader required)")
  end
  if not ui.rolling then
    error("AnnotationSync.sync: only EPUB (rolling) documents are supported in Phase 1")
  end

  local sha256 = get_sha256(ui)
  if not sha256 then
    error("AnnotationSync.sync: cannot determine book SHA256")
  end

  local resolved, conflict, failed = 0, 0, 0

  -- Retry KOReader-originated deletes that were queued when the user deleted
  -- a synced annotation while offline or while the backend was unavailable.
  local delete_result = drain_pending_deletes(ui, sha256)

  -- ── Phase 1/2: pull pending highlights ────────────────────────────────
  local pending_result = AiClient.listHighlights(sha256, "pending")
  local highlights = (type(pending_result) == "table"
    and type(pending_result.highlights) == "table")
    and pending_result.highlights or {}

  for _, hl in ipairs(highlights) do
    local ok, err = pcall(function()
      local exact = type(hl.exact) == "string" and hl.exact or ""
      if exact == "" then error("empty exact text") end

      local results = ui.document:findAllText(exact, true, 8, 200, false)
      if not results or #results == 0 then
        AiClient.updateHighlight(sha256, hl.id, {
          koreader = { status = "failed", error = "text not found in document" }
        })
        failed = failed + 1
        return
      end

      local best_idx, best_score, second_score = 1, -1, -1
      for i, candidate in ipairs(results) do
        local s = score_candidate(ui, candidate, hl)
        if s > best_score then
          second_score = best_score
          best_score   = s
          best_idx     = i
        elseif s > second_score then
          second_score = s
        end
      end
      if second_score < 0 then second_score = 0 end

      if #results > 1 then
        local ok_d, reason = check_disambiguation(exact, #results, best_score, second_score)
        if not ok_d then
          AiClient.updateHighlight(sha256, hl.id, {
            koreader = {
              status           = "conflict",
              error            = reason,
              candidates_count = #results,
              conflict_scores  = {
                best   = best_score,
                second = second_score,
                margin = best_score - second_score,
              },
            }
          })
          conflict = conflict + 1
          return
        end
      end

      local winner  = results[best_idx]
      local pos0_xp = winner.start
      local pos1_xp = winner["end"]

      if type(pos0_xp) ~= "string" or type(pos1_xp) ~= "string" then
        AiClient.updateHighlight(sha256, hl.id, {
          koreader = { status = "failed", error = "findAllText result missing XPointer" }
        })
        failed = failed + 1
        return
      end

      -- Idempotency guard: if a previous sync inserted this local annotation
      -- but failed before marking the backend highlight resolved, retry the
      -- backend resolution without adding a duplicate KOReader annotation.
      if not find_synced_annotation(ui, sha256, hl.id) then
        write_annotation(ui, hl, pos0_xp, pos1_xp, sha256)
      end

      local pageno = ""
      local ok_page, pn = pcall(function()
        return ui.document:getPageFromXPointer(pos0_xp)
      end)
      if ok_page and pn then pageno = tostring(pn) end

      AiClient.updateHighlight(sha256, hl.id, {
        koreader = {
          status = "resolved",
          pos0   = pos0_xp,
          pos1   = pos1_xp,
          page   = pageno,
        }
      })
      resolved = resolved + 1
    end)

    if not ok then
      pcall(AiClient.updateHighlight, sha256, hl.id, {
        koreader = { status = "failed", error = tostring(err) }
      })
      failed = failed + 1
    end
  end

  if resolved > 0 and ui.doc_settings
      and type(ui.doc_settings.saveSetting) == "function" then
    ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
  end

  -- Fetch tombstones once so push_new / push_changes / apply_tombstones all
  -- agree about which ids are dead. If this fails the whole sync must fail —
  -- otherwise we'd silently miss web-side deletes.
  local deleted_ids = fetch_deleted_ids(sha256)

  -- ── Phase 3a: push new KOReader-originated highlights ──────────────────
  -- Run *before* push_changes so freshly assigned backend ids are visible to
  -- subsequent diff logic (in this sync round they're new and not dirty, so
  -- push_changes is a no-op for them — but future rounds depend on the ids).
  --
  -- We do NOT pass deleted_ids here: backend client_id idempotency already
  -- excludes tombstoned rows, so re-highlighting locally produces a fresh
  -- backend row (matching user intent). See test T17 in book-aware.
  local new_result = push_new(ui, sha256)

  -- ── Phase 3b: push local note/color changes ────────────────────────────
  local push_result = push_changes(ui, sha256, deleted_ids)

  -- ── Phase 3c: apply tombstones from book-aware ─────────────────────────
  local removed = apply_tombstones(ui, sha256, deleted_ids)

  -- Save id/synced_color/note fields updated by push_new / push_changes, and
  -- deletions applied by tombstones. (Resolved annotations are saved earlier,
  -- before fetching tombstones, so a later network failure cannot leave the
  -- backend marked resolved while the local sidecar misses the annotation.)
  if (new_result.created > 0 or push_result.pushed > 0 or removed > 0)
      and ui.doc_settings
      and type(ui.doc_settings.saveSetting) == "function" then
    ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
  end

  local total_failed = failed
    + (push_result.failed or 0)
    + (new_result.failed or 0)
    + (delete_result.failed or 0)
  return {
    resolved = resolved,
    conflict = conflict,
    failed   = total_failed,
    pushed   = push_result.pushed,
    created  = new_result.created,
    removed  = removed,
    deleted  = delete_result.deleted or 0,
    -- Per-annotation failure details from push_new (client_id, exact, message).
    -- Surfaced so callers can show "upload failed for N highlight(s): ...".
    create_errors = new_result.errors or {},
  }
end

-- Push-only sync: upload KOReader-created highlights that do not have a
-- backend id yet. Used by the automatic "new highlight" hook in main.lua.
-- It deliberately does NOT pull web highlights, apply tombstones, or push
-- note/color changes: this keeps the post-highlight path as small and safe as
-- possible. Silently no-ops on non-EPUB documents or when SHA256 is unavailable.
function AnnotationSync.push_new_highlights_only(ui)
  if not ui or not ui.document then return { created = 0, failed = 0, errors = {} } end
  if not ui.rolling then return { created = 0, failed = 0, errors = {} } end
  if not ui.annotation then return { created = 0, failed = 0, errors = {} } end
  local sha256 = get_sha256(ui)
  if not sha256 then return { created = 0, failed = 0, errors = {} } end

  local result = push_new(ui, sha256)
  if (result.created or 0) > 0
      and ui.doc_settings
      and type(ui.doc_settings.saveSetting) == "function" then
    ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
  end
  return result
end

-- Push-only sync: push local note/color changes back to book-aware.
-- Does NOT pull pending highlights, create new highlights, or apply tombstones —
-- safe to call on close. Returns { pushed, failed }. Silently no-ops on
-- non-EPUB documents or when the SHA256 cannot be determined (this hook runs
-- during onCloseDocument / onSaveSettings, including for PDF/DjVu, and must
-- not raise just because there is no backend record to push).
function AnnotationSync.push_changes_only(ui)
  if not ui or not ui.document then return { pushed = 0, failed = 0 } end
  if not ui.rolling then return { pushed = 0, failed = 0 } end
  if not ui.annotation then return { pushed = 0, failed = 0 } end
  local sha256 = get_sha256(ui)
  if not sha256 then return { pushed = 0, failed = 0 } end
  return push_changes(ui, sha256, nil)
end

-- Pull all active backend highlights and restore only those missing from the
-- current KOReader annotation list. This fixes the "backend says resolved but
-- local metadata is missing" case without changing normal pending-only sync.
function AnnotationSync.repair_missing_highlights(ui)
  if not ui or not ui.document then
    error("AnnotationSync.repair_missing_highlights: no open document")
  end
  if not ui.annotation then
    error("AnnotationSync.repair_missing_highlights: ui.annotation not available")
  end
  if not ui.rolling then
    error("AnnotationSync.repair_missing_highlights: only EPUB documents are supported")
  end

  local sha256 = get_sha256(ui)
  if not sha256 then
    error("AnnotationSync.repair_missing_highlights: cannot determine book SHA256")
  end

  local result = repair_missing(ui, sha256)
  if (result.repaired or 0) > 0
      and ui.doc_settings
      and type(ui.doc_settings.saveSetting) == "function" then
    ui.doc_settings:saveSetting("annotations", ui.annotation.annotations)
  end
  return result
end

-- Persist a KOReader-originated delete before attempting network IO. This is
-- intentionally separate from delete_highlight_only so main.lua can record the
-- user's delete immediately, even if config validation or connectivity fails
-- before the scheduled backend request runs.
function AnnotationSync.queue_deleted_highlight(ui, item)
  if type(item) ~= "table" then return { queued = 0 } end
  local bid = type(item.bookaware_highlight_id) == "string" and item.bookaware_highlight_id or nil
  if not bid or bid == "" then return { queued = 0 } end

  local sha256 = get_sha256(ui)
  local ann_sha = type(item.bookaware_sha256) == "string" and item.bookaware_sha256 or nil
  if sha256 and ann_sha and ann_sha ~= "" and ann_sha ~= sha256 then
    return { queued = 0 }
  end

  return { queued = queue_pending_delete(ui, bid) }
end

-- Push-only sync: drain queued tombstones for KOReader-deleted synced
-- highlights. Silently no-ops when the current book SHA cannot be determined;
-- backend failures remain queued and are surfaced in the returned failed count.
function AnnotationSync.push_pending_deletes_only(ui)
  if not ui or not ui.document then return { deleted = 0, failed = 0 } end
  local sha256 = get_sha256(ui)
  if not sha256 then return { deleted = 0, failed = 0 } end
  return drain_pending_deletes(ui, sha256)
end

-- Queue and immediately try to tombstone a KOReader-deleted synced highlight
-- on the backend. Used by tests and safe for callers that don't need to split
-- durable intent recording from the network attempt.
function AnnotationSync.delete_highlight_only(ui, item)
  local queued = AnnotationSync.queue_deleted_highlight(ui, item)
  local result = AnnotationSync.push_pending_deletes_only(ui)
  result.queued = queued.queued or 0
  return result
end

-- Fetch conflict highlights for the currently open book.
-- Returns an array of WebHighlight objects with status="conflict".
-- Raises on fatal errors (SHA256 not found, network failure).
function AnnotationSync.list_conflicts(ui)
  local sha256 = get_sha256(ui)
  if not sha256 then
    error("AnnotationSync.list_conflicts: cannot determine book SHA256")
  end
  local result = AiClient.listHighlights(sha256, "conflict")
  return (type(result) == "table" and type(result.highlights) == "table")
    and result.highlights or {}
end

return AnnotationSync
