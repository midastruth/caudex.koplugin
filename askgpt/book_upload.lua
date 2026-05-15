-- 将 KOReader 当前打开的 EPUB 上传到 Book-Aware 后端。
-- Book-Aware 现在会保存 EPUB、抽取 Markdown 并建立索引；客户端优先用
-- multipart/form-data 直传文件，避免 JSON/base64 的体积和内存开销。
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _           = require("gettext")

local AiClient = require("askgpt.ai_client")
local Util     = require("askgpt.util")

local BookUpload = {}

local function basename(path)
  return tostring(path or ""):match("([^/\\]+)$") or "book.epub"
end

local function is_epub(path)
  return tostring(path or ""):lower():match("%.epub$") ~= nil
end

local function show(text, timeout)
  UIManager:show(InfoMessage:new {
    text    = text,
    timeout = timeout or 3,
  })
end

local function read_doc_setting(ui, key)
  if not ui or not ui.doc_settings or not ui.doc_settings.readSetting then return nil end
  local ok, value = pcall(function() return ui.doc_settings:readSetting(key) end)
  if ok then return value end
  return nil
end

local function save_doc_setting(ui, key, value)
  if value == nil or not ui or not ui.doc_settings or not ui.doc_settings.saveSetting then return end
  pcall(function() ui.doc_settings:saveSetting(key, value) end)
end

local function number_equals(a, b)
  if a == b then return true end
  return tonumber(a) ~= nil and tonumber(a) == tonumber(b)
end

local function get_doc_file_sha256(ui, filepath)
  local size, mtime = Util.file_stat(filepath)
  local cached = read_doc_setting(ui, "file_sha256")
  if type(cached) == "string" and cached ~= "" then
    local cached_path  = read_doc_setting(ui, "file_sha256_path")
    local cached_size  = read_doc_setting(ui, "file_sha256_size")
    local cached_mtime = read_doc_setting(ui, "file_sha256_mtime")
    local same_path  = cached_path == nil or cached_path == filepath
    local same_size  = size == nil or cached_size == nil or number_equals(cached_size, size)
    local same_mtime = mtime == nil or cached_mtime == nil or number_equals(cached_mtime, mtime)
    if same_path and same_size and same_mtime then return cached end
  end

  local digest = Util.sha256_file(filepath)
  if digest then
    save_doc_setting(ui, "file_sha256", digest)
    save_doc_setting(ui, "file_sha256_path", filepath)
    save_doc_setting(ui, "file_sha256_size", size)
    save_doc_setting(ui, "file_sha256_mtime", mtime)
  end
  return digest
end

local function get_book_metadata(ui, filepath)
  local props = ui and ui.document and ui.document.getProps and ui.document:getProps() or {}
  local sha = type(props.file_sha256) == "string" and props.file_sha256 ~= ""
              and props.file_sha256 or get_doc_file_sha256(ui, filepath)
  return {
    sha256 = sha,
    title  = props.title or basename(filepath),
    author = props.authors or props.author or "",
  }
end

function BookUpload.upload_file(filepath)
  if type(filepath) ~= "string" or filepath == "" then
    show(_("无法获取书籍文件路径。"), 4)
    return
  end
  if not is_epub(filepath) then
    show(_("Book-Aware 当前上传接口只支持 EPUB。"), 4)
    return
  end

  show(_("正在计算书籍 SHA256..."), 1)
  local sha = Util.sha256_file(filepath)
  if type(sha) ~= "string" or sha == "" then
    show(_("计算书籍 SHA256 失败，无法上传。"), 6)
    return
  end

  local book = { sha256 = sha, title = basename(filepath), author = "" }

  show(_("正在检查 Book-Aware 是否已有本书..."), 1)
  local lookup_ok, existing = pcall(AiClient.getBook, book.sha256)
  if not lookup_ok then
    show(_("检查 Book-Aware 书籍状态失败：") .. tostring(existing), 8)
    return
  end
  if type(existing) == "table" and existing.ok then
    local indexed = existing.indexed and true or false
    local suffix = indexed
        and _("\n后端已有索引，可以直接使用 AskGPT。")
        or _("\n后端已有原始书籍，但尚未索引；需要后端转换/绑定 Markdown。")
    show(_("Book-Aware 已存在本书，无需重复上传。") .. suffix, indexed and 5 or 8)
    return
  end

  show(_("后端没有本书，正在上传 EPUB..."), 1)

  local ok, result = pcall(AiClient.importEpub, {
    filename = basename(filepath),
    filepath = filepath,
    book     = book,
  })
  if not ok then
    show(_("上传到 Book-Aware 失败：") .. tostring(result), 8)
    return
  end

  local indexed = type(result) == "table" and type(result.index) == "table"
  local suffix = indexed
      and _("\n已生成索引，可以直接使用 AskGPT。")
      or _("\n已上传原始 EPUB，但后端未返回索引。")
  show(_("Book-Aware 上传完成。") .. suffix, indexed and 5 or 8)
end

function BookUpload.upload_current(ui)
  local filepath = ui and ui.document and ui.document.file
  if type(filepath) ~= "string" or filepath == "" then
    show(_("无法获取当前书籍文件路径。"), 4)
    return
  end
  if not is_epub(filepath) then
    show(_("Book-Aware 当前上传接口只支持 EPUB。"), 4)
    return
  end

  show(_("正在计算书籍 SHA256..."), 1)
  local book = get_book_metadata(ui, filepath)
  if type(book.sha256) ~= "string" or book.sha256 == "" then
    show(_("计算当前书籍 SHA256 失败，无法上传。"), 6)
    return
  end

  show(_("正在检查 Book-Aware 是否已有本书..."), 1)
  local lookup_ok, existing = pcall(AiClient.getBook, book.sha256)
  if not lookup_ok then
    show(_("检查 Book-Aware 书籍状态失败：") .. tostring(existing), 8)
    return
  end
  if type(existing) == "table" and existing.ok then
    local indexed = existing.indexed and true or false
    local suffix = indexed
        and _("\n后端已有索引，可以直接使用 AskGPT。")
        or _("\n后端已有原始书籍，但尚未索引；需要后端转换/绑定 Markdown。")
    show(_("Book-Aware 已存在本书，无需重复上传。") .. suffix, indexed and 5 or 8)
    return
  end

  show(_("后端没有本书，正在上传当前 EPUB..."), 1)

  local ok, result = pcall(AiClient.importEpub, {
    filename = basename(filepath),
    filepath = filepath,
    book     = book,
  })
  if not ok then
    show(_("上传到 Book-Aware 失败：") .. tostring(result), 8)
    return
  end

  local returned_book = type(result) == "table" and result.book or nil
  if type(returned_book) == "table" and returned_book.sha256 then
    save_doc_setting(ui, "file_sha256", returned_book.sha256)
    save_doc_setting(ui, "file_sha256_path", filepath)
    local size, mtime = Util.file_stat(filepath)
    save_doc_setting(ui, "file_sha256_size", size)
    save_doc_setting(ui, "file_sha256_mtime", mtime)
  end

  local indexed = type(result) == "table" and type(result.index) == "table"
  local suffix = indexed
      and _("\n已生成索引，可以直接使用 AskGPT。")
      or _("\n已上传原始 EPUB，但后端未返回索引。")
  show(_("Book-Aware 上传完成。") .. suffix, indexed and 5 or 8)
end

return BookUpload
