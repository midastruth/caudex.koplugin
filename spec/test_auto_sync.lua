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
  package.loaded["askgpt.dialog_controller"] = { show = function() end }
  package.loaded["askgpt.background_jobs"]   = {
    submit_summary    = function() end,
    submit_analyze    = function() end,
    show_results_menu = function() end,
  }
  package.loaded["askgpt.book_upload"] = {
    upload_current = function() end,
    upload_file    = function() end,
  }
  package.loaded["askgpt.book_sync"] = { sync_all = function() end }
  package.loaded["askgpt.annotation_sync"] = {
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
  package.loaded["askgpt.config"] = {
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
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = false })

  local AskGPT   = require("main")
  local fake_self = { ui = make_reader_ui() }
  AskGPT.init(fake_self)

  for _, s in ipairs(spy.scheduled) do s.fn() end

  H.eq("T-AS1 config=false: sync not triggered on open", #sync_calls, 0)
end

-- ── T-AS2: config=true + reader UI → sync called once on open ─────────────

do
  local spy = H.mock_koreader()
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true })

  local AskGPT    = require("main")
  local fake_self = { ui = make_reader_ui() }
  AskGPT.init(fake_self)

  for _, s in ipairs(spy.scheduled) do s.fn() end

  H.eq("T-AS2 config=true reader: sync called once on open", #sync_calls, 1)
end

-- ── T-AS3: FileManager context → sync NOT triggered even with config=true ──

do
  local spy = H.mock_koreader()
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true })

  local AskGPT    = require("main")
  local fake_fm   = {
    ui = {
      menu                 = { registerToMainMenu = function() end },
      addFileDialogButtons = function() end,
    }
  }
  AskGPT.init(fake_fm)

  for _, s in ipairs(spy.scheduled) do s.fn() end

  H.eq("T-AS3 FileManager: sync not triggered", #sync_calls, 0)
end

-- ── T-AS4: config=true → onCloseDocument triggers push_changes_only ────────

do
  H.mock_koreader()
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true })

  local AskGPT    = require("main")
  local fake_self = { ui = make_reader_ui() }

  H.no_error("T-AS4 onCloseDocument runs without error", function()
    AskGPT.onCloseDocument(fake_self)
  end)
  H.eq("T-AS4 onCloseDocument triggers push_changes_only", #push_calls, 1)
end

-- ── T-AS5: config=false → onCloseDocument does NOT push ───────────────────

do
  H.mock_koreader()
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = false })

  local AskGPT    = require("main")
  local fake_self = { ui = make_reader_ui() }
  AskGPT.onCloseDocument(fake_self)

  H.eq("T-AS5 config=false: onCloseDocument does not push", #push_calls, 0)
end

-- ── T-AS6: config=true → onSaveSettings triggers push_changes_only ────────

do
  H.mock_koreader()
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls = {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true })

  local AskGPT    = require("main")
  local fake_self = { ui = make_reader_ui() }

  H.no_error("T-AS6 onSaveSettings runs without error", function()
    AskGPT.onSaveSettings(fake_self)
  end)
  H.eq("T-AS6 onSaveSettings triggers push_changes_only", #push_calls, 1)
end

-- ── T-AS7: new local highlight schedules push_new_highlights_only ─────────

do
  local spy = H.mock_koreader()
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls = {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_upload_new_highlights = true }, push_new_calls)

  local AskGPT    = require("main")
  local fake_self = { ui = make_reader_ui() }

  AskGPT.onAnnotationsModified(fake_self, {
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
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls = {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_upload_new_highlights = true }, push_new_calls)

  local AskGPT    = require("main")
  local fake_self = { ui = make_reader_ui() }

  AskGPT.onAnnotationsModified(fake_self, {
    { text = "web highlight", bookaware_highlight_id = "hl-web" },
    nb_highlights_added = 1,
  })
  H.eq("T-AS8 web highlight schedules no upload", #spy.scheduled, 0)
  H.eq("T-AS8 web highlight does not call push_new", #push_new_calls, 0)
end

-- ── T-AS9: auto_sync_web_highlights=true also enables new-highlight upload ─

do
  local spy = H.mock_koreader()
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls = {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true }, push_new_calls)

  local AskGPT    = require("main")
  local fake_self = { ui = make_reader_ui() }

  AskGPT.onAnnotationsModified(fake_self, {
    { text = "local highlight", pos0 = "/p.0", pos1 = "/p.15" },
    nb_highlights_added = 1,
  })
  for _, s in ipairs(spy.scheduled) do s.fn() end
  H.eq("T-AS9 auto_sync enables new highlight upload", #push_new_calls, 1)
end

-- ── T-AS10: local deletion of synced highlight tombstones backend ─────────

do
  local spy = H.mock_koreader()
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls, delete_calls, queue_calls = {}, {}, {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true }, push_new_calls, delete_calls, queue_calls)

  local AskGPT    = require("main")
  local fake_self = { ui = make_reader_ui() }

  AskGPT.onAnnotationsModified(fake_self, {
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
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls, delete_calls = {}, {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true }, push_new_calls, delete_calls)

  local AskGPT    = require("main")
  local fake_self = { ui = make_reader_ui() }

  AskGPT.onAnnotationsModified(fake_self, {
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
  H.reset("main", "askgpt.config", "askgpt.annotation_sync",
          "askgpt.dialog_controller", "askgpt.background_jobs",
          "askgpt.book_upload", "askgpt.book_sync", "update_checker")

  local sync_calls, push_calls, push_new_calls, delete_calls, queue_calls = {}, {}, {}, {}, {}
  setup_stubs(sync_calls, push_calls, { auto_sync_web_highlights = true }, push_new_calls, delete_calls, queue_calls)
  package.loaded["askgpt.config"].validate = function() return false, "bad config" end

  local AskGPT    = require("main")
  local fake_self = { ui = make_reader_ui() }

  AskGPT.onAnnotationsModified(fake_self, {
    { text = "synced highlight", bookaware_highlight_id = "hl-queue-only", bookaware_sha256 = SHA },
    nb_highlights_added = -1,
    index_modified = -1,
  })
  H.eq("T-AS12 deletion queues despite config failure", #queue_calls, 1)
  for _, s in ipairs(spy.scheduled) do s.fn() end
  H.eq("T-AS12 config failure prevents immediate push", #delete_calls, 0)
end
