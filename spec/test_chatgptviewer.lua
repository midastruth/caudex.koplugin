-- Unit tests for chatgptviewer.lua Markdown rendering integration
--
-- 设计要点：
--   1. 对所有 KOReader UI 组件使用 stub，不依赖真实渲染环境
--   2. 验证 _shouldUseHtml 纯函数逻辑
--   3. 验证 init() 根据 render_markdown/markdown_max_size 选择正确的 widget
--   4. 验证 update() 的 debounce 行为（Markdown 路径）与原始行为（纯文本路径）

local H = require("spec.helpers")

H.section("L. chatgptviewer.lua markdown integration")

-- ── Mock 基础设施 ─────────────────────────────────────────────────────────────

local spy = H.mock_koreader()

-- 增强 device mock：chatgptviewer 需要 screen 方法和 input.group
package.loaded["device"] = {
    hasKeys        = function() return false end,
    isTouchDevice  = function() return false end,
    hasClipboard   = function() return false end,
    screen = {
        getWidth    = function() return 600 end,
        getHeight   = function() return 800 end,
        scaleBySize = function(_, n) return n end,
    },
    input = { group = { Back = "back" }, setClipboardText = function() end },
}

package.loaded["ui/bidi"] = {
    flipDirectionIfMirroredUILayout = function(d) return d end,
}

local function make_geom(args)
    args = args or {}
    return {
        x = args.x or 0, y = args.y or 0,
        w = args.w or 600, h = args.h or 800,
        intersectWith    = function() return true end,
        notIntersectWith = function() return false end,
    }
end
package.loaded["ui/geometry"] = {
    new = function(_, args) return make_geom(args) end,
}

package.loaded["ffi/blitbuffer"] = { COLOR_BLACK = 0, COLOR_WHITE = 1 }

package.loaded["ui/size"] = {
    padding = { large = 10, default = 5 },
    margin  = { small = 2 },
    radius  = { window = 5 },
}

package.loaded["ui/font"] = {
    getFace = function(_, name) return { name = name or "default" } end,
}

-- 通用 widget 工厂：返回带 getSize/getHeight 的最小 stub
local function make_widget(type_name)
    local W = {}
    W.__index = W
    W.new = function(_, args)
        local obj = {}
        if type(args) == "table" then
            for k, v in pairs(args) do obj[k] = v end
        end
        setmetatable(obj, W)
        obj._type     = type_name
        obj.getSize   = function() return { h = 50, w = 100 } end
        obj.getHeight = function() return 50 end
        return obj
    end
    return W
end

package.loaded["ui/widget/buttontable"] = {
    new = function(_, _args)
        return {
            _type       = "ButtonTable",
            getSize     = function() return { h = 50, w = 100 } end,
            getButtonById = function() return nil end,
        }
    end,
}
package.loaded["ui/widget/container/centercontainer"]  = make_widget("CenterContainer")
package.loaded["ui/widget/container/framecontainer"]   = make_widget("FrameContainer")
package.loaded["ui/widget/container/movablecontainer"] = make_widget("MovableContainer")
package.loaded["ui/widget/container/widgetcontainer"]  = make_widget("WidgetContainer")
package.loaded["ui/widget/titlebar"]                   = make_widget("TitleBar")
package.loaded["ui/widget/verticalgroup"]              = make_widget("VerticalGroup")
package.loaded["ui/widget/notification"]               = make_widget("Notification")
package.loaded["ui/gesturerange"] = {
    new = function(_, args) return args or {} end,
}

-- ScrollTextWidget mock
local created_stw = {}
local STW_mock = {
    new = function(_, args)
        local obj = { _type = "ScrollTextWidget" }
        if type(args) == "table" then
            for k, v in pairs(args) do obj[k] = v end
        end
        obj.scrollToBottom = function() end
        obj.scrollToTop    = function() end
        obj.scrollText     = function() end
        table.insert(created_stw, obj)
        return obj
    end,
}
package.loaded["ui/widget/scrolltextwidget"] = STW_mock

-- ScrollHtmlWidget mock
local created_shw = {}
local SHW_mock = {
    new = function(_, args)
        local obj = { _type = "ScrollHtmlWidget" }
        if type(args) == "table" then
            for k, v in pairs(args) do obj[k] = v end
        end
        obj.htmlbox_widget = {
            page_count = 4,
            page_number = 1,
            setPageNumber = function(self, n) self.page_number = n end,
        }
        obj._updateScrollBar = function() end
        obj.scrollToRatio = function(w, ratio)
            local page_count = w.htmlbox_widget.page_count
            local page_num = 1 + math.floor(page_count * math.max(0, math.min(1, ratio)))
            if page_num > page_count then page_num = page_count end
            if page_num == w.htmlbox_widget.page_number then return end
            w.htmlbox_widget:setPageNumber(page_num)
            w:_updateScrollBar()
        end
        obj.scrollText = function(w, direction)
            if direction == 0 then return end
            local page_num = w.htmlbox_widget.page_number + (direction > 0 and 1 or -1)
            page_num = math.max(1, math.min(w.htmlbox_widget.page_count, page_num))
            if page_num == w.htmlbox_widget.page_number then return end
            w.htmlbox_widget:setPageNumber(page_num)
            w:_updateScrollBar()
        end
        table.insert(created_shw, obj)
        return obj
    end,
}
package.loaded["ui/widget/scrollhtmlwidget"] = SHW_mock

-- MarkdownRenderer mock
local mr_calls = {}
package.loaded["markdown_renderer"] = {
    toHtml = function(text)
        table.insert(mr_calls, text)
        return "<p>" .. (text or "") .. "</p>", nil
    end,
    DEFAULT_CSS = "body { margin: 0; }",
}

-- 给 InputContainer mock 添加 :extend（类继承支持）
local IC_mock = package.loaded["ui/widget/container/inputcontainer"]
IC_mock.extend = function(self, props)
    local subclass = setmetatable({}, { __index = self })
    subclass.__index = subclass
    for k, v in pairs(props or {}) do
        subclass[k] = v
    end
    subclass.new = function(cls, o)
        o = o or {}
        setmetatable(o, { __index = cls })
        if o.init then o:init() end
        return o
    end
    subclass.extend = IC_mock.extend
    return subclass
end

-- ── 加载真实的 chatgptviewer.lua ──────────────────────────────────────────────

H.reset("chatgptviewer")
local ChatGPTViewer = require("chatgptviewer")

-- ── 1. _shouldUseHtml 静态帮助函数 ──────────────────────────────────────────

H.is_false("_shouldUseHtml: render_markdown=false → false",
    ChatGPTViewer._shouldUseHtml("hello", false, 8192))

H.is_true("_shouldUseHtml: short text + render_markdown=true → true",
    ChatGPTViewer._shouldUseHtml("hello", true, 8192))

H.is_false("_shouldUseHtml: text exceeds markdown_max_size → false",
    ChatGPTViewer._shouldUseHtml(string.rep("x", 100), true, 50))

H.is_false("_shouldUseHtml: empty text → false",
    ChatGPTViewer._shouldUseHtml("", true, 8192))

H.is_false("_shouldUseHtml: nil text → false",
    ChatGPTViewer._shouldUseHtml(nil, true, 8192))

-- ── 2. init() widget 选择 ────────────────────────────────────────────────────

-- reset trackers
created_stw = {}
created_shw = {}
mr_calls    = {}

local v1 = ChatGPTViewer:new {
    title = "test", text = "hello **world**", render_markdown = false,
}
H.eq("render_markdown=false: scroll_text_w is ScrollTextWidget",
    v1.scroll_text_w._type, "ScrollTextWidget")
H.eq("render_markdown=false: MarkdownRenderer.toHtml NOT called",
    #mr_calls, 0)

-- reset trackers
created_stw = {}
created_shw = {}
mr_calls    = {}

local v2 = ChatGPTViewer:new {
    title = "test", text = "hello **world**", render_markdown = true,
}
H.eq("render_markdown=true: scroll_text_w is ScrollHtmlWidget",
    v2.scroll_text_w._type, "ScrollHtmlWidget")
H.is_true("render_markdown=true: MarkdownRenderer.toHtml called",
    #mr_calls > 0)

local html_scroll_positions = {}
v2._buttons_scroll_callback = function(low, high)
    table.insert(html_scroll_positions, { low, high })
end
v2.scroll_text_w:scrollText(1)
H.eq("render_markdown=true: HTML scrollText notifies button callback",
    html_scroll_positions[1], { 0.25, 0.5 })
v2.scroll_text_w:scrollToBottom()
H.eq("render_markdown=true: HTML scrollToBottom notifies button callback",
    html_scroll_positions[2], { 0.75, 1 })

-- reset trackers
created_stw = {}
created_shw = {}
mr_calls    = {}

local long_text = string.rep("x", 100)
local v3 = ChatGPTViewer:new {
    title = "test", text = long_text,
    render_markdown = true, markdown_max_size = 50,
}
H.eq("text > markdown_max_size: falls back to ScrollTextWidget",
    v3.scroll_text_w._type, "ScrollTextWidget")
H.eq("text > markdown_max_size: MarkdownRenderer.toHtml NOT called",
    #mr_calls, 0)

-- ── 3. update() 行为 ─────────────────────────────────────────────────────────

-- 3a. render_markdown=false → 立即 close+show，不使用 scheduleIn
local v4 = ChatGPTViewer:new { title = "t", text = "init", render_markdown = false }
spy.closed    = {}
spy.shown     = {}
spy.scheduled = {}
v4:update("updated text")
H.eq("update() non-md: immediately closes viewer",    #spy.closed,    1)
H.eq("update() non-md: immediately shows new viewer", #spy.shown,     1)
H.eq("update() non-md: no scheduleIn used",           #spy.scheduled, 0)

-- 3b. render_markdown=true → 走 debounce，使用 scheduleIn
local v5 = ChatGPTViewer:new { title = "t", text = "init", render_markdown = true }
spy.closed    = {}
spy.shown     = {}
spy.scheduled = {}
v5:update("update 1")
H.eq("update() md: does not close immediately",    #spy.closed,    0)
H.eq("update() md: does not show immediately",     #spy.shown,     0)
H.eq("update() md: scheduleIn called once",        #spy.scheduled, 1)

-- 3c. debounce：第二次调用被丢弃，只保留最后文本
v5:update("update 2")
H.eq("update() md: second call keeps scheduleIn count at 1", #spy.scheduled, 1)
H.eq("update() md: last text saved for deferred apply",
    v5._last_update_text, "update 2")

-- 3d. close during debounce: scheduled callback must not reopen viewer
v5:onClose()
spy.scheduled[1].fn()
H.eq("update() md: close during debounce does not show new viewer", #spy.shown, 0)
H.eq("update() md: close during debounce does not close twice",     #spy.closed, 1)
H.is_false("update() md: close during debounce clears pending flag", v5._update_pending)

-- 3e. active debounce still applies update when not closed
local v6 = ChatGPTViewer:new { title = "t", text = "init", render_markdown = true }
spy.closed    = {}
spy.shown     = {}
spy.scheduled = {}
v6:update("live update")
spy.scheduled[1].fn()
H.eq("update() md: active debounce closes old viewer", #spy.closed, 1)
H.eq("update() md: active debounce shows new viewer",  #spy.shown, 1)
H.eq("update() md: active debounce uses latest text",  spy.shown[1].text, "live update")
