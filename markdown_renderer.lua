--[[--
Markdown 渲染辅助模块
将 Markdown 文本转换为可被 ScrollHtmlWidget 渲染的 HTML 片段，
并提供一份适配 KOReader/MuPDF HTML 渲染引擎的默认样式表。

参考实现：
  - frontend/apps/filemanager/filemanagerconverter.lua : mdToHtml()
  - frontend/ui/widget/dictquicklookup.lua            : getHtmlDictionaryCss()

设计目标：
  1. 单一职责 —— 只负责 md→html 转换 + 默认 CSS 提供
  2. 对 nil / 空字符串 / 转换失败健壮（永远返回 string，便于上层无脑使用）
  3. 不依赖 ChatGPTViewer，便于离线单元测试
]]

local MarkdownRenderer = {}

-- 默认样式：参考词典查看器，针对 MuPDF HTML 渲染做了适配
-- MuPDF 对 rem/px 支持不完善，所以用 em / % 度量
MarkdownRenderer.DEFAULT_CSS = [[
@page {
    margin: 0;
    font-family: 'Noto Sans';
}
body {
    margin: 0;
    line-height: 1.4;
    text-align: left;
}
h1, h2, h3, h4, h5, h6 {
    margin: 0.6em 0 0.3em 0;
    line-height: 1.2;
}
h1 { font-size: 1.6em; }
h2 { font-size: 1.4em; }
h3 { font-size: 1.2em; }
p {
    margin: 0.4em 0;
}
ol, ul {
    margin: 0.3em 0;
    padding: 0 1.7em;
}
li {
    margin: 0.15em 0;
}
blockquote {
    margin: 0.4em 1em;
    padding-left: 0.6em;
    border-left: 3px solid #888;
    color: #444;
}
code {
    font-family: 'Noto Sans Mono';
    background-color: #eeeeee;
    padding: 0 0.2em;
}
pre {
    font-family: 'Noto Sans Mono';
    background-color: #eeeeee;
    padding: 0.4em 0.6em;
    margin: 0.4em 0;
    white-space: pre-wrap;
}
pre code {
    background-color: transparent;
    padding: 0;
}
hr {
    border: 0;
    border-top: 1px solid #888;
    margin: 0.6em 0;
}
table {
    border-collapse: collapse;
    margin: 0.4em 0;
}
th, td {
    border: 1px solid #888;
    padding: 0.2em 0.4em;
}
a {
    text-decoration: underline;
}
]]

local function escape_plaintext(text)
    return tostring(text)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub("\n", "<br/>")
end

-- 惰性加载 luamd —— 既允许真实运行环境，又方便测试中替换
local function load_md_engine()
    local ok, MD = pcall(require, "apps/filemanager/lib/md")
    if ok then return MD end
    return nil
end

--- 把 Markdown 文本转成 HTML 片段（body 内部，不含 <html>/<body> 标签）。
--- 永远返回 string；不会抛异常。
---@param md_text string|nil 原始 Markdown 文本
---@return string html_body
---@return string|nil err 转换失败时给出的错误说明（用于日志）
function MarkdownRenderer.toHtml(md_text)
    if md_text == nil or md_text == "" then
        return "", nil
    end
    if type(md_text) ~= "string" then
        return escape_plaintext(md_text), "input is not a string"
    end

    local MD = load_md_engine()
    if not MD then
        -- 引擎不可用 —— 边界安全地退化为纯文本：对 HTML 特殊字符做最小转义，保留换行
        return "<p>" .. escape_plaintext(md_text) .. "</p>", "luamd engine not available"
    end

    local html, err = MD(md_text, {})
    if not html or html == "" then
        -- 渲染器失败时绝不能把原始 Markdown 当 HTML 交给 ScrollHtmlWidget。
        return "<p>" .. escape_plaintext(md_text) .. "</p>", err or "empty render result"
    end
    return html, nil
end

--- 把 toHtml 的结果包成完整 HTML 文档（带 <head><style>）。
--- 主要供调试/导出使用；ScrollHtmlWidget 实际只需要 body 片段 + css 参数。
function MarkdownRenderer.toFullHtml(md_text, extra_css)
    local body = MarkdownRenderer.toHtml(md_text)
    local css = MarkdownRenderer.DEFAULT_CSS .. (extra_css or "")
    return string.format(
        "<!DOCTYPE html>\n<html><head><style>%s</style></head><body>%s</body></html>",
        css, body
    )
end

return MarkdownRenderer
