-- 对话框协调器：InputDialog 创建、按钮回调、调用 workflow
local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")
local _ = require("gettext")

local Highlight = require("caudex.highlight")
local Config    = require("caudex.config")
local Util      = require("caudex.util")
local Workflow  = require("caudex.workflow")

local DialogController = {}

function DialogController.show(ui, highlight_source)
  local highlighted_text, highlighted_context = Highlight.extract(highlight_source)
  local input_dialog  -- 当前活动的输入对话框，仅限本次 show() 调用

  local buttons = {
    {
      text = _("Cancel"),
      callback = function()
        UIManager:close(input_dialog)
      end,
    },
    {
      text = _("Ask"),
      callback = function()
        local question = input_dialog and Util.trim(input_dialog:getInputText()) or ""
        UIManager:close(input_dialog)
        Workflow.ask(ui, {
          term             = highlighted_text,
          highlighted_text = highlighted_text,
          question         = question,
          viewer_title     = _("Caudex"),
        }, highlighted_text)
      end,
    },
  }

  table.insert(buttons, {
    text = _("Summarize"),
    callback = function()
      local question = input_dialog and Util.trim(input_dialog:getInputText()) or ""
      UIManager:close(input_dialog)
      Workflow.summarize(ui, {
        content          = highlighted_text,
        highlighted_text = highlighted_text,
        prompt           = question,
        viewer_title     = _("Reader AI Summary"),
      }, highlighted_text)
    end,
  })

  table.insert(buttons, {
    text = _("Deep research"),
    callback = function()
      local focus_input = input_dialog and Util.trim(input_dialog:getInputText()) or ""
      UIManager:close(input_dialog)
      Workflow.research(ui, {
        term             = highlighted_text,
        highlighted_text = highlighted_text,
        question         = focus_input,
        action           = "analyze",
        viewer_title     = _("深度研究"),
      }, highlighted_text)
    end,
  })

  table.insert(buttons, {
    text = _("How to read"),
    callback = function()
      local extra = input_dialog and Util.trim(input_dialog:getInputText()) or ""
      UIManager:close(input_dialog)

      -- 取书名/作者，用于构造"如何阅读这本书"的问题
      local props  = (ui and ui.document and ui.document:getProps()) or {}
      local title  = (type(props.title)   == "string" and props.title   ~= "") and props.title   or _("这本书")
      local author = (type(props.authors) == "string" and props.authors ~= "") and props.authors or nil

      local question = string.format(
        _("请告诉我应该如何阅读《%s》%s。\n请给出：\n1. 这本书的核心主题与作者意图；\n2. 推荐的阅读方式及阅读顺序；\n3. 阅读时需要重点关注的章节或概念；\n4. 阅读时常见的难点和建议的应对方法；\n5. 可搭配阅读的延伸书籍或资料。"),
        title,
        author and ("（作者：" .. author .. "）") or ""
      )
      if extra ~= "" then
        question = question .. "\n\n" .. _("用户附加要求：") .. extra
      end

      -- 复用 Ask 流式工作流；term 用书名，避免被当作高亮逐字解读
      Workflow.ask(ui, {
        term             = title,
        highlighted_text = highlighted_text,
        question         = question,
        viewer_title     = _("How to read this book"),
      }, highlighted_text)
    end,
  })

  local target_language = type(Config.get_dictionary_language) == "function"
      and Config.get_dictionary_language() or nil
  if target_language then
    table.insert(buttons, {
      text = _("Dictionary"),
      callback = function()
        UIManager:close(input_dialog)
        Workflow.lookup(ui, {
          term                    = highlighted_text,
          highlighted_text        = highlighted_text,
          question                = _("Dictionary lookup in ") .. target_language,
          action                  = "dictionary",
          language                = target_language,
          request_language        = "auto",
          viewer_title            = _("Dictionary"),
          followup_language       = target_language,
          followup_request_language = "auto",
          context                 = highlighted_context,
          skip_context_question   = true,
        }, highlighted_text)
      end,
    })
  end

  input_dialog = InputDialog:new {
    title      = _("Ask a question about the highlighted text"),
    input_hint = _("Type your question here..."),
    input_type = "text",
    buttons    = { buttons },
  }
  UIManager:show(input_dialog)
end

return DialogController
