-- spec/test_dialog_controller.lua
-- 验证 dialog_controller.show() 构造的按钮集合与回调行为，
-- 重点覆盖新增的 "How to read" 按钮。

local H = require("spec.helpers")
H.section("dialog_controller")

H.reset("askgpt.dialog_controller", "askgpt.workflow", "askgpt.highlight",
        "askgpt.config", "askgpt.util",
        "ui/widget/inputdialog", "ui/uimanager", "gettext")

local spy = H.mock_koreader()

-- ── 捕获 InputDialog 的 buttons ────────────────────────────────────────────
local captured_dialog = nil
package.loaded["ui/widget/inputdialog"] = {
  new = function(_, args)
    captured_dialog = {
      _type    = "InputDialog",
      title    = args.title,
      buttons  = args.buttons,
      -- 模拟用户在输入框里没有输入任何内容
      getInputText = function() return "" end,
    }
    return captured_dialog
  end,
}

-- ── Stub 业务依赖 ───────────────────────────────────────────────────────────
package.loaded["askgpt.highlight"] = {
  extract = function(_) return "selected text", "ctx" end,
}

package.loaded["askgpt.config"] = {
  -- 不返回翻译目标 → 不应该出现 Dictionary 按钮
  get_translate_target = function() return nil end,
}

package.loaded["askgpt.util"] = {
  trim = function(s) return (s or ""):gsub("^%s+",""):gsub("%s+$","") end,
}

local ask_calls       = {}
local summarize_calls = {}
local analyze_calls   = {}
package.loaded["askgpt.workflow"] = {
  ask       = function(ui, opts, def) table.insert(ask_calls,       { ui = ui, opts = opts, def = def }) end,
  summarize = function(ui, opts, def) table.insert(summarize_calls, { ui = ui, opts = opts, def = def }) end,
  analyze   = function(ui, opts, def) table.insert(analyze_calls,   { ui = ui, opts = opts, def = def }) end,
  lookup    = function() end,
}

-- ── Fake KOReader UI ───────────────────────────────────────────────────────
local ui = {
  document = {
    getProps = function()
      return { title = "How to Read a Book", authors = "Mortimer J. Adler" }
    end,
  },
}

-- ── Act ────────────────────────────────────────────────────────────────────
local DialogController = require("askgpt.dialog_controller")
DialogController.show(ui, { _fake = true })

-- ── Assert: 对话框已弹出，并捕获到了按钮组 ──────────────────────────────────
H.is_true("InputDialog 被弹出", captured_dialog ~= nil)
H.is_true("buttons 结构为单行二维表", type(captured_dialog.buttons) == "table"
                                       and type(captured_dialog.buttons[1]) == "table")

local row = captured_dialog.buttons[1]

local function find_button(text)
  for _, b in ipairs(row) do
    if b.text == text then return b end
  end
  return nil
end

H.is_true("含 Cancel 按钮",         find_button("Cancel")       ~= nil)
H.is_true("含 Ask 按钮",            find_button("Ask")          ~= nil)
H.is_true("含 Summarize 按钮",      find_button("Summarize")    ~= nil)
H.is_true("含 Analyze 按钮",        find_button("Analyze")      ~= nil)
H.is_true("含 How to read 按钮 (新)", find_button("How to read") ~= nil)
H.is_false("无 Dictionary 按钮 (未配置 target 语言)",
           find_button("Dictionary") ~= nil)

-- ── Act: 点击 "How to read" 按钮 ────────────────────────────────────────────
local how_btn = find_button("How to read")
H.no_error("点击 How to read 不抛错", function() how_btn.callback() end)

-- ── Assert: Workflow.ask 被以预期 payload 调用 ──────────────────────────────
H.eq("Workflow.ask 被调用 1 次", #ask_calls, 1)

local call = ask_calls[1]
H.is_true("call.opts 存在", type(call.opts) == "table")
H.eq ("term 为书名",         call.opts.term,          "How to Read a Book")
H.eq ("highlighted_text 透传", call.opts.highlighted_text, "selected text")
H.eq ("viewer_title 正确",   call.opts.viewer_title, "How to read this book")
H.contains("question 含书名",            call.opts.question, "How to Read a Book")
H.contains("question 含作者",            call.opts.question, "Mortimer J. Adler")
H.contains("question 含 '如何阅读'",     call.opts.question, "如何阅读")
H.contains("question 提到核心主题/意图", call.opts.question, "核心主题")
H.contains("question 提到延伸阅读",      call.opts.question, "延伸")

-- 既然输入框是空的，不应该带 "用户附加要求"
H.is_false("无附加要求时不出现 '用户附加要求'",
           call.opts.question:find("用户附加要求", 1, true) ~= nil)

-- ── Act: 再次弹框，模拟用户在输入框写了附加要求 ────────────────────────────
captured_dialog = nil
ask_calls = {}
package.loaded["ui/widget/inputdialog"] = {
  new = function(_, args)
    captured_dialog = {
      _type        = "InputDialog",
      buttons      = args.buttons,
      getInputText = function() return "  我只有30分钟  " end,
    }
    return captured_dialog
  end,
}

H.reset("askgpt.dialog_controller")
DialogController = require("askgpt.dialog_controller")
DialogController.show(ui, { _fake = true })
find_button = function(text)
  for _, b in ipairs(captured_dialog.buttons[1]) do
    if b.text == text then return b end
  end
end
find_button("How to read").callback()

H.eq("二次调用 Workflow.ask", #ask_calls, 1)
H.contains("附加要求被附加到 question",
           ask_calls[1].opts.question, "我只有30分钟")
H.contains("附加要求带前缀 '用户附加要求'",
           ask_calls[1].opts.question, "用户附加要求")
