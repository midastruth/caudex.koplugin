-- 后台任务管理：在子进程中执行 AI 请求，完成后通知用户
-- 仅 Summarize / Analyze 走后台；Ask / Dictionary 保持同步
local ffiutil     = require("ffi/util")
local json        = require("json")
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local _ = require("gettext")

local AiClient  = require("caudex.ai_client")
local Formatter = require("caudex.formatter")
local Util      = require("caudex.util")
local Errors    = require("caudex.errors")

local BackgroundJobs = {}

-- ── 任务列表（session 内内存，不持久化）────────────────────────────────────────

local _jobs    = {}
local _next_id = 1

local POLL_START   = 1.0   -- 首次轮询间隔（秒）
local POLL_MAX     = 6.0   -- 最大轮询间隔（秒）
local POLL_GROWTH  = 1.5   -- 每轮乘以该系数

-- 前向声明：深度研究的子任务构造器与追问轮询，open_result_viewer 会用到它们，
-- 但其定义位于文件后部，因此先声明本地名以便闭包通过 upvalue 捕获。
local make_research_task
local start_research_followup_poll

-- ── 内部工具 ──────────────────────────────────────────────────────────────────

-- 深拷贝（保留嵌套表，例如高亮的 pos0/pos1），用于在后台结果中保存选区快照。
local function deep_copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local copy = {}
  seen[value] = copy
  for k, v in pairs(value) do
    copy[deep_copy(k, seen)] = deep_copy(v, seen)
  end
  return copy
end

local UTF8_CHAR_PATTERN = '[%z\1-\127\194-\253][\128-\191]*'

local function safe_tostring(value)
  if value == nil then return "" end
  if type(value) == "string" then return value end
  if type(value) == "table" then
    if type(value.text) == "string" then return value.text end
    if type(value.selection) == "string" then return value.selection end
  end
  local ok, text = pcall(tostring, value)
  return ok and text or ""
end

local function trim_text(value)
  return Util.trim(safe_tostring(value))
end

local function truncate_utf8(text, max_chars)
  text = safe_tostring(text)
  max_chars = max_chars or 36
  local chars = {}
  local count = 0
  for char in text:gmatch(UTF8_CHAR_PATTERN) do
    count = count + 1
    if count <= max_chars then
      chars[#chars + 1] = char
    else
      return table.concat(chars) .. "…"
    end
  end
  return text
end

local function job_time(job)
  return type(job) == "table" and type(job.created_at) == "number"
      and job.created_at or 0
end

local function job_id(job)
  return type(job) == "table" and type(job.id) == "number" and job.id or 0
end

local function job_kind_label(job)
  if type(job) == "table" and job.kind == "summarize" then
    return _("[摘要]")
  elseif type(job) == "table" and job.kind == "analyze" then
    return _("[分析]")
  elseif type(job) == "table" and job.kind == "research" then
    return _("[研究]")
  end
  return _("[结果]")
end

local function new_job(kind, viewer_title, highlighted_text, doc_title, doc_author, doc_file_sha256)
  local id  = _next_id
  _next_id  = _next_id + 1
  local job = {
    id               = id,
    kind             = kind,       -- "summarize" | "analyze" | "research"
    status           = "running",  -- "running" | "done" | "failed"
    created_at       = os.time(),
    viewer_title     = viewer_title,
    highlighted_text = highlighted_text,
    doc_title        = doc_title,
    doc_author       = doc_author,
    doc_file_sha256  = doc_file_sha256,
    result_text      = nil,
    error_message    = nil,
    pid              = nil,
    -- 仅深度研究使用：保存追问/存笔记所需的上下文
    research_blocks  = nil,  -- 已格式化的问答块数组（含初始结果与后续追问）
    research_params  = nil,  -- 复用的请求参数（book/location/action…）
    highlight_obj    = nil,  -- 提交时的 ui.highlight 引用
    selection_snapshot = nil,  -- ui.highlight.selected_text 的深拷贝
  }
  _jobs[id] = job
  return job
end

-- 打开后台结果 viewer（无活跃 highlight 上下文）
-- 深度研究结果 viewer：支持继续追问与添加到高亮笔记。
-- 追问会再 fork 一次后台研究子进程；完成后把新块追加进同一 viewer。
local function open_research_viewer(ui, job)
  local CaudexViewer = require("caudexviewer")
  local viewer
  local refresh_viewer

  -- 显式打开结果时清除上一次手动关闭/隐藏状态；后台自动刷新仍会尊重之后的关闭。
  job.viewer_dismissed = false
  job.viewer_hidden = false

  -- 保存笔记：优先写入提交时捕获的高亮选区快照，脱离当前选区也能落笔记。
  local function handle_add_note(_viewer)
    local hl = job.highlight_obj or (ui and ui.highlight)
    if not hl or type(hl.addNote) ~= "function" then
      UIManager:show(InfoMessage:new {
        text    = _("无法找到高亮对象，已复制结果到查看器。"),
        timeout = 3,
      })
      return
    end
    -- 若当前 highlight 没有活跃选区，则用提交时保存的快照恢复，
    -- 让 addNote() 能基于原高亮位置创建带笔记的标注。
    if (not hl.selected_text) and type(job.selection_snapshot) == "table" then
      hl.selected_text = deep_copy(job.selection_snapshot)
    end
    local ok = pcall(function() hl:addNote(job.result_text) end)
    if ok then
      UIManager:close(viewer)
      if type(hl.onClose) == "function" then pcall(function() hl:onClose() end) end
    else
      UIManager:show(InfoMessage:new {
        text    = _("添加到笔记失败。"),
        timeout = 3,
      })
    end
  end

  local function handle_hide_chat(_viewer)
    job.viewer_hidden = true
    job.viewer_dismissed = false
    if job.viewer then
      UIManager:close(job.viewer)
      job.viewer = nil
    elseif viewer then
      UIManager:close(viewer)
    end
    UIManager:show(InfoMessage:new {
      text    = _("聊天已隐藏，回答完成后会自动显示。"),
      timeout = 2,
    })
  end

  local function handle_follow_up(_viewer, input)
    local trimmed = trim_text(input)
    if trimmed == "" then return end
    UIManager:show(InfoMessage:new {
      text    = _("正在进行深度研究…完成后会自动更新。"),
      timeout = 3,
    })
    -- AI 正在回答追问期间，用"Hide chat"替代"Add note"（内容尚未稳定）。
    job.followup_pending = true
    job.viewer_hidden = false
    job.viewer_dismissed = false
    if type(refresh_viewer) == "function" then refresh_viewer() end
    start_research_followup_poll(ui, job, trimmed)
  end

  refresh_viewer = function()
    -- 普通关闭表示用户已明确收起该聊天；后台追问完成后不要再自动弹出。
    -- Hide chat 使用 job.viewer_hidden=true，仍允许完成后自动显示最终结果。
    if job.viewer_dismissed and not job.viewer_hidden then return end
    if job.viewer and job.viewer._closed and not job.viewer_hidden then
      job.viewer = nil
      job.viewer_dismissed = true
      return
    end

    if job.viewer then UIManager:close(job.viewer) end
    local is_pending = job.followup_pending == true
    local add_note_callback = handle_add_note
    local hide_chat_callback = nil
    if is_pending then
      add_note_callback = nil
      hide_chat_callback = handle_hide_chat
    end
    local new_viewer
    new_viewer = CaudexViewer:new {
      ui              = ui,
      title           = job.viewer_title or _("深度研究"),
      text            = job.result_text,
      render_markdown = true,
      onAskQuestion   = handle_follow_up,
      onAddToNote     = add_note_callback,
      onHideChat      = hide_chat_callback,
      show_add_note   = not is_pending,
      close_callback  = function()
        if job.viewer == new_viewer then job.viewer = nil end
        if not job.viewer_hidden then job.viewer_dismissed = true end
      end,
    }
    viewer = new_viewer
    job.viewer = new_viewer
    job.viewer_hidden = false
    job.viewer_dismissed = false
    UIManager:show(new_viewer)
  end

  job.refresh_viewer = refresh_viewer
  refresh_viewer()
end

-- 打开后台结果 viewer。深度研究支持追问/存笔记；摘要/分析为只读结果。
local function open_result_viewer(ui, job)
  if not job or not job.result_text then return end

  if job.kind == "research" then
    return open_research_viewer(ui, job)
  end

  local CaudexViewer = require("caudexviewer")

  local function on_add_note_disabled(_viewer)
    UIManager:show(InfoMessage:new {
      text    = _("后台结果无法直接添加到当前高亮笔记。"),
      timeout = 3,
    })
  end
  local function on_ask_disabled(_viewer, _input)
    UIManager:show(InfoMessage:new {
      text    = _("后台结果暂不支持继续提问。"),
      timeout = 3,
    })
  end

  UIManager:show(CaudexViewer:new {
    ui              = ui,
    title           = job.viewer_title or _("AI Result"),
    text            = job.result_text,
    render_markdown = true,
    onAskQuestion   = on_ask_disabled,
    onAddToNote     = on_add_note_disabled,
  })
end

-- 任务完成后通知用户
local function notify_done(ui, job)
  local label = job.kind == "summarize" and _("AI摘要")
             or job.kind == "research"  and _("深度研究")
             or _("AI分析")
  if job.status == "done" then
    local text = label .. _("已完成，是否立即查看？")
    local ok, TopNotification = pcall(require, "caudex.top_notification")
    local shown = false
    if ok and TopNotification then
      shown = pcall(function()
        UIManager:show(TopNotification:new {
          text        = text,
          ok_text     = _("View"),
          cancel_text = _("Later"),
          timeout     = 60,
          ok_callback = function()
            open_result_viewer(ui, job)
          end,
        })
      end)
    end
    if not shown then
      -- 兼容兜底：如果旧版 KOReader 缺少顶部通知依赖，则仍使用原确认框。
      UIManager:show(ConfirmBox:new {
        text        = text,
        ok_text     = _("View"),
        cancel_text = _("Later"),
        ok_callback = function()
          open_result_viewer(ui, job)
        end,
      })
    end
  else
    Errors.show(label .. _("失败：") .. (job.error_message or "unknown error"))
  end
end

-- 启动轮询，直到子进程结束
local function start_poll(ui, job, pid, read_fd)
  local interval = POLL_START

  local function poll()
    local is_done  = ffiutil.isSubProcessDone(pid)
    local has_data = read_fd and ffiutil.getNonBlockingReadSize(read_fd) ~= 0

    if is_done or has_data then
      local raw = (read_fd and ffiutil.readAllFromFD(read_fd)) or ""

      if raw ~= "" then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == "table" and data.status == "done"
            and type(data.text) == "string" then
          job.status      = "done"
          job.result_text = data.text
        else
          job.status        = "failed"
          job.error_message = (ok and type(data) == "table" and data.error)
                              or "result parse error"
        end
      else
        job.status        = "failed"
        job.error_message = "subprocess produced no output"
      end

      -- 子进程可能还未完全退出，延迟一次确保 reap
      if not is_done then
        UIManager:scheduleIn(2, function() ffiutil.isSubProcessDone(pid) end)
      end

      notify_done(ui, job)
    else
      interval = math.min(interval * POLL_GROWTH, POLL_MAX)
      UIManager:scheduleIn(interval, poll)
    end
  end

  UIManager:scheduleIn(interval, poll)
end

-- ── 子进程任务体（捕获父进程 upvalue，fork 后在子进程运行）──────────────────────

local function build_book(doc_title, doc_author, doc_file_sha256)
  local book = {
    sha256 = doc_file_sha256,
    title  = doc_title,
    author = doc_author,
  }
  for _, value in pairs(book) do
    if value ~= nil and value ~= "" then return book end
  end
  return nil
end

local function make_summarize_task(content, prompt, language,
                                    highlighted_text, doc_title, doc_author,
                                    doc_file_sha256, doc_location)
  return function(_pid, child_write_fd)
    local result_text, err_msg
    local ok, summary = pcall(AiClient.summarizeContent, {
      content     = content,
      question    = prompt,
      language    = language,
      context     = prompt,
      file_sha256 = doc_file_sha256,
      book        = build_book(doc_title, doc_author, doc_file_sha256),
      location    = doc_location,
    })
    if not ok then
      err_msg = tostring(summary)
    elseif type(summary) ~= "table" or type(summary.summary) ~= "string" then
      err_msg = "invalid summary response"
    else
      result_text = Formatter.summary {
        highlighted_text = highlighted_text,
        prompt           = prompt,
        summary          = summary.summary,
        details          = summary.raw,
        language         = language,
        title            = doc_title,
        author           = doc_author,
        file_sha256      = doc_file_sha256,
      }
    end
    local out = result_text
      and json.encode({ status = "done",   text  = result_text })
      or  json.encode({ status = "failed", error = err_msg or "unknown" })
    ffiutil.writeToFD(child_write_fd, out, true)
  end
end

local function make_analyze_task(content, focus_points, language,
                                   highlighted_text, doc_title, doc_author,
                                   doc_file_sha256, doc_location)
  return function(_pid, child_write_fd)
    local result_text, err_msg
    local ok, analysis = pcall(AiClient.analyzeContent, {
      content      = content,
      focus_points = focus_points,
      question     = focus_points and table.concat(focus_points, ", ") or nil,
      language     = language,
      file_sha256  = doc_file_sha256,
      book         = build_book(doc_title, doc_author, doc_file_sha256),
      location     = doc_location,
    })
    if not ok then
      err_msg = tostring(analysis)
    elseif type(analysis) ~= "table" then
      err_msg = "invalid analysis response"
    else
      result_text = Formatter.analysis {
        highlighted_text = highlighted_text,
        focus_points     = focus_points,
        analysis         = analysis,
        language         = language,
        title            = doc_title,
        author           = doc_author,
        file_sha256      = doc_file_sha256,
      }
    end
    local out = result_text
      and json.encode({ status = "done",   text  = result_text })
      or  json.encode({ status = "failed", error = err_msg or "unknown" })
    ffiutil.writeToFD(child_write_fd, out, true)
  end
end

-- 深度研究任务体：在子进程中阻塞消费 /ai/research/stream，
-- 完成后把 { answer, sources } 格式化为问答块写回父进程。
-- text 为研究主题（高亮文本/书名），question 为可选的研究焦点/追问。
make_research_task = function(text, question, action, highlighted_text,
                             doc_title, doc_author, doc_file_sha256, doc_location)
  return function(_pid, child_write_fd)
    local result_text, err_msg
    local ok, final = pcall(AiClient.researchContent, {
      text        = text,
      question    = question,
      action      = action or "analyze",
      file_sha256 = doc_file_sha256,
      book        = build_book(doc_title, doc_author, doc_file_sha256),
      location    = doc_location,
    })
    if not ok then
      err_msg = tostring(final)
    elseif type(final) ~= "table" then
      err_msg = "invalid research response"
    else
      result_text = Formatter.ask {
        highlighted_text = highlighted_text,
        question         = question,
        answer           = final.answer,
        sources          = final.sources,
        title            = doc_title,
        author           = doc_author,
        file_sha256      = doc_file_sha256,
      }
    end
    local out = result_text
      and json.encode({ status = "done",   text  = result_text })
      or  json.encode({ status = "failed", error = err_msg or "unknown" })
    ffiutil.writeToFD(child_write_fd, out, true)
  end
end

-- ── 公开 API ──────────────────────────────────────────────────────────────────

-- 提交摘要后台任务
-- doc_title / doc_author / doc_file_sha256 由调用方（Workflow）从 ui 中提取后传入
function BackgroundJobs.submit_summary(ui, options, default_highlighted, doc_title, doc_author, doc_file_sha256, doc_location)
  local content = Util.trim(
    options.content or options.highlighted_text or default_highlighted or ""
  )
  if content == "" then
    Errors.show(_("内容不能为空。"))
    return
  end

  local prompt       = Util.trim(options.prompt or "")
  local language     = options.language
  local viewer_title = options.viewer_title or _("Reader AI Summary")
  local hitext       = options.highlighted_text or content

  local job  = new_job("summarize", viewer_title, hitext, doc_title, doc_author, doc_file_sha256)
  local task = make_summarize_task(content, prompt, language, hitext, doc_title, doc_author, doc_file_sha256, doc_location)

  local pid, read_fd = ffiutil.runInSubProcess(task, true)
  if not pid then
    job.status        = "failed"
    job.error_message = "fork failed"
    Errors.show(_("无法启动后台AI摘要任务（系统资源不足）。"))
    return
  end
  job.pid = pid

  UIManager:show(InfoMessage:new {
    text    = _("AI摘要任务已提交，可继续阅读。完成后会通知你。"),
    timeout = 3,
  })
  start_poll(ui, job, pid, read_fd)
end

-- 提交分析后台任务
function BackgroundJobs.submit_analyze(ui, options, default_highlighted, doc_title, doc_author, doc_file_sha256, doc_location)
  local content = Util.trim(
    options.content or options.highlighted_text or default_highlighted or ""
  )
  if content == "" then
    Errors.show(_("内容不能为空。"))
    return
  end

  local focus_input  = Util.trim(options.focus_points_input or "")
  local focus_points = focus_input ~= "" and Util.split_csv(focus_input) or nil
  if focus_points and #focus_points == 0 then focus_points = nil end
  local language     = options.language
  local viewer_title = options.viewer_title or _("Reader AI Analysis")
  local hitext       = options.highlighted_text or content

  local job  = new_job("analyze", viewer_title, hitext, doc_title, doc_author, doc_file_sha256)
  local task = make_analyze_task(content, focus_points, language, hitext, doc_title, doc_author, doc_file_sha256, doc_location)

  local pid, read_fd = ffiutil.runInSubProcess(task, true)
  if not pid then
    job.status        = "failed"
    job.error_message = "fork failed"
    Errors.show(_("无法启动后台AI分析任务（系统资源不足）。"))
    return
  end
  job.pid = pid

  UIManager:show(InfoMessage:new {
    text    = _("AI分析任务已提交，可继续阅读。完成后会通知你。"),
    timeout = 3,
  })
  start_poll(ui, job, pid, read_fd)
end

-- 提交深度研究后台任务（替代原前台流式）。
-- 完成后通过顶部通知提示，点开的结果 viewer 支持继续追问与添加笔记。
-- options: term/highlighted_text, question, action, viewer_title
function BackgroundJobs.submit_research(ui, options, default_highlighted, doc_title, doc_author, doc_file_sha256, doc_location)
  local text = Util.trim(
    options.term or options.highlighted_text or default_highlighted or ""
  )
  if text == "" then
    Errors.show(_("请先选中文字再提问。"))
    return
  end

  local question     = Util.trim(options.question or "")
  local action       = options.action or "analyze"
  local viewer_title = options.viewer_title or _("深度研究")
  local hitext       = options.highlighted_text or default_highlighted or text

  local job = new_job("research", viewer_title, hitext, doc_title, doc_author, doc_file_sha256)
  -- 保存追问/存笔记所需上下文
  job.research_params = {
    text         = text,
    action       = action,
    doc_title    = doc_title,
    doc_author   = doc_author,
    doc_file_sha256 = doc_file_sha256,
    doc_location = doc_location,
    highlighted_text = hitext,
  }
  job.research_blocks = {}
  job.highlight_obj   = ui and ui.highlight or nil
  if ui and ui.highlight and type(ui.highlight.selected_text) == "table" then
    job.selection_snapshot = deep_copy(ui.highlight.selected_text)
  end

  local task = make_research_task(text, question, action, hitext,
                                  doc_title, doc_author, doc_file_sha256, doc_location)

  local pid, read_fd = ffiutil.runInSubProcess(task, true)
  if not pid then
    job.status        = "failed"
    job.error_message = "fork failed"
    Errors.show(_("无法启动后台深度研究任务（系统资源不足）。"))
    return
  end
  job.pid = pid

  UIManager:show(InfoMessage:new {
    text    = _("深度研究任务已提交，可继续阅读。完成后会通知你。"),
    timeout = 3,
  })
  start_poll(ui, job, pid, read_fd)
end

-- 追问轮询：在已打开的研究结果 viewer 中再发起一次后台研究，
-- 完成后把新问答块追加到 job.result_text 并刷新 viewer。
start_research_followup_poll = function(ui, job, question)
  local rp = job.research_params or {}
  local task = make_research_task(rp.text or job.highlighted_text, question,
                                  rp.action, rp.highlighted_text or job.highlighted_text,
                                  rp.doc_title, rp.doc_author, rp.doc_file_sha256,
                                  rp.doc_location)

  local pid, read_fd = ffiutil.runInSubProcess(task, true)
  if not pid then
    job.followup_pending = false
    if type(job.refresh_viewer) == "function" then pcall(job.refresh_viewer) end
    UIManager:show(InfoMessage:new {
      text    = _("无法启动深度研究追问（系统资源不足）。"),
      timeout = 3,
    })
    return
  end

  local interval = POLL_START
  local function poll()
    local is_done  = ffiutil.isSubProcessDone(pid)
    local has_data = read_fd and ffiutil.getNonBlockingReadSize(read_fd) ~= 0

    if is_done or has_data then
      local raw = (read_fd and ffiutil.readAllFromFD(read_fd)) or ""
      local appended
      if raw ~= "" then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == "table" and data.status == "done"
            and type(data.text) == "string" then
          appended = data.text
        end
      end
      if not is_done then
        UIManager:scheduleIn(2, function() ffiutil.isSubProcessDone(pid) end)
      end

      -- 无论成功与否，追问子进程已结束，恢复"添加笔记"按钮。
      job.followup_pending = false

      if appended then
        job.research_blocks = job.research_blocks or {}
        table.insert(job.research_blocks, appended)
        job.result_text = (job.result_text or "") .. "\n\n" .. appended
      else
        UIManager:show(InfoMessage:new {
          text    = _("深度研究追问失败。"),
          timeout = 3,
        })
      end

      if type(job.refresh_viewer) == "function" then
        pcall(job.refresh_viewer)
      elseif job.viewer and type(job.viewer.update) == "function" then
        pcall(function() job.viewer:update(job.result_text) end)
      end
    else
      interval = math.min(interval * POLL_GROWTH, POLL_MAX)
      UIManager:scheduleIn(interval, poll)
    end
  end

  UIManager:scheduleIn(interval, poll)
end

-- 显示结果列表对话框（"稍后查看"入口）
function BackgroundJobs.show_results_menu(ui)
  local done_jobs = {}
  for _, job in pairs(_jobs) do
    if type(job) == "table" and job.status == "done" and type(job.result_text) == "string" then
      table.insert(done_jobs, job)
    end
  end
  table.sort(done_jobs, function(a, b)
    local at, bt = job_time(a), job_time(b)
    if at == bt then return job_id(a) > job_id(b) end
    return at > bt
  end)

  if #done_jobs == 0 then
    UIManager:show(InfoMessage:new {
      text    = _("暂无已完成的AI结果。"),
      timeout = 3,
    })
    return
  end

  local dlg
  local buttons = {}
  for _, job in ipairs(done_jobs) do
    local kind_label = job_kind_label(job)
    local snippet    = truncate_utf8(trim_text(job.highlighted_text), 36)
    local btn_text   = kind_label .. " " .. (snippet ~= "" and snippet or _("(无文本)"))
    local j = job   -- capture for closure
    table.insert(buttons, {{
      text     = btn_text,
      callback = function()
        UIManager:close(dlg)
        local ok, err = pcall(function()
          open_result_viewer(ui, j)
        end)
        if not ok then
          UIManager:show(InfoMessage:new {
            text    = _("打开 Caudex 结果失败：") .. tostring(err),
            timeout = 6,
          })
        end
      end,
    }})
  end
  table.insert(buttons, {{
    text     = _("Close"),
    callback = function() UIManager:close(dlg) end,
  }})

  dlg = ButtonDialog:new {
    title   = _("Recent AI Results"),
    buttons = buttons,
  }
  UIManager:show(dlg)
end

return BackgroundJobs
