-- Tests for automatic web highlight sync lifecycle (Phase 4 auto-sync)
-- Tests main.lua: auto-sync on open, push-only on close, FileManager guard.

local H = require("spec.helpers")
H.section("G. auto sync lifecycle (main.lua)")

local SHA = string.rep("c", 64)

-- Build a minimal reader UI (not FileManager).
local function make_reader_ui()
  return {
    menu = { registerToMainMenu = function() end },
    highlight = {
      addToHighlightDialog = function() end,
    },
    document = { file = "/fake/book.epub" },
    annotation = { annotations = {} },
    doc_settings = {
      readSetting = function(_, k) return k == "file_sha256" and SHA or nil end,
      saveSetting = function() end,
    },
    rolling = true,
    handleEvent = function() end,
  }
end

-- Shared stubs required by every main.lua load.
local function setup_stubs(sync_calls, push_calls, cfg_override, push_new_calls, delete_calls, queue_calls)
  push_new_calls = push_new_calls or {}
  delete_calls = delete_calls or {}
  queue_calls = queue_calls or {}
  package.loaded["caudex.dialog_controller"] = { show = function() end }
  package.loaded["caudex.background_jobs"]   = {
    submit_summary    = function() end,
    submit_analyze    = function() end,
    show_results_menu = function() end,
  }
  package.loaded["caudex.book_upload"] = {
    upload_current = function() end,
    upload_file    = function() end,
  }
  package.loaded["caudex.book_sync"] = { sync_all = function() end }
  package.loaded["caudex.annotation_sync"] = {
    sync = function(_ui)
      table.insert(sync_calls, true)
      return { resolved = 0, conflict = 0, failed = 0, pushed = 0, removed = 0 }
    end,
    push_changes_only = function(_ui)
      table.insert(push_calls, true)
      return { pushed = 0, failed = 0 }
    end,
    push_new_highlights_only = function(_ui)
      table.insert(push_new_calls, true)
      return { created = 1, failed = 0, errors = {} }
    end,
    queue_deleted_highlight = function(_ui, item)
      table.insert(queue_calls, item and item.bookaware_highlight_id or true)
      return { queued = 1 }
    end,
    push_pending_deletes_only = function(_ui)
      table.insert(delete_calls, true)
      return { deleted = 1, failed = 0 }
    end,
    delete_highlight_only = function(_ui, item)
      table.insert(delete_calls, item and item.bookaware_highlight_id or true)
      return { deleted = 1, failed = 0 }
    end,
    list_conflicts = function() return {} end,
  }
  package.loaded["caudex.config"] = {
    validate = function() return true, {} end,
    get      = function() return cfg_override or {} end,
  }
  package.loaded["ui/elements/reader_menu_order"] = {
    navi = { "table_of_contents", "bookmarks" },
  }
end

-- ── T-AS1: auto_sync_web_highlights=false → sync NOT triggered on open ─────

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = false })

  local Caudex   = require("main")
  local fake_self = { ui = make_reader_ui() }
  Caudex.init(fake_self)

  for _, s in ipairs(spy.scheduled) do s.fn() end

  H.eq("T-AS1 config=false: sync not triggered on open", #sync_calls, 0)
end

-- ── T-AS2: config=true + reader UI → sync called once on open ─────────────

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true })

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }
  Caudex.init(fake_self)

  for _, s in ipairs(spy.scheduled) do s.fn() end

  H.eq("T-AS2 config=true reader: sync called once on open", #sync_calls, 1)
end

-- ── T-AS3: FileManager context → sync NOT triggered even with config=true ──

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true })

  local Caudex    = require("main")
  local fake_fm   = {
    ui = {
      menu                 = { registerToMainMenu = function() end },
      addFileDialogButtons = function() end,
    }
  }
  Caudex.init(fake_fm)

  for _, s in ipairs(spy.scheduled) do s.fn() end

  H.eq("T-AS3 FileManager: sync not triggered", #sync_calls, 0)
end

-- ── T-AS4: config=true → onCloseDocument triggers push_changes_only ────────

do
  H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true })

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }

  H.no_error("T-AS4 onCloseDocument runs without error", function()
    Caudex.onCloseDocument(fake_self)
  end)
  H.eq("T-AS4 onCloseDocument triggers push_changes_only", #push_calls, 1)
end

-- ── T-AS5: config=false → onCloseDocument does NOT push ───────────────────

do
  H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = false })

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }
  Caudex.onCloseDocument(fake_self)

  H.eq("T-AS5 config=false: onCloseDocument does not push", #push_calls, 0)
end

-- ── T-AS6: config=true → onSaveSettings triggers push_changes_only ────────

do
  H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true })

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }

  H.no_error("T-AS6 onSaveSettings runs without error", function()
    Caudex.onSaveSettings(fake_self)
  end)
  H.eq("T-AS6 onSaveSettings triggers push_changes_only", #push_calls, 1)
end

-- ── T-AS7: new local highlight schedules push_new_highlights_only ─────────

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls = {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_upload_new_highlights = true }, push_new_calls)

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }

  Caudex.onAnnotationsModified(fake_self, {
    { text = "local highlight", pos0 = "/p.0", pos1 = "/p.15" },
    nb_highlights_added = 1,
  })
  H.eq("T-AS7 new highlight schedules one upload", #spy.scheduled, 1)
  for _, s in ipairs(spy.scheduled) do s.fn() end
  H.eq("T-AS7 scheduled upload calls push_new_highlights_only", #push_new_calls, 1)
end

-- ── T-AS8: web-created annotations are not re-uploaded ───────────────────

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls = {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_upload_new_highlights = true }, push_new_calls)

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }

  Caudex.onAnnotationsModified(fake_self, {
    { text = "web highlight", bookaware_highlight_id = "hl-web" },
    nb_highlights_added = 1,
  })
  H.eq("T-AS8 web highlight schedules no upload", #spy.scheduled, 0)
  H.eq("T-AS8 web highlight does not call push_new", #push_new_calls, 0)
end

-- ── T-AS9: auto_sync_web_highlights=true also enables new-highlight upload ─

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls = {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true }, push_new_calls)

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }

  Caudex.onAnnotationsModified(fake_self, {
    { text = "local highlight", pos0 = "/p.0", pos1 = "/p.15" },
    nb_highlights_added = 1,
  })
  for _, s in ipairs(spy.scheduled) do s.fn() end
  H.eq("T-AS9 auto_sync enables new highlight upload", #push_new_calls, 1)
end

-- ── T-AS10: local deletion of synced highlight tombstones backend ─────────

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls, delete_calls, queue_calls = {}, {}, {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true }, push_new_calls, delete_calls, queue_calls)

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }

  Caudex.onAnnotationsModified(fake_self, {
    { text = "synced highlight", bookaware_highlight_id = "hl-delete-me", bookaware_sha256 = SHA },
    nb_highlights_added = -1,
    index_modified = -1,
  })
  H.eq("T-AS10 deletion queues tombstone", #queue_calls, 1)
  H.eq("T-AS10 queued id forwarded", queue_calls[1], "hl-delete-me")
  H.eq("T-AS10 deletion schedules tombstone push", #spy.scheduled, 1)
  for _, s in ipairs(spy.scheduled) do s.fn() end
  H.eq("T-AS10 push_pending_deletes_only called", #delete_calls, 1)
end

-- ── T-AS11: web tombstone application is not echoed back as local delete ──

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls, delete_calls = {}, {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true }, push_new_calls, delete_calls)

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }

  Caudex.onAnnotationsModified(fake_self, {
    { text = "web deleted highlight", bookaware_highlight_id = "hl-web-deleted" },
    nb_highlights_added = -1,
    index_modified = -1,
    bookaware_origin = "tombstone_apply",
  })
  H.eq("T-AS11 web tombstone schedules no backend delete", #spy.scheduled, 0)
  H.eq("T-AS11 push_pending_deletes_only not called", #delete_calls, 0)
end

-- ── T-AS12: config failure does not lose local delete intent ──────────────

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls, delete_calls, queue_calls = {}, {}, {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true }, push_new_calls, delete_calls, queue_calls)
  package.loaded["caudex.config"].validate = function() return false, "bad config" end

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }

  Caudex.onAnnotationsModified(fake_self, {
    { text = "synced highlight", bookaware_highlight_id = "hl-queue-only", bookaware_sha256 = SHA },
    nb_highlights_added = -1,
    index_modified = -1,
  })
  H.eq("T-AS12 deletion queues despite config failure", #queue_calls, 1)
  for _, s in ipairs(spy.scheduled) do s.fn() end
  H.eq("T-AS12 config failure prevents immediate push", #delete_calls, 0)
end

-- ── T-AS13: deleting a highlight-with-note tombstones backend ─────────────
-- KOReader's ReaderBookmark:removeItemByIndex emits `nb_notes_added = -1`
-- (no nb_highlights_added) when the removed item carries a note. The bug
-- before this regression test was: only nb_highlights_added < 0 was treated
-- as a delete, so synced highlights that had a note attached were never
-- tombstoned and got reinstated by the next sync's reinstate_missing pass.

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls, delete_calls, queue_calls = {}, {}, {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true }, push_new_calls, delete_calls, queue_calls)

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }

  Caudex.onAnnotationsModified(fake_self, {
    {
      text = "synced highlight with note",
      note = "my note",
      drawer = "lighten",
      bookaware_highlight_id = "hl-with-note",
      bookaware_sha256 = SHA,
    },
    nb_notes_added = -1,
    index_modified = -1,
  })
  H.eq("T-AS13 highlight-with-note deletion queues tombstone", #queue_calls, 1)
  H.eq("T-AS13 queued id forwarded", queue_calls[1], "hl-with-note")
  for _, s in ipairs(spy.scheduled) do s.fn() end
  H.eq("T-AS13 push_pending_deletes_only called", #delete_calls, 1)
end

-- ── T-AS14: deleting only the note (highlight remains) does NOT tombstone ─
-- ReaderHighlight emits `nb_highlights_added = 1, nb_notes_added = -1` (no
-- index_modified) when the user clears the note but keeps the highlight.
-- That is a metadata edit, not a removal, and must not enqueue a delete.

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls, delete_calls, queue_calls = {}, {}, {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true }, push_new_calls, delete_calls, queue_calls)

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }

  Caudex.onAnnotationsModified(fake_self, {
    {
      text = "synced highlight, note cleared",
      drawer = "lighten",
      bookaware_highlight_id = "hl-keep-me",
      bookaware_sha256 = SHA,
    },
    nb_highlights_added = 1,
    nb_notes_added = -1,
  })
  H.eq("T-AS14 clearing a note does not queue a tombstone", #queue_calls, 0)
  H.eq("T-AS14 clearing a note does not schedule a delete push", #delete_calls, 0)
end

-- ── T-AS15: auto-sync disabled still queues tombstone on deletion ─────────
-- Regression for "delete a synced highlight, then tap manual Sync → the
-- deleted highlight comes back". Root cause: when auto_sync_web_highlights
-- is off, main.lua used to skip queue_deleted_highlight entirely, so the
-- backend row stayed active. On the next manual sync, reinstate_missing()
-- found a resolved backend highlight with no matching local annotation and
-- recreated it from the stored pos0/pos1. The fix queues the tombstone
-- unconditionally; only the immediate background DELETE push remains gated
-- on auto-sync (manual sync's drain_pending_deletes will pick it up).

do
  local spy = H.mock_koreader()
  H.reset("main", "caudex.config", "caudex.annotation_sync",
          "caudex.dialog_controller", "caudex.background_jobs",
          "caudex.book_upload", "caudex.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls, delete_calls, queue_calls = {}, {}, {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = false }, push_new_calls, delete_calls, queue_calls)

  local Caudex    = require("main")
  local fake_self = { ui = make_reader_ui() }

  Caudex.onAnnotationsModified(fake_self, {
    { text = "synced highlight", bookaware_highlight_id = "hl-offline-delete", bookaware_sha256 = SHA },
    nb_highlights_added = -1,
    index_modified = -1,
  })
  H.eq("T-AS15 auto-sync off still queues tombstone", #queue_calls, 1)
  H.eq("T-AS15 queued id forwarded", queue_calls[1], "hl-offline-delete")
  H.eq("T-AS15 auto-sync off schedules no immediate push", #spy.scheduled, 0)
  H.eq("T-AS15 auto-sync off does not call push_pending_deletes_only", #delete_calls, 0)
end
