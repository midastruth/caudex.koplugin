-- Caudex 插件配置样板
-- 位置：caudex.koplugin/configuration.lua
--
-- 使用前请先修改 reader_ai_base_url。
-- 注意：这里配置的是你的 Reader AI / Book-Aware 后端服务地址，
-- 不是 OpenAI 的 /v1/chat/completions 地址。

return {
  ---------------------------------------------------------------------------
  -- 必填：后端服务地址
  ---------------------------------------------------------------------------
  -- 示例：
  -- reader_ai_base_url = "http://192.168.1.100:8000",
  -- reader_ai_base_url = "https://your-domain.example.com",
  --
  -- 请把下面的空字符串改成你自己的服务地址。
  -- 如果保持为空，点击 Caudex 时仍会提示“配置错误”。
  reader_ai_base_url = "https://read.opensociety.eu.org",

  ---------------------------------------------------------------------------
  -- 可选：接口路径。一般保持默认即可。
  ---------------------------------------------------------------------------
  reader_ai_query_path = "/ai/query",
  reader_ai_import_epub_path = "/books/import/epub",
  reader_ai_books_path = "/books",
  reader_ai_book_download_path = "/epub",

  ---------------------------------------------------------------------------
  -- 可选：Book-Aware 超时（秒）。上传 EPUB 可能较慢，避免 LuaSec wantread 超时。
  ---------------------------------------------------------------------------
  reader_ai_book_lookup_timeout = 30,
  reader_ai_import_epub_timeout = 300,
  reader_ai_book_download_timeout = 300,

  ---------------------------------------------------------------------------
  -- 可选：语言设置
  ---------------------------------------------------------------------------
  -- "zh" 表示中文；也可以改为 "en" 或 "auto"。
  language = "zh",

  features = {
    -- 词典/解释语言
    dictionary_language = "zh",
  },

  ---------------------------------------------------------------------------
  -- 可选：自动上传当前书籍到 Book-Aware 后端
  ---------------------------------------------------------------------------
  -- 如果你不确定后端是否支持，建议保持 false。
  reader_ai_auto_upload_book = false,

  ---------------------------------------------------------------------------
  -- 可选：从 Book-Aware 后端同步 EPUB 到 KOReader 本地目录
  ---------------------------------------------------------------------------
  -- 菜单路径：Tools/工具 → Caudex → Book-Aware book sync
  -- 打开后会显示书籍同步界面，可选择单本或同步全部。
  -- 不填 reader_ai_sync_dir 时，默认同步到当前书籍所在目录或 KOReader 最近目录。
  -- reader_ai_sync_dir = "/mnt/onboard/Books",
  reader_ai_auto_sync_books = false,

  ---------------------------------------------------------------------------
  -- 可选：Web 高亮自动同步
  -- true  = 打开书时自动 sync（pull pending + push 本地改动 + 应用删除），
  --         关闭书时自动 push 本地 note/color 改动回 book-aware。
  -- false = 只通过菜单 "Sync web highlights" 手动触发（默认，安全起见）。
  ---------------------------------------------------------------------------
  auto_sync_web_highlights = false,

  ---------------------------------------------------------------------------
  -- 可选：KOReader 新建高亮后自动上传到 Book-Aware
  -- true  = 每次在 KOReader 新建高亮后，延迟约 2 秒自动上传本地新高亮。
  --         若 auto_sync_web_highlights = true，则无需单独开启，本功能也会启用。
  -- false = 不自动上传新高亮；仍可通过菜单 "Sync web highlights" 手动上传。
  ---------------------------------------------------------------------------
  auto_upload_new_highlights = true,
}
