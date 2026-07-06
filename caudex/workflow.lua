-- 任务执行入口：lookup / summarize / analyze
-- lookup 同步；summarize / analyze 路由到 background_jobs（子进程）
local UIManager     = require("ui/uimanager")
local InfoMessage   = require("ui/widget/infomessage")
local CaudexViewer = require("caudexviewer")
local _ = require("gettext")

local AiClient         = require("caudex.ai_client")
local Errors           = require("caudex.errors")
local Formatter        = require("caudex.formatter")
local Util             = require("caudex.util")
local BackgroundJobs   = require("caudex.background_jobs")

local unpack = unpack or table.unpack

local Workflow = {}

-- ── 私有工具 ─────────────────────────────────────────────────────────────────

local function show_loading()
  local loading = InfoMessage:new { text = _("Loading..."), timeout = 0.1 }
  UIManager:show(loading)
  return loading
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

local function get_doc_file_sha256(ui)
  local filepath = ui and ui.document and ui.document.file
  if not filepath or filepath == "" then return nil end

  local size, mtime = Util.file_stat(filepath)
  local cached = read_doc_setting(ui, "file_sha256")
  if type(cached) == "string" and cached ~= "" then
    local cached_path  = read_doc_setting(ui, "file_sha256_path")
    local cached_size  = read_doc_setting(ui, "file_sha256_size")
    local cached_mtime = read_doc_setting(ui, "file_sha256_mtime")
    local same_path  = cached_path == nil or cached_path == filepath
    local same_size  = size == nil or cached_size == nil or number_equals(cached_size, size)
    local same_mtime = mtime == nil or cached_mtime == nil or number_equals(cached_mtime, mtime)
    if same_path and same_size and same_mtime then
      return cached
    end
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

local function get_doc_props(ui)
  local props = ui and ui.document and ui.document:getProps() or {}
  local file_sha256 = type(props.file_sha256) == "string" and props.file_sha256 ~= ""
                      and props.file_sha256 or get_doc_file_sha256(ui)
  return props.title or nil, props.authors or nil, file_sha256
end

local function build_book(title, author, file_sha256)
  local book = {
    sha256 = file_sha256,
    title  = title,
    author = author,
  }
  for _, value in pairs(book) do
    if value ~= nil and value ~= "" then return book end
  end
  return nil
end

local function safe_call(obj, method, ...)
  if not obj or type(obj[method]) ~= "function" then return nil end
  local args = { ... }
  local ok, value = pcall(function() return obj[method](obj, unpack(args)) end)
  if ok then return value end
  return nil
end

local function get_current_page(ui)
  return safe_call(ui, "getCurrentPage")
      or (ui and ui.view and ui.view.state and ui.view.state.page)
      or (ui and ui.toc and ui.toc.pageno)
end

local function get_doc_location(ui)
  local current_page = get_current_page(ui)
  local chapter = safe_call(ui and ui.toc, "getTocTitleOfCurrentPage")
  if (not chapter or chapter == "") and current_page then
    chapter = safe_call(ui and ui.toc, "getTocTitleByPage", current_page)
  end
  if chapter == "" then chapter = nil end

  local progress
  local page_count = safe_call(ui and ui.document, "getPageCount")
  if type(current_page) == "number" and type(page_count) == "number" and page_count > 0 then
    progress = current_page / page_count
  end

  if chapter or progress then
    return { chapter = chapter, progress = progress }
  end
  return nil
end

local function build_lookup_context(ui, highlighted_text, extra_context, file_sha256)
  local props  = ui and ui.document and ui.document:getProps() or {}
  local title  = props.title   or _("Unknown Title")
  local author = props.authors or _("Unknown Author")
  file_sha256 = file_sha256 or get_doc_file_sha256(ui)
  local parts  = {
    _("Document title: ") .. title,
    _("Author: ") .. author,
  }
  if file_sha256 and file_sha256 ~= "" then
    table.insert(parts, _("File SHA256: ") .. file_sha256)
  end
  if highlighted_text and highlighted_text ~= "" then
    table.insert(parts, _("Highlighted text: ") .. highlighted_text)
  end
  if extra_context and extra_context ~= "" then
    table.insert(parts, _("User request: ") .. extra_context)
  end
  return table.concat(parts, "\n")
end

-- ── 核心 helper ───────────────────────────────────────────────────────────────
--
-- spec 字段:
--   ui            KOReader UI 引用
--   viewer_title  string
--   call_ai       function() -> block_string | nil
--                   nil 表示失败（函数内部已调用 Errors.show*）
--   call_followup function(trimmed_input) -> block_string | nil
--                   nil 表示失败或静默跳过
--
local function run_viewer_workflow(spec)
  local blocks       = {}
  local current_text = ""

  local loading = show_loading()
  UIManager:scheduleIn(0.1, function()
    if loading then UIManager:close(loading) end

    local block = spec.call_ai()
    if not block then return end

    table.insert(blocks, block)
    current_text = table.concat(blocks, "\n\n")

    local caudex_viewer

    local function handleAddToNote(viewer)
      if not spec.ui.highlight or not spec.ui.highlight.addNote then
        Errors.show(_("错误：无法找到高亮对象。"))
        return
      end
      spec.ui.highlight:addNote(current_text)
      UIManager:close(viewer or caudex_viewer)
      if spec.ui.highlight.onClose then spec.ui.highlight:onClose() end
    end

    local function handleFollowUp(viewer, input)
      local trimmed = Util.trim(input or "")
      if trimmed == "" then return end
      local follow_block = spec.call_followup(trimmed)
      if not follow_block then return end
      table.insert(blocks, follow_block)
      current_text = table.concat(blocks, "\n\n")
      viewer:update(current_text)
    end

    caudex_viewer = CaudexViewer:new {
      ui              = spec.ui,
      title           = spec.viewer_title,
      text            = current_text,
      render_markdown = true,
      onAskQuestion   = handleFollowUp,
      onAddToNote     = handleAddToNote,
    }
    UIManager:show(caudex_viewer)
  end)
end

-- ── Lookup (字典) ─────────────────────────────────────────────────────────────

-- options: term, highlighted_text, question, action, language, request_language,
--          context, skip_context_question, viewer_title,
--          followup_language, followup_request_language
function Workflow.lookup(ui, options, default_highlighted)
  local request_term = Util.trim(options.term or "")
  if request_term == "" then
    Errors.show(_("词条不能为空。"))
    return
  end

  local question          = Util.trim(options.question or "")
  local base_context      = type(options.context) == "string"
                            and Util.trim(options.context) or ""
  local skip_ctx_question = options.skip_context_question
  local request_language  = options.request_language or options.language
  local action            = options.action or "ask"
  local doc_title, doc_author, doc_file_sha256 = get_doc_props(ui)
  local doc_book          = build_book(doc_title, doc_author, doc_file_sha256)
  local doc_location      = get_doc_location(ui)

  local function compose_context(prompt_text)
    local trimmed = Util.trim(prompt_text)
    if base_context ~= "" then
      if trimmed ~= "" and not skip_ctx_question then
        return base_context .. "\n" .. trimmed
      end
      return base_context
    end
    return build_lookup_context(ui, options.highlighted_text or default_highlighted, trimmed, doc_file_sha256)
  end

  run_viewer_workflow({
    ui           = ui,
    viewer_title = options.viewer_title or _("Reader AI Dictionary"),

    call_ai = function()
      local ok, dictionary = pcall(AiClient.dictionaryLookup, {
        action      = action,
        term        = request_term,
        language    = request_language,
        question    = question,
        context     = compose_context(question),
        file_sha256 = doc_file_sha256,
        book        = doc_book,
        location    = doc_location,
      })
      if not ok then
        Errors.show_request_error(dictionary, _("字典查询"))
        return nil
      end
      if type(dictionary) ~= "table" then
        Errors.show(_("字典查询返回了未知格式。"))
        return nil
      end
      return Formatter.dictionary {
        highlighted_text = options.highlighted_text,
        question         = question,
        term             = request_term,
        dictionary       = dictionary,
        language         = options.language,
        title            = doc_title,
        author           = doc_author,
        file_sha256      = doc_file_sha256,
      }
    end,

    call_followup = function(input)
      local follow_lang     = options.followup_language or options.language
      local follow_req_lang = options.followup_request_language
                              or options.request_language or follow_lang
      local ok2, dict_follow = pcall(AiClient.dictionaryLookup, {
        action      = action,
        term        = input,
        language    = follow_req_lang,
        question    = input,
        context     = compose_context(input),
        file_sha256 = doc_file_sha256,
        book        = doc_book,
        location    = doc_location,
      })
      if not ok2 then
        Errors.show_request_error(dict_follow, _("字典查询"))
        return nil
      end
      return Formatter.dictionary {
        question   = input,
        term       = input,
        dictionary = dict_follow,
        language    = follow_lang,
        title       = doc_title,
        author      = doc_author,
        file_sha256 = doc_file_sha256,
      }
    end,
  })
end

-- ── Summarize → 后台执行 ──────────────────────────────────────────────────────

-- 提交摘要到后台子进程；立即返回，不阻塞 UI
-- options: content, highlighted_text, prompt, language, viewer_title
function Workflow.summarize(ui, options, default_highlighted)
  local doc_title, doc_author, doc_file_sha256 = get_doc_props(ui)
  BackgroundJobs.submit_summary(ui, options, default_highlighted, doc_title, doc_author,
                                doc_file_sha256, get_doc_location(ui))
end

-- ── Analyze → 后台执行 ────────────────────────────────────────────────────────

-- 提交分析到后台子进程；立即返回，不阻塞 UI
-- options: content, highlighted_text, focus_points_input, language, viewer_title
function Workflow.analyze(ui, options, default_highlighted)
  local doc_title, doc_author, doc_file_sha256 = get_doc_props(ui)
  BackgroundJobs.submit_analyze(ui, options, default_highlighted, doc_title, doc_author,
                                doc_file_sha256, get_doc_location(ui))
end

-- ── 流式工作流核心（子进程 + tmpfile 轮询）────────────────────────────────────
--
-- 流程：
--   1. 立即打开 CaudexViewer（显示占位提示）
--   2. fork 子进程调用 stream_fn(stream_params, tmpfile)，把 delta 写入 tmpfile
--   3. 主进程每 1.5s 读 tmpfile，更新 viewer
--   4. 收到 <<CAUDEX_DONE>> → 格式化最终结果，刷新 viewer，支持继续提问
--   5. 用户关闭 viewer → 停止轮询，删除 tmpfile
--
-- spec 字段：
--   ui, options, default_highlighted
--   stream_fn       function(stream_params, tmpfile)  在子进程运行
--   tmp_prefix      string  /tmp 文件前缀
--   placeholder     string  初始占位文本
--   restart         function(ui, options, trimmed_input, default_highlighted)
--                     继续提问时重新发起本工作流
local function run_stream_workflow(spec)
  local ui                  = spec.ui
  local options             = spec.options or {}
  local default_highlighted = spec.default_highlighted
  local stream_fn           = spec.stream_fn

  local ffiutil = require("ffi/util")
  local json    = require("json")

  local doc_title, doc_author, doc_file_sha256 = get_doc_props(ui)
  local doc_location = get_doc_location(ui)

  local text     = Util.trim(options.term or options.highlighted_text or default_highlighted or "")
  local question = Util.trim(options.question or "")

  if text == "" then
    Errors.show(_("请先选中文字再提问。"))
    return
  end

  math.randomseed(os.time())
  local tmpfile = string.format("%s_%d_%d.txt",
    spec.tmp_prefix or "/tmp/caudex_stream", os.time(), math.random(99999))

  local POLL_INTERVAL = 1.5
  local DONE_MARKER   = "<<CAUDEX_DONE>>"
  local ERROR_MARKER  = "<<CAUDEX_ERROR>>"

  local current_viewer  = nil
  local polling_active  = false
  local stream_complete = false
  local chat_hidden     = false

  local stream_params = {
    text        = text,
    question    = question,
    action      = options.action,
    file_sha256 = doc_file_sha256,
    book        = build_book(doc_title, doc_author, doc_file_sha256),
    location    = doc_location,
  }

  local function stop_and_cleanup()
    polling_active = false
    pcall(os.remove, tmpfile)
  end

  local function show_viewer(display_text, callbacks)
    -- AI 仍在回答中（未传入 on_note 回调）时，用"Hide chat"替代"Add note"。
    local has_note_callback = callbacks and callbacks.on_note ~= nil
    local force_show = callbacks and callbacks.force_show
    if chat_hidden and not has_note_callback and not force_show then return end
    if current_viewer then UIManager:close(current_viewer) end
    if has_note_callback or force_show then chat_hidden = false end
    current_viewer = CaudexViewer:new {
      ui              = ui,
      title           = options.viewer_title or _("Caudex"),
      text            = display_text,
      render_markdown = true,
      close_callback  = callbacks and callbacks.on_close or nil,
      onAskQuestion   = callbacks and callbacks.on_ask or function(_, _)
        UIManager:show(InfoMessage:new { text = _("请等待回答完成。"), timeout = 2 })
      end,
      onAddToNote   = has_note_callback and callbacks.on_note or nil,
      onHideChat    = (not has_note_callback) and function(_)
        chat_hidden = true
        if current_viewer then
          UIManager:close(current_viewer)
          current_viewer = nil
        end
        UIManager:show(InfoMessage:new {
          text    = _("聊天已隐藏，回答完成后会自动显示。"),
          timeout = 2,
        })
      end or nil,
      show_add_note = has_note_callback,
    }
    UIManager:show(current_viewer)
  end

  -- 初始占位 viewer
  show_viewer(spec.placeholder or _("正在思考..."), { on_close = stop_and_cleanup })
  polling_active = true

  -- Fork 子进程
  local pid = ffiutil.runInSubProcess(function()
    stream_fn(stream_params, tmpfile)
  end, false)

  if not pid then
    polling_active = false
    UIManager:close(current_viewer)
    pcall(os.remove, tmpfile)
    Errors.show(_("无法启动流式查询（系统资源不足）。"))
    return
  end

  local last_content = ""

  local function poll()
    if not polling_active then return end

    local f = io.open(tmpfile, "r")
    local raw = f and f:read("*a") or ""
    if f then f:close() end

    local done_pos  = raw:find(DONE_MARKER,  1, true)
    local error_pos = raw:find(ERROR_MARKER, 1, true)

    if error_pos then
      stop_and_cleanup()
      stream_complete = true
      UIManager:close(current_viewer)
      Errors.show_request_error(raw:sub(error_pos + #ERROR_MARKER), _("Caudex"))
      return
    end

    if done_pos then
      stop_and_cleanup()
      stream_complete = true

      local delta_text = raw:sub(1, done_pos - 1)
      local final_str  = raw:sub(done_pos + #DONE_MARKER)
      local ok_j, final = pcall(json.decode, final_str)

      local formatted
      if ok_j and type(final) == "table" then
        formatted = Formatter.ask {
          highlighted_text = options.highlighted_text or default_highlighted,
          question         = question,
          answer           = final.answer,
          sources          = final.sources,
          title            = doc_title,
          author           = doc_author,
          file_sha256      = doc_file_sha256,
        }
      else
        formatted = delta_text ~= "" and delta_text or _("回答完毕，但无法解析结果。")
      end

      local final_text = formatted
      show_viewer(formatted, {
        on_close = function() end,
        on_ask = function(_, input)
          local trimmed = Util.trim(input or "")
          if trimmed == "" then return end
          spec.restart(ui, options, trimmed, default_highlighted, text)
        end,
        on_note = function(_)
          if ui.highlight and ui.highlight.addNote then
            ui.highlight:addNote(final_text)
            UIManager:close(current_viewer)
            if ui.highlight.onClose then ui.highlight:onClose() end
          end
        end,
      })
      return
    end

    -- 仍在流式：有新内容则更新 viewer
    if raw ~= "" and raw ~= last_content then
      last_content = raw
      show_viewer(raw, { on_close = stop_and_cleanup })
    end

    -- 子进程异常退出（未写 DONE/ERROR）
    if ffiutil.isSubProcessDone(pid) and not stream_complete then
      stop_and_cleanup()
      stream_complete = true
      if last_content ~= "" then
        show_viewer(last_content .. "\n\n[Stream ended unexpectedly]", {
          on_close = function() end,
          force_show = true,
        })
      else
        UIManager:close(current_viewer)
        Errors.show(_("Caudex 流式请求异常结束。"))
      end
      return
    end

    UIManager:scheduleIn(POLL_INTERVAL, poll)
  end

  UIManager:scheduleIn(POLL_INTERVAL, poll)
end

-- ── Ask → SSE 流式 ────────────────────────────────────────────────────────────
function Workflow.ask(ui, options, default_highlighted)
  run_stream_workflow {
    ui                  = ui,
    options             = options,
    default_highlighted = default_highlighted,
    stream_fn           = AiClient.streamAsk,
    tmp_prefix          = "/tmp/caudex_ask",
    placeholder         = _("正在思考..."),
    restart = function(ui2, opts, trimmed, default_hl, text)
      Workflow.ask(ui2, {
        term             = text,
        highlighted_text = opts.highlighted_text or default_hl,
        question         = trimmed,
        viewer_title     = opts.viewer_title or _("Caudex"),
      }, default_hl)
    end,
  }
end

-- ── Deep Research（深度研究）→ 后台执行 ──────────────────────────────────────
-- 提交到后台子进程；立即返回，不阻塞 UI。完成后通过顶部通知提示，
-- 打开的结果 viewer 支持继续追问与添加到高亮笔记。
-- options: term/highlighted_text, question, action, viewer_title
function Workflow.research(ui, options, default_highlighted)
  local doc_title, doc_author, doc_file_sha256 = get_doc_props(ui)
  BackgroundJobs.submit_research(ui, options, default_highlighted, doc_title, doc_author,
                                 doc_file_sha256, get_doc_location(ui))
end

return Workflow
