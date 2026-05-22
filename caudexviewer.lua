--[[--
Caudex查看器 - 在可滚动视图中显示文本的组件
用于显示Caudex响应内容，支持文本选择、滚动、提问和添加笔记功能

@usage 使用示例
    local caudexviewer = CaudexViewer:new{
        title = _("I can scroll!"),
        text = _("I'll need to be longer than this example to scroll."),
    }
    UIManager:show(caudexviewer)
]]
-- 导入必要的KOReader UI组件和工具模块
local BD = require("ui/bidi")                    -- 双向文本支持
local Blitbuffer = require("ffi/blitbuffer")     -- 图像缓冲区操作
local ButtonTable = require("ui/widget/buttontable")  -- 按钮表格组件
local CenterContainer = require("ui/widget/container/centercontainer")  -- 居中容器
-- local CheckButton = require("ui/widget/checkbutton")  -- 未使用的复选按钮组件
local Device = require("device")                 -- 设备信息
local Geom = require("ui/geometry")              -- 几何计算
local Font = require("ui/font")                  -- 字体管理
local FrameContainer = require("ui/widget/container/framecontainer")    -- 框架容器
local GestureRange = require("ui/gesturerange")  -- 手势范围
local InputContainer = require("ui/widget/container/inputcontainer")    -- 输入容器基类
local InputDialog = require("ui/widget/inputdialog")  -- 输入对话框
local MovableContainer = require("ui/widget/container/movablecontainer") -- 可移动容器
local Notification = require("ui/widget/notification")  -- 通知组件
local ScrollTextWidget = require("ui/widget/scrolltextwidget")  -- 滚动文本组件
local Size = require("ui/size")                  -- 尺寸定义
local TitleBar = require("ui/widget/titlebar")   -- 标题栏
local UIManager = require("ui/uimanager")        -- UI管理器
local VerticalGroup = require("ui/widget/verticalgroup")  -- 垂直布局组
local WidgetContainer = require("ui/widget/container/widgetcontainer")  -- 组件容器
-- local T = require("ffi/util").template  -- 未使用的模板工具
-- local util = require("util")            -- 未使用的工具函数
local _ = require("gettext")             -- 国际化
local Screen = Device.screen               -- 屏幕对象
local MarkdownRenderer  -- lazy-required when render_markdown=true

--[[--
Caudex查看器主组件类
继承自InputContainer，提供完整的Caudex响应显示和交互功能
]]
local CaudexViewer = InputContainer:extend {
  ui = nil,                    -- UI实例引用，用于访问主程序功能
  title = nil,                 -- 对话框标题
  text = nil,                  -- 要显示的Caudex响应文本
  width = nil,                 -- 对话框宽度（可选，默认自适应屏幕）
  height = nil,                -- 对话框高度（可选，默认自适应屏幕）
  buttons_table = nil,         -- 自定义按钮配置表
  
  -- 文本显示选项 - 详见TextBoxWidget
  -- 默认使用两端对齐和自动段落方向，适应各种类型的文本
  -- 对于技术文本（HTML、CSS、应用日志等），建议设为false
  alignment = "left",                    -- 文本对齐方式：左对齐
  justified = true,                      -- 启用两端对齐
  lang = nil,                            -- 语言设置
  para_direction_rtl = nil,              -- 段落从右到左方向
  auto_para_direction = true,            -- 自动检测段落方向
  alignment_strict = false,              -- 严格对齐模式
  
  -- 标题栏配置
  title_face = nil,                      -- 标题字体（使用TitleBar默认）
  title_multilines = nil,                -- 标题多行显示（详见TitleBar）
  title_shrink_font_to_fit = nil,        -- 自动缩小字体适应（详见TitleBar）
  
  -- 文本显示配置
  text_face = Font:getFace("infofont"),  -- 正文字体
  fgcolor = Blitbuffer.COLOR_BLACK,            -- 前景色（黑色）
  text_padding = Size.padding.large,           -- 文本内边距
  text_margin = Size.margin.small,             -- 文本外边距
  button_padding = Size.padding.default,       -- 按钮内边距
  
  -- 按钮配置
  add_default_buttons = nil,                   -- 是否添加默认按钮
  default_hold_callback = nil,                 -- 默认按钮长按回调
  find_centered_lines_count = 5,               -- 查找结果居中显示行数
  
  -- 回调函数
  onAskQuestion = nil,                         -- 提问按钮回调函数
  onAddToNote = nil,                           -- 添加笔记按钮回调函数

  -- Markdown 渲染选项
  render_markdown = false,                     -- 是否渲染 Markdown（需要 ScrollHtmlWidget）
  markdown_max_size = 131072,                  -- 超过此长度时强制走 ScrollTextWidget 路径（128 KB，约 4 万汉字）
  _update_pending = false,                     -- debounce: 是否有未执行的 update 调度
  _last_update_text = nil,                     -- debounce: 最后一次待应用的文本
  _closed = false,                             -- 已关闭后禁止延迟 update 重新打开
}

--[[--
判断是否应使用 HTML 渲染路径（静态方法，便于单元测试）
@param text 显示文本
@param render_markdown 是否启用 Markdown 渲染
@param markdown_max_size 超过此长度时强制走纯文本路径
]]
function CaudexViewer._shouldUseHtml(text, render_markdown, markdown_max_size)
    if not render_markdown then return false end
    if type(text) ~= "string" or text == "" then return false end
    if #text > (markdown_max_size or 131072) then return false end
    return true
end

--[[--
初始化函数 - 构建完整的Caudex查看器UI界面
创建所有必要的UI组件并设置事件处理
]]
function CaudexViewer:init()
  -- 计算窗口尺寸 - 默认居中显示，留出边距
  self.align = "center"
  self.region = Geom:new {
    x = 0, y = 0,
    w = Screen:getWidth(),
    h = Screen:getHeight(),
  }
  -- 设置对话框尺寸，默认比屏幕小30个单位
  self.width = self.width or Screen:getWidth() - Screen:scaleBySize(30)
  self.height = self.height or Screen:getHeight() - Screen:scaleBySize(30)

  -- 初始化查找相关状态变量
  self._find_next = false                    -- 是否处于查找下一个状态
  self._find_next_button = false             -- 查找下一个按钮状态
  self._old_virtual_line_num = 1             -- 旧的虚拟行号，用于查找定位

  -- 设置键盘事件 - 如果有物理键盘，按返回键关闭对话框
  if Device:hasKeys() then
    self.key_events.Close = { { Device.input.group.Back } }
  end

  -- 设置触摸事件 - 如果是触摸设备，配置各种手势识别
  if Device:isTouchDevice() then
    local range = Geom:new {
      x = 0, y = 0,
      w = Screen:getWidth(),
      h = Screen:getHeight(),
    }
    self.ges_events = {
      -- 点击关闭：点击对话框外部区域关闭
      TapClose = {
        GestureRange:new {
          ges = "tap",
          range = range,
        },
      },
      -- 滑动手势：用于文本滚动
      Swipe = {
        GestureRange:new {
          ges = "swipe",
          range = range,
        },
      },
      -- 多指滑动手势：关闭对话框
      MultiSwipe = {
        GestureRange:new {
          ges = "multiswipe",
          range = range,
        },
      },
      -- 文本选择相关手势 - 支持选择一个或多个单词
      HoldStartText = {
        GestureRange:new {
          ges = "hold",
          range = range,
        },
      },
      HoldPanText = {
        GestureRange:new {
          ges = "hold",
          range = range,
        },
      },
      HoldReleaseText = {
        GestureRange:new {
          ges = "hold_release",
          range = range,
        },
        -- 长按释放时的回调函数，处理文本选择
        args = function(text, hold_duration, start_idx, end_idx, to_source_index_func)
          self:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
        end
      },
      -- 以下事件将在检查后转发给MovableContainer处理
      ForwardingTouch = { GestureRange:new { ges = "touch", range = range, }, },
      ForwardingPan = { GestureRange:new { ges = "pan", range = range, }, },
      ForwardingPanRelease = { GestureRange:new { ges = "pan_release", range = range, }, },
    }
  end

  -- 创建标题栏 - 包含标题和关闭按钮
  local titlebar = TitleBar:new {
    width = self.width,
    align = "left",
    with_bottom_line = true,
    title = self.title,
    title_face = self.title_face,
    title_multilines = self.title_multilines,
    title_shrink_font_to_fit = self.title_shrink_font_to_fit,
    close_callback = function() self:onClose() end,
    show_parent = self,
  }

  -- 创建滚动位置回调 - 用于根据滚动位置启用/禁用顶部/底部按钮
  local prev_at_top = false -- 记录之前是否在顶部（按钮初始为启用状态）
  local prev_at_bottom = false
  local function button_update(id, enable)
    local button = self.button_table:getButtonById(id)
    if button then
      if enable then
        button:enable()      -- 启用按钮
      else
        button:disable()     -- 禁用按钮
      end
      button:refresh()       -- 刷新按钮显示
    end
  end
  -- 滚动回调函数 - 根据滚动位置更新按钮状态
  self._buttons_scroll_callback = function(low, high)
    -- 顶部按钮状态管理
    if prev_at_top and low > 0 then
      button_update("top", true)   -- 离开顶部，启用"到顶部"按钮
      prev_at_top = false
    elseif not prev_at_top and low <= 0 then
      button_update("top", false)  -- 到达顶部，禁用"到顶部"按钮
      prev_at_top = true
    end
    -- 底部按钮状态管理
    if prev_at_bottom and high < 1 then
      button_update("bottom", true)   -- 离开底部，启用"到底部"按钮
      prev_at_bottom = false
    elseif not prev_at_bottom and high >= 1 then
      button_update("bottom", false)  -- 到达底部，禁用"到底部"按钮
      prev_at_bottom = true
    end
  end

  -- 创建默认按钮组 - 包含提问、滚动和笔记功能
  local default_buttons =
  {
    {
      text = _("Ask Another Question"),  -- "再问一个问题"按钮
      id = "ask_another_question",
      callback = function()
        self:askAnotherQuestion()  -- 调用提问函数
      end,
    },
    {
      text = "⇱",  -- "到顶部"按钮（箭头符号）
      id = "top",
      callback = function()
        self.scroll_text_w:scrollToTop()  -- 滚动到文本顶部
      end,
      hold_callback = self.default_hold_callback,
      allow_hold_when_disabled = true,
    },
    {
      text = "⇲",  -- "到底部"按钮（箭头符号）
      id = "bottom",
      callback = function()
        self.scroll_text_w:scrollToBottom()  -- 滚动到文本底部
      end,
      hold_callback = self.default_hold_callback,
      allow_hold_when_disabled = true,
    },
    {
      text = _("Add note"),  -- "添加笔记"按钮
      id = "add_note",
      callback = function()
        self:addToNote()  -- 调用添加笔记函数
      end,
      hold_callback = self.default_hold_callback,
    },
  }
  -- 合并自定义按钮和默认按钮
  local buttons = self.buttons_table or {}
  if self.add_default_buttons or not self.buttons_table then
    table.insert(buttons, default_buttons)
  end
  -- 创建按钮表格组件
  self.button_table = ButtonTable:new {
    width = self.width - 2 * self.button_padding,
    buttons = buttons,
    zero_sep = true,
    show_parent = self,
  }

  -- 计算文本显示区域高度 - 减去标题栏和按钮区域高度
  local textw_height = self.height - titlebar:getHeight() - self.button_table:getSize().h

  -- 创建滚动文本组件 - 核心文本显示区域
  self.scroll_text_w = ScrollTextWidget:new {
    text = self.text,
    face = self.text_face,
    fgcolor = self.fgcolor,
    width = self.width - 2 * self.text_padding - 2 * self.text_margin,
    height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
    dialog = self,
    alignment = self.alignment,
    justified = self.justified,
    lang = self.lang,
    para_direction_rtl = self.para_direction_rtl,
    auto_para_direction = self.auto_para_direction,
    alignment_strict = self.alignment_strict,
    scroll_callback = self._buttons_scroll_callback,  -- 绑定滚动回调
  }
  -- Markdown 渲染路径：文本未超长时用 ScrollHtmlWidget 替换 ScrollTextWidget
  if CaudexViewer._shouldUseHtml(self.text, self.render_markdown, self.markdown_max_size) then
      if not MarkdownRenderer then MarkdownRenderer = require("markdown_renderer") end
      local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
      local html_body = MarkdownRenderer.toHtml(self.text)
      local html_w = ScrollHtmlWidget:new {
          html_body = html_body,
          css = MarkdownRenderer.DEFAULT_CSS,
          width = self.width - 2 * self.text_padding - 2 * self.text_margin,
          height = textw_height - 2 * self.text_padding - 2 * self.text_margin,
          dialog = self,
      }
      local function notify_html_scroll_position(w)
          if not self._buttons_scroll_callback or not w.htmlbox_widget then return end
          local page_count = math.max(1, w.htmlbox_widget.page_count or 1)
          local page_number = math.max(1, math.min(page_count, w.htmlbox_widget.page_number or 1))
          self._buttons_scroll_callback((page_number - 1) / page_count, page_number / page_count)
      end
      local original_update_scroll_bar = html_w._updateScrollBar
      html_w._updateScrollBar = function(w, ...)
          original_update_scroll_bar(w, ...)
          notify_html_scroll_position(w)
      end
      -- ScrollHtmlWidget 缺少 scrollToTop/scrollToBottom，补上适配器
      html_w.scrollToTop    = function(w) w:scrollToRatio(0) end
      html_w.scrollToBottom = function(w) w:scrollToRatio(1) end
      notify_html_scroll_position(html_w)
      self.scroll_text_w = html_w
  end
  -- 文本容器 - 包装滚动文本组件
  self.textw = FrameContainer:new {
    padding = self.text_padding,
    margin = self.text_margin,
    bordersize = 0,
    self.scroll_text_w
  }

  -- 主框架 - 包含所有UI元素
  self.frame = FrameContainer:new {
    radius = Size.radius.window,      -- 窗口圆角
    padding = 0,
    margin = 0,
    background = Blitbuffer.COLOR_WHITE,  -- 白色背景
    VerticalGroup:new {  -- 垂直布局：标题栏 + 文本区 + 按钮区
      titlebar,
      CenterContainer:new {  -- 文本区域居中
        dimen = Geom:new {
          w = self.width,
          h = self.textw:getSize().h,
        },
        self.textw,
      },
      CenterContainer:new {  -- 按钮区域居中
        dimen = Geom:new {
          w = self.width,
          h = self.button_table:getSize().h,
        },
        self.button_table,
      }
    }
  }
  -- 可移动容器 - 支持拖拽移动整个对话框
  self.movable = MovableContainer:new {
    -- 我们将自己处理这些事件，未处理时再转发给MovableContainer
    ignore_events = {
      -- 这些事件会影响文本组件，可能被文本组件处理
      "swipe", "hold", "hold_release", "hold_pan",
      -- 这些事件对文本组件无直接影响，但在文本选择时需要检查
      "touch", "pan", "pan_release",
    },
    self.frame,
  }
  -- 最外层容器 - 负责整体布局和定位
  self[1] = WidgetContainer:new {
    align = self.align,
    dimen = self.region,
    self.movable,
  }
end

--[[--
添加笔记功能 - 调用外部回调函数处理笔记添加
]]
function CaudexViewer:addToNote()
  if self.onAddToNote then
    self:onAddToNote()
  end
end

--[[--
提问功能 - 显示输入对话框让用户输入新问题
创建输入对话框，获取用户输入并触发提问回调
]]
function CaudexViewer:askAnotherQuestion()
  local input_dialog
  input_dialog = InputDialog:new {
    title = _("Ask another question"),           -- 对话框标题
    input = "",                                  -- 初始输入为空
    input_type = "text",                         -- 输入类型为文本
    description = _("Enter your question for Caudex."),  -- 输入提示
    buttons = {
      {
        {
          text = _("Cancel"),                    -- 取消按钮
          callback = function()
            UIManager:close(input_dialog)        -- 关闭对话框
          end,
        },
        {
          text = _("Ask"),                       -- 提问按钮
          is_enter_default = true,               -- 设为默认按钮（回车触发）
          callback = function()
            local input_text = input_dialog:getInputText()  -- 获取输入文本
            if input_text and input_text ~= "" then        -- 检查非空
              self:onAskQuestion(input_text)               -- 调用提问回调
            end
            UIManager:close(input_dialog)                  -- 关闭对话框
          end,
        },
      },
    },
  }
  UIManager:show(input_dialog)    -- 显示输入对话框
  input_dialog:onShowKeyboard()   -- 自动显示键盘
end

--[[--
组件关闭时的处理 - 清理UI状态
]]
function CaudexViewer:onCloseWidget()
  self._closed = true
  self._update_pending = false
  UIManager:setDirty(nil, function()
    return "partial", self.frame.dimen
  end)
end

--[[--
组件显示时的处理 - 刷新UI显示
]]
function CaudexViewer:onShow()
  UIManager:setDirty(self, function()
    return "partial", self.frame.dimen
  end)
  return true
end

--[[--
点击关闭事件处理 - 点击对话框外部区域关闭
@param arg 事件参数（未使用）
@param ges_ev 手势事件对象
]]
function CaudexViewer:onTapClose(_, ges_ev)
  if ges_ev.pos:notIntersectWith(self.frame.dimen) then
    self:onClose()  -- 点击外部区域，关闭对话框
  end
  return true
end

--[[--
多指滑动手势处理 - 任何多指滑动都关闭对话框
@param arg 事件参数（未使用）
@param ges_ev 手势事件对象（未使用）
]]
function CaudexViewer:onMultiSwipe(_, _)
  -- 与其他全屏组件保持一致：多指滑动关闭
  self:onClose()
  return true
end

--[[--
关闭对话框 - 清理资源并触发回调
]]
function CaudexViewer:onClose()
  self._closed = true
  self._update_pending = false
  UIManager:close(self)
  -- 后台结果打开的 viewer 没有活跃高亮上下文，安全检查后再调用
  if self.ui and self.ui.highlight and self.ui.highlight.onClose then
    self.ui.highlight:onClose()
  end
  if self.close_callback then
    self.close_callback()
  end
  return true
end

--[[--
滑动手势处理 - 在文本区域内滑动时滚动文本
@param arg 事件参数（未使用）
@param ges 手势对象
]]
function CaudexViewer:onSwipe(_, ges)
  if ges.pos:intersectWith(self.textw.dimen) then
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" then
      self.scroll_text_w:scrollText(1)    -- 向西滑动（向右），向下滚动一行
      return true
    elseif direction == "east" then
      self.scroll_text_w:scrollText(-1)   -- 向东滑动（向左），向上滚动一行
      return true
    else
      -- 其他方向滑动：触发全屏刷新
      UIManager:setDirty(nil, "full")
      -- 长对角线滑动可能用于截图，允许事件继续传播
      return false
    end
  end
  -- 在文本区域外滑动：交给MovableContainer处理窗口移动
  return self.movable:onMovableSwipe(_, ges)
end

--[[--
长按开始文本选择 - 转发给MovableContainer处理
@param _ 事件参数（未使用）
@param ges 手势对象
]]
function CaudexViewer:onHoldStartText(_, ges)
  -- 将TextBoxWidget未处理的长按事件转发给MovableContainer
  return self.movable:onMovableHold(_, ges)
end

--[[--
长按拖动文本选择 - 条件转发给MovableContainer
@param _ 事件参数（未使用）
@param ges 手势对象
]]
function CaudexViewer:onHoldPanText(_, ges)
  -- 只有在之前转发了Touch事件时才转发HoldPan
  -- 避免在文本选择时意外移动窗口
  if self.movable._touch_pre_pan_was_inside then
    return self.movable:onMovableHoldPan(_, ges)
  end
end

--[[--
长按释放文本选择 - 转发给MovableContainer处理
@param _ 事件参数（未使用）
@param ges 手势对象
]]
function CaudexViewer:onHoldReleaseText(_, ges)
  -- 将TextBoxWidget未处理的长按释放事件转发给MovableContainer
  return self.movable:onMovableHoldRelease(_, ges)
end

--[[--
触摸事件转发 - 条件转发给MovableContainer
避免在文本选择时意外移动窗口
@param _ 事件参数（未使用）
@param ges 手势对象
]]
function CaudexViewer:onForwardingTouch(_, ges)
  -- 只有在文本区域外才转发触摸事件给MovableContainer
  if not ges.pos:intersectWith(self.textw.dimen) then
    return self.movable:onMovableTouch(_, ges)
  else
    -- 确保重置状态，避免错误转发HoldPan事件
    self.movable._touch_pre_pan_was_inside = false
  end
end

--[[--
拖动事件转发 - 条件转发给MovableContainer
@param _ 事件参数（未使用）
@param ges 手势对象
]]
function CaudexViewer:onForwardingPan(_, ges)
  -- 只有在之前转发了Touch事件或正在移动时才转发拖动事件
  if self.movable._touch_pre_pan_was_inside or self.movable._moving then
    return self.movable:onMovablePan(_, ges)
  end
end

--[[--
拖动释放事件转发 - 转发给MovableContainer
@param _ 事件参数（未使用）
@param ges 手势对象
]]
function CaudexViewer:onForwardingPanRelease(_, ges)
  -- onMovablePanRelease函数内部有足够的检查，可以直接转发
  return self.movable:onMovablePanRelease(_, ges)
end

--[[--
文本选择处理 - 复制选中文本到剪贴板
@param text 选中的文本内容
@param hold_duration 长按持续时间
@param start_idx 选择开始索引
@param end_idx 选择结束索引
@param to_source_index_func 源索引转换函数
]]
function CaudexViewer:handleTextSelection(text, hold_duration, start_idx, end_idx, to_source_index_func)
  -- 如果有自定义文本选择回调，优先使用
  if self.text_selection_callback then
    self.text_selection_callback(text, hold_duration, start_idx, end_idx, to_source_index_func)
    return
  end
  -- 如果设备支持剪贴板，复制选中文本
  if Device:hasClipboard() then
    Device.input.setClipboardText(text)
    -- 显示复制成功通知
    UIManager:show(Notification:new {
      text = start_idx == end_idx and _("Word copied to clipboard.")    -- 单个单词
          or _("Selection copied to clipboard."),                       -- 多个单词
    })
  end
end

--[[--
更新显示内容 - 关闭当前对话框并显示新内容
用于刷新Caudex响应内容；Markdown路径带 200ms debounce 防止频繁重排
@param new_text 新的文本内容
]]
function CaudexViewer:update(new_text)
  if self._closed then return end
  -- 纯文本路径：行为与改动前完全一致
  if not self.render_markdown then
    UIManager:close(self)  -- 关闭当前对话框
    -- 创建新的查看器实例
    local updated_viewer = CaudexViewer:new {
      ui = self.ui,
      title = self.title,
      text = new_text,
      width = self.width,
      height = self.height,
      buttons_table = self.buttons_table,
      onAskQuestion = self.onAskQuestion,
      onAddToNote = self.onAddToNote,
    }
    updated_viewer.scroll_text_w:scrollToBottom()  -- 滚动到新内容底部
    UIManager:show(updated_viewer)  -- 显示更新后的对话框
    return
  end
  -- Markdown 路径：debounce 200ms，防止流式更新反复触发 MuPDF 排版
  self._last_update_text = new_text
  if self._update_pending then return end   -- 丢弃中间帧，只保留最后一次
  self._update_pending = true
  UIManager:scheduleIn(0.2, function()
    if self._closed then
      self._update_pending = false
      return
    end
    self._update_pending = false
    local text = self._last_update_text
    UIManager:close(self)  -- 关闭当前对话框
    -- 创建新的查看器实例（传递 Markdown 相关参数）
    local updated_viewer = CaudexViewer:new {
      ui = self.ui,
      title = self.title,
      text = text,
      width = self.width,
      height = self.height,
      buttons_table = self.buttons_table,
      render_markdown = self.render_markdown,
      markdown_max_size = self.markdown_max_size,
      onAskQuestion = self.onAskQuestion,
      onAddToNote = self.onAddToNote,
    }
    updated_viewer.scroll_text_w:scrollToBottom()  -- 滚动到新内容底部
    UIManager:show(updated_viewer)  -- 显示更新后的对话框
  end)
end

return CaudexViewer
