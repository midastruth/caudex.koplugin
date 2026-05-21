-- Unit tests for markdown_renderer.lua
--
-- 设计要点：
--   1. 不依赖真实 KOReader 运行时；用 stub 替换 luamd 引擎
--   2. 同时验证“引擎可用”和“引擎缺失（退化为纯文本转义）”两条路径
--   3. 验证 DEFAULT_CSS 包含足够的样式 selector

local H = require("spec.helpers")

H.section("K. markdown_renderer.lua")

-- ── 工具：注入一个假的 luamd 引擎 ────────────────────────────────────────────
local function install_fake_md_engine(transform)
  -- luamd 真实接口：模块表本身可被 __call，也提供 renderString
  -- 见 /home/midas/workspace/projects/koreader/frontend/apps/filemanager/lib/md.lua
  local fake = setmetatable({
    renderString = function(s, _opts) return transform(s) end,
  }, {
    __call = function(_self, s, _opts) return transform(s) end,
  })
  package.loaded["apps/filemanager/lib/md"] = fake
end

local function uninstall_md_engine()
  package.loaded["apps/filemanager/lib/md"] = nil
end

local function fresh_renderer()
  package.loaded["markdown_renderer"] = nil
  return require("markdown_renderer")
end

-- ── 1. 引擎可用：能正确返回 HTML ───────────────────────────────────────────
install_fake_md_engine(function(s)
  -- 一个极简“假 markdown 渲染”：仅把 **x** -> <strong>x</strong>
  -- # x -> <h1>x</h1>，足以让测试断言看到典型标签
  local out = s
  out = out:gsub("^# (.-)\n", "<h1>%1</h1>\n")
  out = out:gsub("%*%*(.-)%*%*", "<strong>%1</strong>")
  out = "<p>" .. out:gsub("\n\n", "</p><p>") .. "</p>"
  return out
end)

local MR = fresh_renderer()

do
  local html, err = MR.toHtml("# Title\n\nhello **world**")
  H.is_true("toHtml returns string when engine ok", type(html) == "string")
  H.is_true("toHtml has no error when engine ok",   err == nil)
  H.contains("rendered html contains <h1>",          html, "<h1>Title</h1>")
  H.contains("rendered html contains <strong>",      html, "<strong>world</strong>")
end

-- 边界：nil / 空串 / 非字符串
do
  local html, err = MR.toHtml(nil)
  H.eq("toHtml(nil) returns empty string", html, "")
  H.is_true("toHtml(nil) no error",         err == nil)

  html, err = MR.toHtml("")
  H.eq("toHtml('') returns empty string",   html, "")
  H.is_true("toHtml('') no error",          err == nil)

  html, err = MR.toHtml(12345)
  H.eq("toHtml(number) coerces to string",  html, "12345")
  H.is_true("toHtml(number) sets err",      err ~= nil)
end

-- toFullHtml: 含 doctype + style + body
do
  local full = MR.toFullHtml("# Title\n")
  H.contains("toFullHtml has <!DOCTYPE html>", full, "<!DOCTYPE html>")
  H.contains("toFullHtml has <style>",          full, "<style>")
  H.contains("toFullHtml embeds default css",   full, "line-height")
  H.contains("toFullHtml has <body>",           full, "<body>")
  H.contains("toFullHtml contains rendered h1", full, "<h1>Title</h1>")
end

-- toFullHtml 接受 extra_css 拼接
do
  local full = MR.toFullHtml("hi", "/* user-css */ .x { color: red; }")
  H.contains("toFullHtml appends extra css", full, "/* user-css */")
end

-- ── 2. DEFAULT_CSS 包含关键 selector，保证渲染观感 ─────────────────────────
do
  local css = MR.DEFAULT_CSS
  H.contains("DEFAULT_CSS styles body",       css, "body")
  H.contains("DEFAULT_CSS styles headings",   css, "h1")
  H.contains("DEFAULT_CSS styles code",       css, "code")
  H.contains("DEFAULT_CSS styles pre",        css, "pre")
  H.contains("DEFAULT_CSS styles blockquote", css, "blockquote")
  H.contains("DEFAULT_CSS styles ul/ol",      css, "ol, ul")
  H.contains("DEFAULT_CSS styles table",      css, "table")
end

-- ── 3. 引擎缺失：退化为纯文本 + HTML 转义 ──────────────────────────────────
uninstall_md_engine()
MR = fresh_renderer()  -- 重新加载以丢弃前一次缓存

do
  local html, err = MR.toHtml("a<b>&c")
  H.is_true("fallback returns non-empty html",   html ~= nil and html ~= "")
  H.is_true("fallback reports engine missing",   err ~= nil)
  H.contains("fallback escapes <",                html, "&lt;")
  H.contains("fallback escapes >",                html, "&gt;")
  H.contains("fallback escapes &",                html, "&amp;")
  -- 不应留下未转义的原始尖括号
  H.is_false("fallback strips raw '<b>'",         html:find("<b>", 1, true) ~= nil)
end

do
  local html = MR.toHtml("line1\nline2")
  H.contains("fallback converts \\n to <br/>", html, "<br/>")
end

-- ── 4. 引擎返回 nil/空（如解析异常）应优雅退化 ──────────────────────────────
install_fake_md_engine(function(_s) return nil, "boom" end)
MR = fresh_renderer()

do
  local html, err = MR.toHtml("<script>alert(1)</script>")
  H.is_true("nil engine result still returns string", type(html) == "string" and html ~= "")
  H.is_true("nil engine result surfaces err",         err ~= nil)
  H.contains("nil engine result escapes raw HTML",     html, "&lt;script&gt;")
  H.is_false("nil engine result does not expose raw tag", html:find("<script>", 1, true) ~= nil)
end

install_fake_md_engine(function(_s) return "", nil end)
MR = fresh_renderer()
do
  local html, err = MR.toHtml("a<b>&c")
  H.is_true("empty engine result still returns string", type(html) == "string" and html ~= "")
  H.is_true("empty engine result surfaces err",         err ~= nil)
  H.contains("empty engine result escapes <",           html, "&lt;")
  H.contains("empty engine result escapes &",           html, "&amp;")
end

-- 清理：避免污染后续 spec
uninstall_md_engine()
package.loaded["markdown_renderer"] = nil
