-- 统一错误展示；所有 UI 层错误提示都走这里
local UIManager   = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local Errors = {}

function Errors.show(message)
  UIManager:show(InfoMessage:new { text = message })
end

-- 将 AI 请求错误映射为友好提示（全小写匹配，大小写无关）
-- 覆盖：timeout / connection failed / failed to contact / attempts exhausted
-- task_label: 如 _("字典查询")，用于兜底提示
function Errors.show_request_error(error_msg, task_label)
  local lower = tostring(error_msg):lower()
  if lower:match("timeout") then
    Errors.show(_("网络请求超时，请检查网络连接后重试。"))
  elseif lower:match("connection") or lower:match("failed to contact") then
    Errors.show(_("无法连接到AI服务，请检查网络设置。"))
  elseif lower:match("attempts") then
    Errors.show(_("网络连接多次失败，请检查网络后重试。"))
  else
    Errors.show((task_label or _("请求")) .. _("失败：") .. tostring(error_msg))
  end
end

return Errors
