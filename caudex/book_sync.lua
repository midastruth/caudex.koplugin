-- 从 Book-Aware 后端同步 EPUB 到 KOReader 本地书库。
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Menu        = require("ui/widget/menu")
local _           = require("gettext")

local AiClient = require("caudex.ai_client")
local Config   = require("caudex.config")
local Util     = require("caudex.util")

local BookSync = {}

local function show(text, timeout)
  UIManager:show(InfoMessage:new {
    text    = text,
    timeout = timeout or 3,
  })
end

local function basename(path)
  return tostring(path or ""):match("([^/\\]+)$") or ""
end

local function dirname(path)
  local dir = tostring(path or ""):match("^(.*)[/\\][^/\\]+$")
  return dir ~= "" and dir or nil
end

local function sanitize_filename(name)
  name = tostring(name or ""):gsub("[%z\1-\31/\\:*?\"<>|]", "_")
  name = Util.trim(name)
  if name == "" then name = "book.epub" end
  if not name:lower():match("%.epub$") then name = name .. ".epub" end
  return name
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

local function try_lfs()
  local ok, lfs = pcall(require, "libs/libkoreader-lfs")
  if ok and lfs then return lfs end
  return nil
end

local function ensure_dir(path)
  if type(path) ~= "string" or path == "" then return false, "missing path" end
  local lfs = try_lfs()
  if not lfs or type(lfs.attributes) ~= "function" or type(lfs.mkdir) ~= "function" then
    return true
  end
  local mode = lfs.attributes(path, "mode")
  if mode == "directory" then return true end
  if mode ~= nil then return false, "path exists and is not a directory" end
  local parent = dirname(path)
  if parent and parent ~= path then
    local ok, err = ensure_dir(parent)
    if not ok then return ok, err end
  end
  local ok, err = lfs.mkdir(path)
  if ok or lfs.attributes(path, "mode") == "directory" then return true end
  return false, err
end

local function join_path(dir, name)
  dir = tostring(dir or "")
  if dir == "" or dir == "/" then return "/" .. name end
  return dir:gsub("[/\\]+$", "") .. "/" .. name
end

local function configured_sync_dir()
  local cfg = Config.get()
  if type(cfg) == "table" then
    if type(cfg.reader_ai_sync_dir) == "string" and cfg.reader_ai_sync_dir ~= "" then
      return cfg.reader_ai_sync_dir
    end
    if type(cfg.book_aware_sync_dir) == "string" and cfg.book_aware_sync_dir ~= "" then
      return cfg.book_aware_sync_dir
    end
  end
  return nil
end

local function default_sync_dir(ui)
  local configured = configured_sync_dir()
  if configured then return configured end
  local doc_file = ui and ui.document and ui.document.file
  local doc_dir = dirname(doc_file)
  if doc_dir then return doc_dir end
  if ui and ui.file_chooser and type(ui.file_chooser.path) == "string" and ui.file_chooser.path ~= "" then
    return ui.file_chooser.path
  end
  if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
    local ok, lastdir = pcall(function() return G_reader_settings:readSetting("lastdir") end)
    if ok and type(lastdir) == "string" and lastdir ~= "" then return lastdir end
  end
  return "."
end

local function book_filename(book)
  local name = basename(book.central_original_path) ~= "" and basename(book.central_original_path)
      or basename(book.original_path) ~= "" and basename(book.original_path)
      or tostring(book.title or "")
  if name == "" then name = "book-" .. tostring(book.sha256 or ""):sub(1, 12) end
  return sanitize_filename(name)
end

local function is_epub_book(book)
  if type(book) ~= "table" or type(book.sha256) ~= "string" or book.sha256 == "" then return false end
  if tostring(book.format or ""):lower() == "epub" then return true end
  return book.central_original_path ~= nil or book.original_path ~= nil
end

local function book_label(book)
  local title = Util.trim(book.title or "")
  if title ~= "" then return title end
  return book_filename(book)
end

local function refresh_filemanager(ui)
  if ui and ui.file_chooser and type(ui.file_chooser.refreshPath) == "function" then
    pcall(function() ui.file_chooser:refreshPath() end)
  end
end

local function download_one(book, sync_dir, current, total)
  local filename = book_filename(book)
  local target = join_path(sync_dir, filename)
  if file_exists(target) then
    return "skipped", target
  end

  local tmp = target .. ".caudex-download"
  os.remove(tmp)
  if current and total then
    show(string.format(_("正在同步 Book-Aware 书籍 %d/%d：\n%s"), current, total, book_label(book)), 1)
  else
    show(_("正在同步 Book-Aware 书籍：\n") .. book_label(book), 1)
  end

  local dl_ok, dl_err = pcall(AiClient.downloadBook, book.sha256, tmp)
  if not dl_ok then
    os.remove(tmp)
    return "failed", tostring(dl_err)
  end

  os.remove(target)
  local renamed, rename_err = os.rename(tmp, target)
  if not renamed then
    os.remove(tmp)
    return "failed", tostring(rename_err)
  end
  return "downloaded", target
end

function BookSync.sync_book(ui, book)
  if not is_epub_book(book) then
    show(_("这本书不是可同步的 EPUB。"), 5)
    return
  end

  local sync_dir = default_sync_dir(ui)
  local ok_dir, dir_err = ensure_dir(sync_dir)
  if not ok_dir then
    show(_("创建同步目录失败：") .. tostring(dir_err), 6)
    return
  end

  local status, detail = download_one(book, sync_dir)
  refresh_filemanager(ui)
  if status == "downloaded" then
    show(_("Book-Aware 书籍同步完成：\n") .. tostring(detail), 6)
  elseif status == "skipped" then
    show(_("本地已存在，已跳过：\n") .. tostring(detail), 5)
  else
    show(_("Book-Aware 书籍同步失败：\n") .. tostring(detail), 8)
  end
end

local function book_mandatory(book)
  if book.indexed == false then return _("未索引") end
  local author = Util.trim(book.author or "")
  if author ~= "" then return author end
  local sha = tostring(book.sha256 or "")
  return sha ~= "" and sha:sub(1, 8) or nil
end

function BookSync.show(ui)
  show(_("正在读取 Book-Aware 书籍列表..."), 1)
  local ok, result = pcall(AiClient.listBooks)
  if not ok then
    show(_("读取 Book-Aware 书籍列表失败：") .. tostring(result), 8)
    return
  end

  local books = type(result) == "table" and result.books or nil
  if type(books) ~= "table" or #books == 0 then
    show(_("Book-Aware 后端没有可同步的书籍。"), 5)
    return
  end

  local epubs = {}
  for _, book in ipairs(books) do
    if is_epub_book(book) then table.insert(epubs, book) end
  end
  if #epubs == 0 then
    show(_("Book-Aware 后端没有 EPUB 书籍可同步。"), 5)
    return
  end

  local menu
  local items = {
    {
      text = _("同步全部 EPUB"),
      mandatory = tostring(#epubs),
      callback = function()
        UIManager:close(menu)
        BookSync.sync_all(ui)
      end,
    },
  }
  for _, book in ipairs(epubs) do
    table.insert(items, {
      text = book_label(book),
      mandatory = book_mandatory(book),
      callback = function()
        UIManager:close(menu)
        BookSync.sync_book(ui, book)
      end,
    })
  end

  menu = Menu:new{
    title = _("Book-Aware 书籍同步"),
    subtitle = string.format(_("选择一本下载，或同步全部。目录：%s"), default_sync_dir(ui)),
    item_table = items,
    is_popout = false,
    items_per_page = 12,
    items_max_lines = 2,
  }
  UIManager:show(menu)
end

function BookSync.sync_all(ui)
  local sync_dir = default_sync_dir(ui)
  local ok_dir, dir_err = ensure_dir(sync_dir)
  if not ok_dir then
    show(_("创建同步目录失败：") .. tostring(dir_err), 6)
    return
  end

  show(_("正在读取 Book-Aware 书籍列表..."), 1)
  local ok, result = pcall(AiClient.listBooks)
  if not ok then
    show(_("读取 Book-Aware 书籍列表失败：") .. tostring(result), 8)
    return
  end

  local books = type(result) == "table" and result.books or nil
  if type(books) ~= "table" or #books == 0 then
    show(_("Book-Aware 后端没有可同步的书籍。"), 5)
    return
  end

  local total, downloaded, skipped, failed = 0, 0, 0, 0
  for _, book in ipairs(books) do
    if is_epub_book(book) then total = total + 1 end
  end
  if total == 0 then
    show(_("Book-Aware 后端没有 EPUB 书籍可同步。"), 5)
    return
  end

  local current = 0
  for _, book in ipairs(books) do
    if is_epub_book(book) then
      current = current + 1
      local status, detail = download_one(book, sync_dir, current, total)
      if status == "downloaded" then
        downloaded = downloaded + 1
      elseif status == "skipped" then
        skipped = skipped + 1
      else
        failed = failed + 1
        print("Caudex BookSync download failed: " .. tostring(detail))
      end
    end
  end

  refresh_filemanager(ui)

  show(string.format(
    _("Book-Aware 同步完成。\n下载：%d\n已存在：%d\n失败：%d\n目录：%s"),
    downloaded, skipped, failed, sync_dir
  ), failed > 0 and 8 or 6)
end

return BookSync
