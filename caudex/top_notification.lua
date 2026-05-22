-- 顶部通知确认条：用于以 iOS 通知横幅的方式提示用户。
-- 相比 ConfirmBox，它不居中弹出，而是固定显示在屏幕顶部。

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RectSpan = require("ui/widget/rectspan")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Input = Device.input
local Screen = Device.screen

local TopNotification = InputContainer:extend {
  modal = true,

  text = "",
  ok_text = _("View"),
  cancel_text = _("Later"),
  ok_callback = function() end,
  cancel_callback = function() end,

  -- nil/false 表示不自动消失；数字表示秒数。
  timeout = 60,
  _timeout_func = nil,

  face = Font:getFace("infofont"),
  margin = Size.margin.default,
  padding = Size.padding.default,
  top_margin = Size.margin.default,
  width = nil,
  dismissable = true,
}

function TopNotification:init()
  if self.dismissable then
    if Device:isTouchDevice() then
      self.ges_events.TapClose = {
        GestureRange:new {
          ges = "tap",
          range = Geom:new {
            x = 0,
            y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
          },
        },
      }
    end
    if Device:hasKeys() then
      self.key_events.Close = { { Input.group.Back } }
    end
  end

  self.width = self.width or math.floor(Screen:getWidth() * 0.92)
  local content_width = self.width - 2 * self.padding

  local text_widget = TextBoxWidget:new {
    text = self.text,
    face = self.face,
    width = content_width,
  }

  local button_table = ButtonTable:new {
    width = content_width,
    buttons = {
      {
        {
          text = self.cancel_text,
          callback = function()
            self.cancel_callback()
            UIManager:close(self)
          end,
        },
        {
          text = self.ok_text,
          callback = function()
            self.ok_callback()
            UIManager:close(self)
          end,
        },
      },
    },
    zero_sep = true,
    show_parent = self,
  }

  self.frame = FrameContainer:new {
    background = Blitbuffer.COLOR_WHITE,
    radius = Size.radius.window,
    margin = self.margin,
    padding = self.padding,
    padding_bottom = 0,
    VerticalGroup:new {
      align = "left",
      text_widget,
      VerticalSpan:new { width = self.padding },
      button_table,
    },
  }

  self[1] = VerticalGroup:new {
    align = "center",
    RectSpan:new {
      width = Screen:getWidth(),
      height = self.top_margin,
    },
    self.frame,
  }
end

function TopNotification:onShow()
  UIManager:setDirty(self, function()
    return "ui", self.frame.dimen
  end)

  if self.timeout then
    self._timeout_func = function()
      self._timeout_func = nil
      self.cancel_callback()
      UIManager:close(self)
    end
    UIManager:scheduleIn(self.timeout, self._timeout_func)
  end

  return true
end

function TopNotification:onCloseWidget()
  UIManager:setDirty(nil, function()
    return "ui", self.frame.dimen
  end)

  if self._timeout_func and UIManager.unschedule then
    UIManager:unschedule(self._timeout_func)
    self._timeout_func = nil
  end
end

function TopNotification:onClose()
  self.cancel_callback()
  UIManager:close(self)
  return true
end

function TopNotification:onTapClose(_, ges)
  if self.frame and self.frame.dimen and ges.pos:notIntersectWith(self.frame.dimen) then
    self:onClose()
  end
  return true
end

return TopNotification
