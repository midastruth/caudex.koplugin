-- Unit tests for annotation_sync.lua (Phase 2 + Phase 3)
-- Phase 2: 5 disambiguation scenarios + list_conflicts
-- Phase 3: backend-id storage, push changes, tombstone handling

local H = require("spec.helpers")
H.section("F. annotation_sync.lua (Phase 2+3)")

local SHA = string.rep("a", 64)

-- ── mock infrastructure ────────────────────────────────────────────────────

local function reset_modules()
  H.reset("caudex.annotation_sync", "caudex.ai_client", "caudex.util",
          "ui/event", "logger")
  package.loaded["caudex.util"] = {
    sha256_file = function() error("not used in tests") end,
    -- Deterministic substitute: real implementation hashes via ffi/sha2 which
    -- is not loadable in the unit-test harness. Returns a stable hex-ish
    -- string that varies with input so distinct payloads get distinct keys
    -- (this matters for T17 retry stability and to avoid collisions in tests).
    sha256_string = function(data)
      local s = tostring(data or "")
      -- Simple deterministic 32-bit rolling hash. Keep this pure arithmetic
      -- so the spec runs under both LuaJIT (KOReader) and stock Lua, where
      -- the global `bit` module may not exist.
      local hash = 5381
      for i = 1, #s do
        hash = (hash * 33 + s:byte(i)) % 4294967296
      end
      return string.format("%08x%08x%08x%08x", hash, hash, hash, hash)
    end,
  }
  package.loaded["ui/event"] = {
    new = function(_, name, data) return { name = name, data = data } end,
  }
  -- Stub logger; production code calls logger.warn/err and we want tests to
  -- be silent rather than spam stderr.
  package.loaded["logger"] = {
    dbg  = function() end,
    info = function() end,
    warn = function() end,
    err  = function() end,
  }
end

-- Build a spy AiClient loaded with the given pending highlights.
-- Returns the client table and the update_calls log.
local function make_ai_client(pending_hls)
  local update_calls = {}
  local ai = {
    listHighlights  = function(_sha, _status) return { highlights = pending_hls } end,
    updateHighlight = function(_sha, id, patch)
      table.insert(update_calls, { id = id, patch = patch })
      return {}
    end,
  }
  package.loaded["caudex.ai_client"] = ai
  return ai, update_calls
end

-- Build a minimal fake ui object.
-- find_fn: function(self, text, ...) → array of candidate tables
-- opts.pages: table[xpointer] = page_number
-- opts.toc_pages: table[page_number] = chapter_title
-- opts.page_count: total pages (default 100)
-- opts.saved_color: KOReader saved_color (default "gray")
local function make_ui(find_fn, opts)
  opts = opts or {}
  local annotation = {
    _calls      = {},
    annotations = {},
    addItem = function(self, item)
      table.insert(self._calls, item)
      table.insert(self.annotations, item)
      return #self.annotations
    end,
  }
  local toc = nil
  if opts.toc_pages then
    toc = {
      getTocTitleByPage = function(self, page)
        return opts.toc_pages[page] or ""
      end,
    }
  end
  local events = {}
  local settings = opts.settings or {}
  return {
    _events = events,
    _settings = settings,
    document = {
      file                = "/fake/book.epub",
      findAllText         = find_fn or function() return {} end,
      getPageFromXPointer = function(self, xp)
        return (opts.pages and opts.pages[xp]) or 1
      end,
      getPageCount = function() return opts.page_count or 100 end,
      -- Mirror CreDocument:getSelectedWordContext signature; return canned
      -- prefix/suffix strings if the test supplied them, otherwise empties.
      getSelectedWordContext = function(_self, _word, _nb_words, pos0, pos1)
        local ctx = opts.contexts and opts.contexts[pos0 .. "|" .. pos1]
        if ctx then return ctx[1], ctx[2] end
        return "", ""
      end,
    },
    annotation   = annotation,
    rolling      = true,
    toc          = toc,
    view         = { highlight = { saved_color = opts.saved_color or "gray" } },
    doc_settings = {
      readSetting = function(self, key)
        if key == "file_sha256" then return SHA end
        return settings[key]
      end,
      saveSetting = function(self, key, value)
        settings[key] = value
      end,
    },
    handleEvent = function(_, ev) table.insert(events, ev) end,
  }
end

-- ── Scenario 1: unique candidate → resolved, addItem called ───────────────

do
  reset_modules()
  local _, updates = make_ai_client({
    {
      id     = "hl-001",
      exact  = "The quick brown fox",
      prefix = "Once upon a time ",
      suffix = " jumps over the lazy dog",
    },
  })

  local ui = make_ui(function(self, text)
    if text == "The quick brown fox" then
      return {{
        start     = "/body/p[1].0",
        ["end"]   = "/body/p[1].19",
        prev_text = "Once upon a time ",
        next_text = " jumps over the lazy dog",
      }}
    end
    return {}
  end)

  local AS = require("caudex.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T1 resolved=1",          r.resolved, 1)
  H.eq("T1 conflict=0",          r.conflict, 0)
  H.eq("T1 failed=0",            r.failed, 0)
  H.eq("T1 addItem called once", #ui.annotation._calls, 1)
  H.eq("T1 backend update once", #updates, 1)
  H.eq("T1 status=resolved",     updates[1].patch.koreader.status, "resolved")
  H.eq("T1 pos0 correct",        updates[1].patch.koreader.pos0, "/body/p[1].0")
  H.eq("T1 pos1 correct",        updates[1].patch.koreader.pos1, "/body/p[1].19")
end

-- ── Scenario 2: multiple candidates, clear winner → resolved to correct one

do
  reset_modules()
  local _, updates = make_ai_client({
    {
      id     = "hl-002",
      exact  = "luminous grace",
      prefix = "bathed in this luminous grace the sky",
      suffix = " falls upon the valley below us",
    },
  })

  local ui = make_ui(function(self, text)
    if text == "luminous grace" then
      return {
        { -- Winner: context matches perfectly (similarity 1.0 for both)
          start     = "/body/p[2].0",
          ["end"]   = "/body/p[2].14",
          prev_text = "bathed in this luminous grace the sky",
          next_text = " falls upon the valley below us",
        },
        { -- Noise: completely different context
          start     = "/body/p[10].0",
          ["end"]   = "/body/p[10].14",
          prev_text = "",
          next_text = "",
        },
        { -- Also noise
          start     = "/body/p[20].0",
          ["end"]   = "/body/p[20].14",
          prev_text = "",
          next_text = "",
        },
      }
    end
    return {}
  end)

  local AS = require("caudex.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T2 resolved=1",                     r.resolved, 1)
  H.eq("T2 conflict=0",                     r.conflict, 0)
  H.eq("T2 addItem called once",            #ui.annotation._calls, 1)
  H.eq("T2 resolved to correct candidate",  updates[1].patch.koreader.pos0, "/body/p[2].0")
end

-- ── Scenario 3: multiple candidates, scores tied → conflict, no addItem ───

do
  reset_modules()
  local _, updates = make_ai_client({
    {
      id     = "hl-003",
      exact  = "the gathering light",
      prefix = "we watched as the gathering light",
      suffix = " faded slowly into the horizon",
    },
  })

  -- Both candidates have identical context → scores tied, margin = 0.
  local same_prev = "we watched as the gathering light"
  local same_next = " faded slowly into the horizon"

  local ui = make_ui(function(self, text)
    if text == "the gathering light" then
      return {
        {
          start     = "/body/p[1].0",
          ["end"]   = "/body/p[1].19",
          prev_text = same_prev,
          next_text = same_next,
        },
        {
          start     = "/body/p[5].0",
          ["end"]   = "/body/p[5].19",
          prev_text = same_prev,
          next_text = same_next,
        },
      }
    end
    return {}
  end)

  local AS = require("caudex.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T3 conflict=1",         r.conflict, 1)
  H.eq("T3 resolved=0",         r.resolved, 0)
  H.eq("T3 addItem NOT called", #ui.annotation._calls, 0)
  H.eq("T3 status=conflict",    updates[1].patch.koreader.status, "conflict")
  H.eq("T3 candidates_count=2", updates[1].patch.koreader.candidates_count, 2)
  H.is_true("T3 error mentions 2 candidates",
    type(updates[1].patch.koreader.error) == "string" and
    updates[1].patch.koreader.error:find("2 candidates") ~= nil)
  H.is_true("T3 conflict_scores present",
    type(updates[1].patch.koreader.conflict_scores) == "table")
end

-- ── Scenario 4: text not found → failed, no addItem ──────────────────────

do
  reset_modules()
  local _, updates = make_ai_client({
    {
      id    = "hl-004",
      exact = "xyzzy this text does not appear anywhere",
    },
  })

  local ui = make_ui(function() return {} end)

  local AS = require("caudex.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T4 failed=1",           r.failed, 1)
  H.eq("T4 resolved=0",         r.resolved, 0)
  H.eq("T4 addItem NOT called", #ui.annotation._calls, 0)
  H.eq("T4 status=failed",      updates[1].patch.koreader.status, "failed")
  H.contains("T4 error mentions not found",
    updates[1].patch.koreader.error or "", "not found")
end

-- ── Scenario 5: short text, multiple candidates → conflict ────────────────
-- A margin of 40 pts would auto-resolve for normal text (MIN_MARGIN=15)
-- but conflicts for short text (SHORT_MARGIN=45).

do
  reset_modules()
  local _, updates = make_ai_client({
    {
      id     = "hl-005",
      exact  = "me",     -- 2 chars < SHORT_TEXT_CHARS=8 → short text
      prefix = "tell",   -- used for scoring
    },
  })

  local ui = make_ui(function(self, text)
    if text == "me" then
      return {
        { -- Better candidate: prefix exact match → 40 pts
          start     = "/body/p[1].0",
          ["end"]   = "/body/p[1].2",
          prev_text = "tell",   -- identical to hl.prefix → similarity=1.0 → 40 pts
          next_text = "",
        },
        { -- Worse candidate: no context → 0 pts
          start     = "/body/p[9].0",
          ["end"]   = "/body/p[9].2",
          prev_text = "",
          next_text = "",
        },
      }
    end
    return {}
  end)

  -- Margin = 40 - 0 = 40.
  -- Normal text: 40 >= MIN_MARGIN(15) → would resolve.
  -- Short text:  40 <  SHORT_MARGIN(45) → must conflict.
  local AS = require("caudex.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T5 conflict=1 (short text conservatism)", r.conflict, 1)
  H.eq("T5 resolved=0",    r.resolved, 0)
  H.eq("T5 addItem NOT called", #ui.annotation._calls, 0)
  H.eq("T5 status=conflict",   updates[1].patch.koreader.status, "conflict")
  H.is_true("T5 error mentions short text",
    type(updates[1].patch.koreader.error) == "string" and
    updates[1].patch.koreader.error:find("short") ~= nil)
  H.is_true("T5 conflict_scores.margin is 40",
    type(updates[1].patch.koreader.conflict_scores) == "table" and
    math.abs(updates[1].patch.koreader.conflict_scores.margin - 40) < 0.01)
end

-- ── Bonus: list_conflicts returns correct array ───────────────────────────

do
  reset_modules()
  local conflict_hls = {
    { id = "c-1", exact = "foo", koreader = { status = "conflict", error = "2 candidates" } },
    { id = "c-2", exact = "bar", koreader = { status = "conflict", error = "3 candidates" } },
  }
  package.loaded["caudex.ai_client"] = {
    listHighlights  = function(_sha, status)
      if status == "conflict" then return { highlights = conflict_hls } end
      return { highlights = {} }
    end,
    updateHighlight = function() return {} end,
  }

  local ui = make_ui()  -- no findAllText needed; we're only calling list_conflicts

  local AS = require("caudex.annotation_sync")
  local list = AS.list_conflicts(ui)

  H.eq("list_conflicts returns 2 items",    #list, 2)
  H.eq("list_conflicts first id",  list[1] and list[1].id, "c-1")
  H.eq("list_conflicts second id", list[2] and list[2].id, "c-2")
end

-- ══════════════════════════════════════════════════════════════════════════
-- Phase 3 tests
-- ══════════════════════════════════════════════════════════════════════════

-- Phase 3 mock: supports both pending-highlights call and include_deleted call.
-- pending_hls    — returned for listHighlights(sha, "pending")
-- all_with_deleted — returned for listHighlights(sha, nil, true)
-- Also returns a `creates` log so push_new tests can inspect POST payloads.
local function make_ai_client_p3(pending_hls, all_with_deleted)
  local update_calls = {}
  local create_calls = {}
  local delete_calls = {}
  local next_create_id = 0
  local ai = {
    listHighlights = function(_sha, _status, include_deleted)
      if include_deleted then
        return { highlights = all_with_deleted or {} }
      end
      return { highlights = pending_hls or {} }
    end,
    updateHighlight = function(_sha, id, patch)
      table.insert(update_calls, { id = id, patch = patch })
      return {}
    end,
    createHighlight = function(_sha, payload)
      next_create_id = next_create_id + 1
      local new_id = string.format("hl-new-%03d", next_create_id)
      table.insert(create_calls, { id = new_id, payload = payload })
      return { ok = true, highlight = {
        id          = new_id,
        book_sha256 = _sha,
        exact       = payload.exact,
        koreader    = payload.koreader or { status = "pending" },
      } }
    end,
    deleteHighlight = function(_sha, id, by)
      table.insert(delete_calls, { id = id, by = by })
      return {}
    end,
  }
  package.loaded["caudex.ai_client"] = ai
  return ai, update_calls, create_calls, delete_calls
end

-- ── T6: resolved annotation stores bookaware_highlight_id and sha256 ──────

do
  reset_modules()
  local _, updates = make_ai_client_p3({
    {
      id     = "hl-006",
      exact  = "unique sentinel text here",
      prefix = "prefix text ",
      suffix = " suffix text",
    },
  }, {})

  local ui = make_ui(function(self, text)
    if text == "unique sentinel text here" then
      return {{
        start     = "/body/p[1].0",
        ["end"]   = "/body/p[1].26",
        prev_text = "prefix text ",
        next_text = " suffix text",
      }}
    end
    return {}
  end)

  local AS = require("caudex.annotation_sync")
  AS.sync(ui)

  local item = ui.annotation._calls[1]
  H.eq("T6 annotation stores bookaware_highlight_id",
    item and item.bookaware_highlight_id, "hl-006")
  H.eq("T6 annotation stores bookaware_sha256",
    item and item.bookaware_sha256, SHA)
  H.is_true("T6 bookaware_synced_color stored",
    item and type(item.bookaware_synced_color) == "string")
end

-- ── T7: push_changes — local color change → PATCH sent ───────────────────

do
  reset_modules()
  local _, updates = make_ai_client_p3({}, {})  -- no pending, no tombstones

  local ui = make_ui(function() return {} end)
  -- Insert a pre-existing "synced" annotation with a changed color.
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-007",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "yellow",   -- what was last synced
    bookaware_synced_note  = "",
    color                  = "blue",     -- changed by user in KOReader
    note                   = "",
  })

  local AS = require("caudex.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T7 pushed=1",    r.pushed, 1)
  H.eq("T7 resolved=0",  r.resolved, 0)
  H.is_true("T7 updateHighlight called for hl-007",
    #updates == 1 and updates[1].id == "hl-007")
  H.eq("T7 patch.color=blue",
    updates[1] and updates[1].patch.color, "blue")
  H.eq("T7 patch.updated_by=koreader",
    updates[1] and updates[1].patch.updated_by, "koreader")
end

-- ── T8: apply_tombstones — annotation removed when backend has deleted_at ──

do
  reset_modules()
  local _, updates = make_ai_client_p3({}, {
    { id = "hl-008", exact = "tombstone text", deleted_at = "2026-01-01T00:00:00Z" },
  })

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-008",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "gray",
    bookaware_synced_note  = "",
    color                  = "gray",
    note                   = "",
  })

  local AS = require("caudex.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T8 removed=1",                r.removed, 1)
  H.eq("T8 resolved=0",               r.resolved, 0)
  H.eq("T8 annotation table is empty", #ui.annotation.annotations, 0)
  H.eq("T8 tombstone event marks origin",
    ui._events[1] and ui._events[1].data and ui._events[1].data.bookaware_origin,
    "tombstone_apply")
end

-- ── T9: tombstone for missing local annotation → no error ─────────────────

do
  reset_modules()
  local _, updates = make_ai_client_p3({}, {
    { id = "hl-009", exact = "ghost text", deleted_at = "2026-01-01T00:00:00Z" },
  })

  -- UI has no annotations; tombstone has no local counterpart.
  local ui = make_ui(function() return {} end)

  local AS = require("caudex.annotation_sync")
  H.no_error("T9 tombstone for missing annotation doesn't crash", function()
    AS.sync(ui)
  end)
  H.eq("T9 no annotations removed", #ui.annotation.annotations, 0)
end

-- ── T10: push_changes_only — changed color → PATCH sent ──────────────────

do
  reset_modules()
  local update_calls = {}
  package.loaded["caudex.ai_client"] = {
    listHighlights  = function() return { highlights = {} } end,
    updateHighlight = function(_sha, id, patch)
      table.insert(update_calls, { id = id, patch = patch })
      return {}
    end,
  }

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-010",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "yellow",
    bookaware_synced_note  = "",
    color                  = "green",
    note                   = "",
  })

  local AS = require("caudex.annotation_sync")
  local r  = AS.push_changes_only(ui)

  H.eq("T10 pushed=1",                    r.pushed, 1)
  H.eq("T10 failed=0",                    r.failed, 0)
  H.eq("T10 updateHighlight called once", #update_calls, 1)
  H.eq("T10 patch.color=green",           update_calls[1] and update_calls[1].patch.color, "green")
  H.eq("T10 patch.updated_by=koreader",   update_calls[1] and update_calls[1].patch.updated_by, "koreader")
end

-- ── T11: push_changes_only — no drift → no PATCH sent ────────────────────

do
  reset_modules()
  local update_calls = {}
  package.loaded["caudex.ai_client"] = {
    listHighlights  = function() return { highlights = {} } end,
    updateHighlight = function(_sha, id, patch)
      table.insert(update_calls, { id = id, patch = patch })
      return {}
    end,
  }

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-011",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "blue",
    bookaware_synced_note  = "my note",
    color                  = "blue",
    note                   = "my note",
  })

  local AS = require("caudex.annotation_sync")
  local r  = AS.push_changes_only(ui)

  H.eq("T11 pushed=0",                 r.pushed, 0)
  H.eq("T11 no updateHighlight calls", #update_calls, 0)
end

-- ── T12: push failures are included in sync failed count ─────────────────

do
  reset_modules()
  package.loaded["caudex.ai_client"] = {
    listHighlights = function(_sha, _status, include_deleted)
      return { highlights = {} }
    end,
    updateHighlight = function()
      error("backend unavailable")
    end,
  }

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-012",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "yellow",
    bookaware_synced_note  = "old note",
    color                  = "green",
    note                   = "new note",
  })

  local AS = require("caudex.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T12 pushed=0 after backend failure", r.pushed, 0)
  H.eq("T12 failed includes push failure",   r.failed, 1)
  H.eq("T12 synced color unchanged",         ui.annotation.annotations[1].bookaware_synced_color, "yellow")
  H.eq("T12 synced note unchanged",          ui.annotation.annotations[1].bookaware_synced_note, "old note")
end

-- ── T13: tombstone fetch failures propagate instead of reporting success ──

do
  reset_modules()
  package.loaded["caudex.ai_client"] = {
    listHighlights = function(_sha, _status, include_deleted)
      if include_deleted then error("tombstone fetch failed") end
      return { highlights = {} }
    end,
    updateHighlight = function() return {} end,
  }

  local ui = make_ui(function() return {} end)
  local AS = require("caudex.annotation_sync")
  local ok, err = pcall(function() AS.sync(ui) end)

  H.is_false("T13 sync raises on tombstone fetch failure", ok)
  H.contains("T13 error mentions tombstone failure", tostring(err), "tombstone fetch failed")
end

-- ── T14: backend resolution failure does not duplicate local annotations ──

do
  reset_modules()
  local pending = {
    {
      id     = "hl-014",
      exact  = "retry duplicate sentinel",
      prefix = "before ",
      suffix = " after",
    },
  }
  package.loaded["caudex.ai_client"] = {
    listHighlights = function(_sha, _status, include_deleted)
      if include_deleted then return { highlights = {} } end
      return { highlights = pending }
    end,
    updateHighlight = function()
      error("backend resolution failed")
    end,
  }

  local ui = make_ui(function(self, text)
    if text == "retry duplicate sentinel" then
      return {{
        start     = "/body/p[14].0",
        ["end"]   = "/body/p[14].24",
        prev_text = "before ",
        next_text = " after",
      }}
    end
    return {}
  end)

  local AS = require("caudex.annotation_sync")
  local r1 = AS.sync(ui)
  local r2 = AS.sync(ui)

  H.eq("T14 first sync counted failed",       r1.failed, 1)
  H.eq("T14 second sync counted failed",      r2.failed, 1)
  H.eq("T14 addItem called only once",        #ui.annotation._calls, 1)
  H.eq("T14 annotation table has one item",   #ui.annotation.annotations, 1)
  H.eq("T14 stored backend id",               ui.annotation.annotations[1].bookaware_highlight_id, "hl-014")
end

-- ══════════════════════════════════════════════════════════════════════════
-- Phase 3d (new): push_new — upload KOReader-created highlights to backend
-- ══════════════════════════════════════════════════════════════════════════

-- ── T15: brand-new annotation (no backend id) → POST sent, id written back ──

do
  reset_modules()
  local _, updates, creates = make_ai_client_p3({}, {})

  local ui = make_ui(function() return {} end, {
    contexts = {
      ["/body/p[3].0|/body/p[3].40"] = { "Earlier context. ", " Trailing context." },
    },
  })
  -- A purely-local annotation: created by user in KOReader, never seen by web.
  table.insert(ui.annotation.annotations, {
    text    = "freshly highlighted on the e-reader",
    pos0    = "/body/p[3].0",
    pos1    = "/body/p[3].40",
    chapter = "Chapter 3",
    color   = "yellow",
    note    = "first note",
  })

  local AS = require("caudex.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T15 created=1",          r.created, 1)
  H.eq("T15 pushed=0",           r.pushed, 0)
  H.eq("T15 createHighlight called once", #creates, 1)
  H.eq("T15 payload.exact",       creates[1].payload.exact, "freshly highlighted on the e-reader")
  H.eq("T15 payload.prefix",      creates[1].payload.prefix, "Earlier context. ")
  H.eq("T15 payload.suffix",      creates[1].payload.suffix, " Trailing context.")
  H.eq("T15 payload.chapter",     creates[1].payload.chapter, "Chapter 3")
  H.eq("T15 payload.color",       creates[1].payload.color, "yellow")
  H.eq("T15 payload.note",        creates[1].payload.note,  "first note")
  H.eq("T15 payload.source",      creates[1].payload.source, "koreader")
  H.eq("T15 payload.koreader.status", creates[1].payload.koreader.status, "resolved")
  H.eq("T15 payload.koreader.pos0",   creates[1].payload.koreader.pos0,   "/body/p[3].0")
  H.eq("T15 payload.koreader.pos1",   creates[1].payload.koreader.pos1,   "/body/p[3].40")
  H.is_true("T15 payload.client_id non-empty",
    type(creates[1].payload.client_id) == "string" and #creates[1].payload.client_id > 0)

  local ann = ui.annotation.annotations[1]
  H.eq("T15 backend id written back",     ann.bookaware_highlight_id, "hl-new-001")
  H.eq("T15 sha256 written back",         ann.bookaware_sha256, SHA)
  H.eq("T15 synced_color baseline",       ann.bookaware_synced_color, "yellow")
  H.eq("T15 synced_note baseline",        ann.bookaware_synced_note,  "first note")
  H.is_true("T15 client_id persisted",
    type(ann.bookaware_client_id) == "string" and #ann.bookaware_client_id > 0)
end

-- ── T16: idempotency — second sync does NOT re-POST the same annotation ────

do
  reset_modules()
  local _, _, creates = make_ai_client_p3({}, {})

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    text = "idempotent line",
    pos0 = "/body/p[4].0",
    pos1 = "/body/p[4].16",
    color = "blue",
  })

  local AS = require("caudex.annotation_sync")
  AS.sync(ui)
  AS.sync(ui)

  H.eq("T16 only one POST across two syncs", #creates, 1)
  H.eq("T16 annotation still single",        #ui.annotation.annotations, 1)
end

-- ── T17: client_id is stable across retries (same hash for same pos0/pos1/text) ──

do
  reset_modules()
  -- Use a stub AI client that always fails the first POST, succeeds the second.
  local attempts = {}
  package.loaded["caudex.ai_client"] = {
    listHighlights = function(_s, _st, inc) return { highlights = {} } end,
    updateHighlight = function() return {} end,
    createHighlight = function(_sha, payload)
      table.insert(attempts, payload.client_id)
      if #attempts == 1 then error("simulated network drop") end
      return { ok = true, highlight = { id = "hl-retry", exact = payload.exact, koreader = payload.koreader } }
    end,
  }

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    text = "retry me",
    pos0 = "/body/p[5].0",
    pos1 = "/body/p[5].8",
  })

  local AS = require("caudex.annotation_sync")
  local r1 = AS.sync(ui)
  local r2 = AS.sync(ui)

  H.eq("T17 first sync created=0 (POST failed)", r1.created, 0)
  H.eq("T17 first sync failed includes push_new", r1.failed >= 1, true)
  H.eq("T17 second sync created=1 (retry success)", r2.created, 1)
  H.eq("T17 same client_id sent on both attempts", attempts[1], attempts[2])
end

-- ── T18: push_new skipped on non-rolling (PDF) documents ───────────────────

do
  reset_modules()
  local _, _, creates = make_ai_client_p3({}, {})

  local ui = make_ui(function() return {} end)
  ui.rolling = nil  -- pretend this is a PDF
  table.insert(ui.annotation.annotations, {
    text = "pdf highlight",
    pos0 = "/body/p[1].0",
    pos1 = "/body/p[1].12",
  })

  local AS = require("caudex.annotation_sync")
  -- sync() itself requires ui.rolling (Phase 1 guard), so we exercise via
  -- a direct sanity check: sync should refuse to run.
  local ok = pcall(AS.sync, ui)
  H.eq("T18 sync rejected without ui.rolling", ok, false)
  H.eq("T18 no POSTs attempted",                #creates, 0)
end

-- ── T19: annotation missing pos0/pos1 is silently skipped (no POST, no fail) ──

do
  reset_modules()
  local _, _, creates = make_ai_client_p3({}, {})

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    text = "no-anchor highlight",
    -- intentionally no pos0/pos1
    color = "green",
  })

  local AS = require("caudex.annotation_sync")
  local r = AS.sync(ui)

  H.eq("T19 created=0 when pos missing", r.created, 0)
  H.eq("T19 failed=0 when pos missing",  r.failed, 0)
  H.eq("T19 no POST sent",               #creates, 0)
end

-- ── T20: push order — tombstoned id is NOT patched even if local has drift ──

do
  reset_modules()
  local update_calls = {}
  package.loaded["caudex.ai_client"] = {
    listHighlights = function(_s, _st, inc)
      if inc then
        return { highlights = {
          { id = "hl-020", exact = "to be deleted", deleted_at = "2026-01-01T00:00:00Z" },
        } }
      end
      return { highlights = {} }
    end,
    updateHighlight = function(_sha, id, patch)
      table.insert(update_calls, { id = id, patch = patch })
      return {}
    end,
    createHighlight = function() error("should not be called in T20") end,
  }

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-020",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "yellow",
    bookaware_synced_note  = "",
    color                  = "blue",  -- locally changed
    note                   = "",
  })

  local AS = require("caudex.annotation_sync")
  local r  = AS.sync(ui)

  H.eq("T20 no PATCH sent for tombstoned id", #update_calls, 0)
  H.eq("T20 pushed=0", r.pushed, 0)
  H.eq("T20 failed=0", r.failed, 0)
  H.eq("T20 removed=1", r.removed, 1)
  H.eq("T20 local annotation removed", #ui.annotation.annotations, 0)
end

-- ── T21: field-level diff — color-only change does NOT send note in PATCH ──

do
  reset_modules()
  local _, updates = make_ai_client_p3({}, {})

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-021",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "yellow",
    bookaware_synced_note  = "kept from web",
    color                  = "green",            -- changed
    note                   = "kept from web",    -- NOT changed
  })

  local AS = require("caudex.annotation_sync")
  AS.sync(ui)

  H.eq("T21 exactly one PATCH",          #updates, 1)
  H.eq("T21 PATCH includes color",       updates[1].patch.color, "green")
  H.eq("T21 PATCH omits note (no drift)",updates[1].patch.note,  nil)
end

-- ── T22: field-level diff — note-only change does NOT send color in PATCH ──

do
  reset_modules()
  local _, updates = make_ai_client_p3({}, {})

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-022",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "yellow",
    bookaware_synced_note  = "",
    color                  = "yellow",
    note                   = "freshly added",
  })

  local AS = require("caudex.annotation_sync")
  AS.sync(ui)

  H.eq("T22 exactly one PATCH",            #updates, 1)
  H.eq("T22 PATCH includes note",          updates[1].patch.note, "freshly added")
  H.eq("T22 PATCH omits color (no drift)", updates[1].patch.color, nil)
end

-- ── T23: push_changes_only silently no-ops on non-EPUB documents ──────────

do
  reset_modules()
  -- ai_client must NOT be reached for PDF; load a stub that explodes on call.
  package.loaded["caudex.ai_client"] = {
    listHighlights  = function() error("should not call listHighlights") end,
    updateHighlight = function() error("should not call updateHighlight") end,
    createHighlight = function() error("should not call createHighlight") end,
  }

  local ui = make_ui(function() return {} end)
  ui.rolling = nil  -- non-EPUB

  local AS = require("caudex.annotation_sync")
  local r
  H.no_error("T23 push_changes_only on PDF does not raise", function()
    r = AS.push_changes_only(ui)
  end)
  H.eq("T23 pushed=0 for PDF", r and r.pushed, 0)
  H.eq("T23 failed=0 for PDF", r and r.failed, 0)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Review-fix regression tests
-- ══════════════════════════════════════════════════════════════════════════

-- ── T24: extract_context must NOT draw a stray selection during sync ────────
-- CreDocument:getSelectedWordContext with restore_selection=true re-marks the
-- *passed-in* pos0..pos1 as the live crengine selection (and draws it on the
-- next refresh). That is correct for ReaderHighlight where pos0..pos1 IS the
-- user's live selection, but wrong for our background sync over historical
-- annotations: it would paint a blue selection rectangle on whichever
-- annotation was processed last. So push_new must call with false.

do
  reset_modules()
  local _, _, creates = make_ai_client_p3({}, {})

  local got_restore_arg
  local ui = make_ui(function() return {} end)
  ui.document.getSelectedWordContext = function(_self, _word, _nb, _p0, _p1, restore_selection)
    got_restore_arg = restore_selection
    return "ctx_prev", "ctx_next"
  end

  table.insert(ui.annotation.annotations, {
    text = "selection-preservation test",
    pos0 = "/body/p[9].0",
    pos1 = "/body/p[9].27",
  })

  local AS = require("caudex.annotation_sync")
  AS.sync(ui)

  H.eq("T24 getSelectedWordContext called with restore_selection=false",
    got_restore_arg, false)
  H.eq("T24 prefix wired through to payload", creates[1].payload.prefix, "ctx_prev")
  H.eq("T24 suffix wired through to payload", creates[1].payload.suffix, "ctx_next")
end

-- ── T25: make_client_id raises (does not fall back) when sha2 unavailable ──
-- Loud failure is required — a low-entropy fallback key would collide and
-- silently de-duplicate distinct annotations on the backend.

do
  reset_modules()
  -- Replace util.sha256_string with a broken implementation that returns nil.
  local util = package.loaded["caudex.util"]
  util.sha256_string = function() return nil, "ffi/sha2.sha256 unavailable" end

  local _, _, creates = make_ai_client_p3({}, {})
  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    text = "no sha available",
    pos0 = "/body/p[10].0",
    pos1 = "/body/p[10].17",
  })

  local AS = require("caudex.annotation_sync")
  local r = AS.sync(ui)

  -- The pcall inside push_new converts the raised error into a counted failure,
  -- and the message must mention the underlying SHA256 problem.
  H.eq("T25 created=0 when sha2 unavailable", r.created, 0)
  H.eq("T25 failed=1 reported",               r.failed, 1)
  H.eq("T25 no POST attempted",               #creates, 0)
  H.is_true("T25 create_errors populated",
    type(r.create_errors) == "table" and #r.create_errors == 1)
  H.contains("T25 error message mentions SHA256",
    r.create_errors[1] and r.create_errors[1].message, "SHA256")
end

-- ── T26: push_new surfaces per-annotation failure detail in create_errors ──
-- Network/backend failure during POST must be captured (client_id, exact
-- snippet, message) so the UI layer can surface a meaningful error.

do
  reset_modules()
  package.loaded["caudex.ai_client"] = {
    listHighlights  = function(_s, _st, _inc) return { highlights = {} } end,
    updateHighlight = function() return {} end,
    createHighlight = function(_sha, _payload)
      error("HTTP 503 backend unavailable")
    end,
  }

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    text = "diagnostic-bearing annotation text long enough to truncate",
    pos0 = "/body/p[11].0",
    pos1 = "/body/p[11].58",
  })

  local AS = require("caudex.annotation_sync")
  local r = AS.sync(ui)

  H.eq("T26 created=0 on POST failure",     r.created, 0)
  H.eq("T26 failed=1 reported",             r.failed, 1)
  H.eq("T26 create_errors has one entry",   #r.create_errors, 1)
  local detail = r.create_errors[1]
  H.is_true("T26 error.client_id present",
    type(detail.client_id) == "string" and detail.client_id:sub(1, 9) == "koreader-")
  H.is_true("T26 error.exact contains the source text",
    type(detail.exact) == "string"
      and detail.exact:sub(1, 30) == "diagnostic-bearing annotation ")
  H.contains("T26 error.message preserves backend error",
    detail.message, "503")
end

-- ── T27: delete_highlight_only tombstones a locally deleted synced highlight ─

do
  reset_modules()
  local _, _, _, deletes = make_ai_client_p3({}, {})
  local ui = make_ui(function() return {} end)

  local AS = require("caudex.annotation_sync")
  local r = AS.delete_highlight_only(ui, {
    bookaware_highlight_id = "hl-del-027",
    bookaware_sha256       = SHA,
  })

  H.eq("T27 deleted=1", r.deleted, 1)
  H.eq("T27 failed=0", r.failed, 0)
  H.eq("T27 deleteHighlight called once", #deletes, 1)
  H.eq("T27 delete origin is koreader", deletes[1] and deletes[1].by, "koreader")
  H.eq("T27 pending queue drained", #(ui._settings.bookaware_pending_deletes or {}), 0)
end

-- ── T28: delete_highlight_only ignores annotations from another book ──────

do
  reset_modules()
  local _, _, _, deletes = make_ai_client_p3({}, {})
  local ui = make_ui(function() return {} end)

  local AS = require("caudex.annotation_sync")
  local r = AS.delete_highlight_only(ui, {
    bookaware_highlight_id = "hl-other-book",
    bookaware_sha256       = string.rep("b", 64),
  })

  H.eq("T28 deleted=0", r.deleted, 0)
  H.eq("T28 failed=0", r.failed, 0)
  H.eq("T28 no delete call", #deletes, 0)
end

-- ── T29: failed backend delete remains queued for a later sync retry ──────

do
  reset_modules()
  local delete_calls = 0
  package.loaded["caudex.ai_client"] = {
    listHighlights = function() return { highlights = {} } end,
    deleteHighlight = function()
      delete_calls = delete_calls + 1
      error("backend unavailable")
    end,
  }
  local ui = make_ui(function() return {} end)

  local AS = require("caudex.annotation_sync")
  local r = AS.delete_highlight_only(ui, {
    bookaware_highlight_id = "hl-pending-029",
    bookaware_sha256       = SHA,
  })

  H.eq("T29 failed=1", r.failed, 1)
  H.eq("T29 delete attempted once", delete_calls, 1)
  H.eq("T29 pending delete persisted",
    ui._settings.bookaware_pending_deletes[1], "hl-pending-029")
end

-- ── T30: full sync drains queued pending deletes ──────────────────────────

do
  reset_modules()
  local _, _, _, deletes = make_ai_client_p3({}, {})
  local ui = make_ui(function() return {} end, {
    settings = { bookaware_pending_deletes = { "hl-pending-030" } },
  })

  local AS = require("caudex.annotation_sync")
  local r = AS.sync(ui)

  H.eq("T30 deleteHighlight called once", #deletes, 1)
  H.eq("T30 deleted count reported", r.deleted, 1)
  H.eq("T30 pending queue drained", #(ui._settings.bookaware_pending_deletes or {}), 0)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Repair missing local annotations from active backend highlights
-- ══════════════════════════════════════════════════════════════════════════

-- ── T31: repair pulls active resolved highlights and writes missing local annotation

do
  reset_modules()
  local list_calls = {}
  local update_calls = {}
  package.loaded["caudex.ai_client"] = {
    listHighlights = function(_sha, status, include_deleted)
      table.insert(list_calls, { status = status, include_deleted = include_deleted })
      return { highlights = {
        {
          id = "hl-repair-031",
          exact = "already resolved remotely",
          color = "green",
          note = "web note",
          chapter = "Repair Chapter",
          source = "reader-web",
          koreader = {
            status = "resolved",
            pos0 = "/body/p[31].0",
            pos1 = "/body/p[31].25",
            page = "31",
          },
        },
      } }
    end,
    updateHighlight = function(_sha, id, patch)
      table.insert(update_calls, { id = id, patch = patch })
      return {}
    end,
  }

  local ui = make_ui(function() error("repair should use resolved backend anchors") end)

  local AS = require("caudex.annotation_sync")
  local r = AS.repair_missing_highlights(ui)

  H.eq("T31 repaired=1", r.repaired, 1)
  H.eq("T31 failed=0", r.failed, 0)
  H.eq("T31 active list called once", #list_calls, 1)
  H.eq("T31 list filters to resolved", list_calls[1].status, "resolved")
  H.eq("T31 list does not request tombstones", list_calls[1].include_deleted, nil)
  H.eq("T31 no backend PATCH for already-resolved row", #update_calls, 0)
  H.eq("T31 addItem called once", #ui.annotation._calls, 1)

  local ann = ui.annotation.annotations[1]
  H.eq("T31 restored backend id", ann.bookaware_highlight_id, "hl-repair-031")
  H.eq("T31 restored sha", ann.bookaware_sha256, SHA)
  H.eq("T31 restored pos0", ann.pos0, "/body/p[31].0")
  H.eq("T31 restored pos1", ann.pos1, "/body/p[31].25")
  H.eq("T31 restored color", ann.color, "green")
  H.eq("T31 restored note", ann.note, "web note")
  H.eq("T31 annotations saved", ui._settings.annotations, ui.annotation.annotations)
end

-- ── T32: repair is idempotent when the backend highlight already exists locally

do
  reset_modules()
  package.loaded["caudex.ai_client"] = {
    listHighlights = function()
      return { highlights = {
        {
          id = "hl-repair-032",
          exact = "local copy already present",
          koreader = {
            status = "resolved",
            pos0 = "/body/p[32].0",
            pos1 = "/body/p[32].26",
          },
        },
      } }
    end,
    updateHighlight = function() error("repair should not patch existing rows") end,
  }

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-repair-032",
    bookaware_sha256       = SHA,
    text                   = "local copy already present",
    pos0                   = "/body/p[32].0",
    pos1                   = "/body/p[32].26",
  })

  local AS = require("caudex.annotation_sync")
  local r = AS.repair_missing_highlights(ui)

  H.eq("T32 repaired=0", r.repaired, 0)
  H.eq("T32 skipped=1", r.skipped, 1)
  H.eq("T32 failed=0", r.failed, 0)
  H.eq("T32 no duplicate addItem", #ui.annotation._calls, 0)
  H.eq("T32 annotation count stays one", #ui.annotation.annotations, 1)
  H.eq("T32 no save when unchanged", ui._settings.annotations, nil)
end

-- ── T33: repair reports failed when an active row has no usable anchor

do
  reset_modules()
  package.loaded["caudex.ai_client"] = {
    listHighlights = function()
      return { highlights = {
        {
          id = "hl-repair-033",
          exact = "cannot be found locally",
          koreader = { status = "resolved" },
        },
      } }
    end,
    updateHighlight = function() error("repair should not mark backend rows failed") end,
  }

  -- findAllText must not be consulted: repair requires pre-disambiguated
  -- anchors and must fail loudly when they are missing.
  local ui = make_ui(function() error("repair must not call findAllText") end)

  local AS = require("caudex.annotation_sync")
  local r = AS.repair_missing_highlights(ui)

  H.eq("T33 repaired=0", r.repaired, 0)
  H.eq("T33 failed=1", r.failed, 1)
  H.eq("T33 no annotation written", #ui.annotation.annotations, 0)
end

-- ── T34: repair never falls back to ambiguous text search
--
-- Even if findAllText would return multiple matches for the exact text,
-- repair must not pick one — that would bypass the normal sync path's
-- scoring/margin disambiguation and could silently anchor at the wrong
-- location. The row is reported as failed and no annotation is written.

do
  reset_modules()
  package.loaded["caudex.ai_client"] = {
    listHighlights = function()
      return { highlights = {
        {
          id = "hl-repair-034",
          exact = "the",
          -- No koreader.pos0 / pos1: anchors were never resolved.
          koreader = { status = "resolved" },
        },
      } }
    end,
    updateHighlight = function() error("repair should not patch backend rows") end,
  }

  local find_calls = 0
  local ui = make_ui(function()
    find_calls = find_calls + 1
    return {
      { start = "/body/p[1].0",  ["end"] = "/body/p[1].3"  },
      { start = "/body/p[2].0",  ["end"] = "/body/p[2].3"  },
      { start = "/body/p[3].0",  ["end"] = "/body/p[3].3"  },
    }
  end)

  local AS = require("caudex.annotation_sync")
  local r = AS.repair_missing_highlights(ui)

  H.eq("T34 repaired=0", r.repaired, 0)
  H.eq("T34 failed=1", r.failed, 1)
  H.eq("T34 no annotation written", #ui.annotation.annotations, 0)
  H.eq("T34 findAllText never called", find_calls, 0)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Server-authoritative normal sync
-- ══════════════════════════════════════════════════════════════════════════

-- ── T35: normal sync reinstates backend-resolved highlights missing locally

do
  reset_modules()
  local list_calls = {}
  package.loaded["caudex.ai_client"] = {
    listHighlights = function(_sha, status, include_deleted)
      table.insert(list_calls, { status = status, include_deleted = include_deleted })
      if include_deleted then
        return { highlights = {
          {
            id = "hl-sync-repair-035",
            exact = "resolved row missing from sidecar",
            color = "purple",
            note = "restore me",
            koreader = {
              status = "resolved",
              pos0 = "/body/p[35].0",
              pos1 = "/body/p[35].33",
            },
          },
        } }
      end
      return { highlights = {} }
    end,
    updateHighlight = function() return {} end,
    createHighlight = function() error("no local-only annotations in T35") end,
    deleteHighlight = function() return {} end,
  }

  local find_calls = 0
  local ui = make_ui(function()
    find_calls = find_calls + 1
    return {}
  end)

  local AS = require("caudex.annotation_sync")
  local r = AS.sync(ui)

  H.eq("T35 repaired=1 during normal sync", r.repaired, 1)
  H.eq("T35 failed=0", r.failed, 0)
  H.eq("T35 annotation restored", #ui.annotation.annotations, 1)
  H.eq("T35 restored backend id", ui.annotation.annotations[1].bookaware_highlight_id, "hl-sync-repair-035")
  H.eq("T35 restored note", ui.annotation.annotations[1].note, "restore me")
  H.eq("T35 findAllText not used for resolved repair", find_calls, 0)
  H.eq("T35 annotations saved", ui._settings.annotations, ui.annotation.annotations)
  H.eq("T35 include_deleted fetch happened", list_calls[2] and list_calls[2].include_deleted, true)
end

-- ── T36: large backend tombstone batch requires explicit confirmation

do
  reset_modules()
  local all_with_deleted = {}
  for i = 1, 6 do
    table.insert(all_with_deleted, {
      id = "hl-large-del-036-" .. i,
      exact = "deleted row " .. i,
      deleted_at = "2026-01-01T00:00:00Z",
    })
  end
  local _, _, _, deletes = make_ai_client_p3({}, all_with_deleted)
  local ui = make_ui(function() return {} end)
  for i = 1, 6 do
    table.insert(ui.annotation.annotations, {
      bookaware_highlight_id = "hl-large-del-036-" .. i,
      bookaware_sha256 = SHA,
      text = "local row " .. i,
    })
  end

  local AS = require("caudex.annotation_sync")
  local ok, err = pcall(AS.sync, ui)

  H.is_false("T36 sync refuses large removal without force", ok)
  H.is_true("T36 error is confirmation table",
    type(err) == "table" and err.bookaware_confirmation_required == true)
  H.eq("T36 pending_removals=6", err and err.pending_removals, 6)
  H.eq("T36 local annotations not removed", #ui.annotation.annotations, 6)
  H.eq("T36 no backend deletes attempted", #deletes, 0)
end

-- ── T37: force option applies the same large tombstone batch

do
  reset_modules()
  local all_with_deleted = {}
  for i = 1, 6 do
    table.insert(all_with_deleted, {
      id = "hl-large-del-037-" .. i,
      exact = "deleted row " .. i,
      deleted_at = "2026-01-01T00:00:00Z",
    })
  end
  local _, _, _, deletes = make_ai_client_p3({}, all_with_deleted)
  local ui = make_ui(function() return {} end)
  for i = 1, 6 do
    table.insert(ui.annotation.annotations, {
      bookaware_highlight_id = "hl-large-del-037-" .. i,
      bookaware_sha256 = SHA,
      text = "local row " .. i,
    })
  end

  local AS = require("caudex.annotation_sync")
  local r = AS.sync(ui, { force = true })

  H.eq("T37 removed=6 with force", r.removed, 6)
  H.eq("T37 pending_removals reported", r.pending_removals, 6)
  H.eq("T37 local annotations removed", #ui.annotation.annotations, 0)
  H.eq("T37 no backend deletes attempted", #deletes, 0)
end

-- ── T38: normal sync pulls backend note/color when local is clean

do
  reset_modules()
  package.loaded["caudex.ai_client"] = {
    listHighlights = function(_sha, _status, include_deleted)
      if include_deleted then
        return { highlights = {
          {
            id = "hl-metadata-038",
            exact = "metadata row",
            color = "blue",
            note = "web-updated note",
            koreader = { status = "resolved", pos0 = "/body/p[38].0", pos1 = "/body/p[38].12" },
          },
        } }
      end
      return { highlights = {} }
    end,
    updateHighlight = function() error("clean local row must not push back") end,
    createHighlight = function() error("no create in T38") end,
    deleteHighlight = function() return {} end,
  }

  local ui = make_ui(function() return {} end)
  table.insert(ui.annotation.annotations, {
    bookaware_highlight_id = "hl-metadata-038",
    bookaware_sha256       = SHA,
    bookaware_synced_color = "yellow",
    bookaware_synced_note  = "old note",
    color                  = "yellow",
    note                   = "old note",
  })

  local AS = require("caudex.annotation_sync")
  local r = AS.sync(ui)

  H.eq("T38 pulled=1", r.pulled, 1)
  H.eq("T38 pushed=0", r.pushed, 0)
  H.eq("T38 note pulled", ui.annotation.annotations[1].note, "web-updated note")
  H.eq("T38 color pulled", ui.annotation.annotations[1].color, "blue")
  H.eq("T38 synced note baseline updated", ui.annotation.annotations[1].bookaware_synced_note, "web-updated note")
  H.eq("T38 annotations saved", ui._settings.annotations, ui.annotation.annotations)
end
