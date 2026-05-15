local H = require("spec.helpers")

H.section("E. main.lua")

local spy = H.mock_koreader()

-- Provide stub modules that main.lua requires
H.reset("main", "askgpt.config", "askgpt.dialog_controller",
        "askgpt.background_jobs", "askgpt.book_upload", "askgpt.book_sync", "update_checker")

package.loaded["askgpt.config"] = {
  validate = function() return true, {} end,
  get      = function() return {} end,
}
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
package.loaded["askgpt.book_sync"] = {
  sync_all = function() end,
}
package.loaded["ui/elements/reader_menu_order"] = {
  navi = { "table_of_contents", "bookmarks" },
}
-- update_checker already set by mock_koreader

local AskGPT = require("main")

H.is_true("main.lua returns a table (AskGPT object)", type(AskGPT) == "table")

-- ── Test init() ────────────────────────────────────────────────────────────

local reg_calls = {}   -- registerToMainMenu call log
local add_calls = {}   -- addToHighlightDialog call log

local fake_self = {
  ui = {
    menu = {
      registerToMainMenu = function(_, obj)
        table.insert(reg_calls, obj)
      end,
    },
    highlight = {
      addToHighlightDialog = function(_, key, factory_fn)
        table.insert(add_calls, { key = key, fn = factory_fn })
      end,
    },
  },
}

H.no_error("init() runs without error", function()
  AskGPT.init(fake_self)
end)

H.eq("init() calls registerToMainMenu once", #reg_calls, 1)
H.eq("init() calls addToHighlightDialog once", #add_calls, 1)
H.eq("addToHighlightDialog key is 'askgpt_GPT'",
     add_calls[1] and add_calls[1].key, "askgpt_GPT")

-- The factory function returned to addToHighlightDialog should produce a table
-- with .text and .callback
local factory = add_calls[1] and add_calls[1].fn
if factory then
  local entry = factory({})          -- pass a dummy highlight source
  H.is_true("highlight entry has .text",     type(entry.text) == "string")
  H.is_true("highlight entry has .callback", type(entry.callback) == "function")
else
  H.is_false("factory_fn was registered", true)  -- force fail
end

-- ── Test init() in FileManager context ────────────────────────────────────

local fm_reg_calls       = {}
local fm_dialog_calls    = {}  -- addFileDialogButtons call log

local fake_fm_self = {
  ui = {
    -- Real KOReader FileManager loads plugins before file_chooser is created.
    -- addFileDialogButtons is the stable FileManager capability to detect.
    menu = {
      registerToMainMenu = function(_, obj)
        table.insert(fm_reg_calls, obj)
      end,
    },
    addFileDialogButtons = function(_, row_id, row_func)
      table.insert(fm_dialog_calls, { id = row_id, fn = row_func })
    end,
  },
}

H.reset("main")
AskGPT = require("main")

H.no_error("init() in FileManager context runs without error", function()
  AskGPT.init(fake_fm_self)
end)

H.eq("FileManager init() calls registerToMainMenu once", #fm_reg_calls, 1)
H.eq("FileManager init() registers one file dialog button row", #fm_dialog_calls, 1)
H.eq("file dialog row_id is 'askgpt_upload_file'",
     fm_dialog_calls[1] and fm_dialog_calls[1].id, "askgpt_upload_file")

local row_fn = fm_dialog_calls[1] and fm_dialog_calls[1].fn
-- non-file: should return nil (no button)
H.is_true("row_fn returns nil for non-file",
          row_fn and row_fn("/books/folder", false) == nil)
-- non-epub file: should return nil
H.is_true("row_fn returns nil for non-epub file",
          row_fn and row_fn("/books/book.pdf", true) == nil)
-- epub file: should return a table with one button
local buttons = row_fn and row_fn("/books/book.epub", true)
H.is_true("row_fn returns table for epub",  type(buttons) == "table")
H.is_true("button row has one entry",       buttons and #buttons == 1)
H.is_true("button has .text",               buttons and type(buttons[1].text) == "string")
H.is_true("button has .callback",           buttons and type(buttons[1].callback) == "function")

-- ── Test addToMainMenu() ───────────────────────────────────────────────────

local menu_items = {}
H.no_error("addToMainMenu() runs without error", function()
  AskGPT.addToMainMenu(fake_self, menu_items)
end)

H.is_true("addToMainMenu creates AskGPT submenu",
          menu_items.askgpt ~= nil)
H.eq("AskGPT submenu is hinted into Navigation", menu_items.askgpt.sorting_hint, "navi")
H.eq("AskGPT is inserted before table of contents",
     package.loaded["ui/elements/reader_menu_order"].navi[1], "askgpt")
H.eq("Table of contents follows AskGPT",
     package.loaded["ui/elements/reader_menu_order"].navi[2], "table_of_contents")
H.is_true("AskGPT submenu has items",
          type(menu_items.askgpt.sub_item_table) == "table")
H.eq("Reader AskGPT submenu has four items", #menu_items.askgpt.sub_item_table, 4)
H.is_true("Recent results item callback is a function",
          type(menu_items.askgpt.sub_item_table[1].callback) == "function")
H.is_true("Upload current book item callback is a function",
          type(menu_items.askgpt.sub_item_table[2].callback) == "function")
H.is_true("Sync books item callback is a function",
          type(menu_items.askgpt.sub_item_table[3].callback) == "function")
H.is_true("Update item callback is a function",
          type(menu_items.askgpt.sub_item_table[4].callback) == "function")

-- Recent Results callback must not crash KOReader if the result dialog fails.
H.reset("main")
package.loaded["askgpt.background_jobs"] = {
  show_results_menu = function() error("boom") end,
}
AskGPT = require("main")
local safe_menu_items = {}
AskGPT.addToMainMenu(fake_self, safe_menu_items)
spy.shown = {}
H.no_error("Recent results callback catches errors", function()
  safe_menu_items.askgpt.sub_item_table[1].callback()
end)
H.contains("Recent results callback shows failure message",
           spy.shown[1] and spy.shown[1].text or "", "打开 AskGPT 最近结果失败")

-- In FileManager context, askgpt_upload_book must NOT appear (no open book).
local fm_menu_items = {}
H.no_error("addToMainMenu() in FileManager context runs without error", function()
  AskGPT.addToMainMenu(fake_fm_self, fm_menu_items)
end)
H.is_true("FileManager addToMainMenu: AskGPT submenu present",
          fm_menu_items.askgpt ~= nil)
H.eq("FileManager AskGPT submenu has three items", #fm_menu_items.askgpt.sub_item_table, 3)
H.eq("FileManager AskGPT submenu is still hinted into Tools",
     fm_menu_items.askgpt.sorting_hint, "tools")
H.is_true("FileManager AskGPT submenu has no upload current book item",
          fm_menu_items.askgpt.sub_item_table[2].text ~= "Upload current book to Book-Aware")
