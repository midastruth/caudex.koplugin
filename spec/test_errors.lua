local H = require("spec.helpers")

H.section("D. caudex/errors.lua")

local spy = H.mock_koreader()
H.reset("caudex.errors")
local Errors = require("caudex.errors")

local function last_shown_text()
  local w = spy.shown[#spy.shown]
  return w and w.text or nil
end

-- ── show_request_error routing ─────────────────────────────────────────────

-- Branch 1: timeout (case-insensitive)
spy.shown = {}
Errors.show_request_error("TIMEOUT exceeded", "task")
H.contains("TIMEOUT -> 超时提示", last_shown_text() or "", "超时")

spy.shown = {}
Errors.show_request_error("request timeout", "task")
H.contains("lowercase timeout -> 超时提示", last_shown_text() or "", "超时")

-- Branch 2a: "connection" keyword
spy.shown = {}
Errors.show_request_error("Connection failed", "task")
H.contains("Connection failed -> 无法连接提示", last_shown_text() or "", "无法连接")

-- Branch 2b: "failed to contact" keyword
spy.shown = {}
Errors.show_request_error("failed to contact server", "task")
H.contains("failed to contact -> 无法连接提示", last_shown_text() or "", "无法连接")

-- Branch 3: "attempts" keyword (use a string that only matches this branch)
spy.shown = {}
Errors.show_request_error("max retry attempts exceeded", "task")
H.contains("attempts -> 多次失败提示", last_shown_text() or "", "多次失败")

-- Branch 4: fallback with task_label
spy.shown = {}
Errors.show_request_error("some unknown error", "字典查询")
local t = last_shown_text() or ""
H.contains("fallback: contains task_label", t, "字典查询")
H.contains("fallback: contains error text",  t, "some unknown error")

-- show() works for plain messages
spy.shown = {}
Errors.show("plain message")
H.eq("show(): plain text stored", last_shown_text(), "plain message")
