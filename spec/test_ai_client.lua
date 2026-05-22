local H = require("spec.helpers")

H.section("H. caudex/ai_client.lua")

-- ── shared state ──────────────────────────────────────────────────────────

local last_https_timeout = nil
local request_results    = {}  -- queue: each entry is returned by next request()

local function next_result()
  return table.remove(request_results, 1) or { nil, nil, nil }
end

-- Pre-declare so closures can capture by upvalue (Lua self-reference pattern).
local http_lib
local https_lib

local function make_libs()
  http_lib = {
    TIMEOUT = 10,
    request = function(_)
      local r = next_result()
      return r[1], r[2], r[3]
    end,
  }
  https_lib = {
    TIMEOUT = 10,
    request = function(_)
      last_https_timeout = https_lib.TIMEOUT  -- upvalue; valid after assignment
      local r = next_result()
      return r[1], r[2], r[3]
    end,
  }
end

-- ── helper: fresh AiClient with controllable request mocks ────────────────

local function load_ai_client(config)
  H.reset("caudex.ai_client", "caudex.config", "caudex.util")
  package.loaded["socket.http"] = http_lib
  package.loaded["ssl.https"]   = https_lib
  package.loaded["socket"]      = { sleep = function() end }
  package.loaded["ltn12"] = {
    sink   = {
      table = function(t) return function(c) if c then table.insert(t, c) end return 1 end end,
      file  = function(f) return function(c) if c then f:write(c) else f:close() end return 1 end end,
    },
    source = { string = function(s) local d=false return function() if not d then d=true return s end end end },
  }
  package.loaded["json"] = {
    encode = function() return "{}" end,
    decode = function() return {} end,
  }
  local cfg
  if type(config) == "table" then
    cfg = {}
    for k, v in pairs(config) do cfg[k] = v end
    if not cfg.reader_ai_base_url then cfg.reader_ai_base_url = "https://example.com" end
  else
    cfg = { reader_ai_base_url = config or "https://example.com" }
  end
  package.loaded["caudex.config"] = {
    get      = function() return cfg end,
    validate = function() return true end,
  }
  return require("caudex.ai_client")
end

-- ── Section 1: timeout propagation ────────────────────────────────────────

-- analyzeContent must use 90s timeout on the HTTPS lib.
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  last_https_timeout = nil
  local AiClient = load_ai_client()
  pcall(AiClient.analyzeContent, { content = "test" })
  H.eq("analyzeContent uses 90s timeout", last_https_timeout, 90)
end

-- summarizeContent must also use 90s timeout.
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  last_https_timeout = nil
  local AiClient = load_ai_client()
  pcall(AiClient.summarizeContent, { content = "test" })
  H.eq("summarizeContent uses 90s timeout", last_https_timeout, 90)
end

-- dictionaryLookup should use the default 10s timeout.
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  last_https_timeout = nil
  local AiClient = load_ai_client()
  pcall(AiClient.dictionaryLookup, { term = "serendipity" })
  H.eq("dictionaryLookup uses default 10s timeout", last_https_timeout, 10)
end

-- Book-Aware lookup gets a longer timeout than normal read queries.
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  last_https_timeout = nil
  local AiClient = load_ai_client()
  pcall(AiClient.getBook, "abc123")
  H.eq("getBook uses 30s timeout", last_https_timeout, 30)
end

-- EPUB import gets a long timeout to avoid LuaSec wantread during upload/import.
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  last_https_timeout = nil
  local AiClient = load_ai_client()
  pcall(AiClient.importEpub, { content_base64 = "YWJj" })
  H.eq("importEpub uses 300s timeout", last_https_timeout, 300)
end

-- EPUB import prefers multipart/form-data when a local filepath is supplied.
do
  local tmp = "/tmp/caudex-ai-client-multipart.epub"
  local f = io.open(tmp, "wb"); f:write("EPUBDATA"); f:close()
  local seen_content_type, seen_body = nil, ""
  http_lib = { TIMEOUT = 10, request = function(_) return nil, nil, nil end }
  https_lib = {
    TIMEOUT = 10,
    request = function(params)
      last_https_timeout = https_lib.TIMEOUT
      seen_content_type = params.headers["Content-Type"]
      while true do
        local chunk = params.source()
        if not chunk then break end
        seen_body = seen_body .. chunk
      end
      return 1, 201, {}
    end,
  }
  local AiClient = load_ai_client()
  package.loaded["json"].decode = function() return { ok = true } end
  local ok = pcall(AiClient.importEpub, { filepath = "", path = tmp, filename = "book.epub", book = { sha256 = "abc" } })
  os.remove(tmp)
  H.is_true("importEpub filepath succeeds on HTTP 201", ok)
  H.contains("importEpub filepath uses multipart", seen_content_type or "", "multipart/form-data")
  H.contains("importEpub multipart has epub field", seen_body, "name=\"epub\"; filename=\"book.epub\"")
  H.contains("importEpub multipart streams file bytes", seen_body, "EPUBDATA")
  H.eq("importEpub filepath uses 300s timeout", last_https_timeout, 300)
end

-- Multipart upload closes the EPUB handle even if the transport fails before
-- LuaSocket consumes the request source.
do
  local target = "/tmp/caudex-close-on-early-fail.epub"
  local original_io_open = io.open
  local open_count, close_count = 0, 0
  http_lib = { TIMEOUT = 10, request = function(_) return nil, nil, nil end }
  https_lib = {
    TIMEOUT = 10,
    request = function(_)
      return nil, "wantread", nil
    end,
  }
  local AiClient = load_ai_client()
  package.loaded["caudex.util"].file_stat = function(path)
    if path == target then return 8 end
    return nil
  end
  io.open = function(path, mode)
    if path == target and mode == "rb" then
      open_count = open_count + 1
      local closed = false
      return {
        read = function() return nil end,
        close = function()
          if not closed then
            close_count = close_count + 1
            closed = true
          end
          return true
        end,
      }
    end
    return original_io_open(path, mode)
  end
  local ok, err = pcall(AiClient.importEpub, { filepath = target, filename = "book.epub" })
  io.open = original_io_open
  H.is_false("importEpub early transport failure returns error", ok)
  H.contains("importEpub early transport failure preserves transport detail", tostring(err), "wantread")
  H.eq("importEpub opens source once per retry", open_count, AiClient.MAX_RETRY_ATTEMPTS)
  H.eq("importEpub closes source once per retry", close_count, AiClient.MAX_RETRY_ATTEMPTS)
end

-- Backend EPUB download gets a long timeout too.
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  last_https_timeout = nil
  local AiClient = load_ai_client()
  pcall(AiClient.downloadBook, "abc123", "/tmp/caudex-test-download.epub")
  os.remove("/tmp/caudex-test-download.epub")
  H.eq("downloadBook uses 300s timeout", last_https_timeout, 300)
end

-- EPUB import timeout can be overridden by configuration.
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  last_https_timeout = nil
  local AiClient = load_ai_client({ reader_ai_import_epub_timeout = 123 })
  pcall(AiClient.importEpub, { content_base64 = "YWJj" })
  H.eq("importEpub uses configured timeout", last_https_timeout, 123)
end

-- TIMEOUT is restored after each request (no global side-effect).
do
  make_libs()
  for _ = 1, 3 do request_results[#request_results+1] = {nil, nil, nil} end
  local AiClient = load_ai_client()
  pcall(AiClient.analyzeContent, { content = "test" })
  H.eq("https TIMEOUT restored after analyzeContent", https_lib.TIMEOUT, 10)
end

-- ── Section 2: wantread / transport error classification ──────────────────

-- LuaSec returns (nil, "wantread", nil) when a non-blocking SSL read times out.
-- ai_client should surface this as "Connection failed: wantread", not an HTTP error.
do
  make_libs()
  -- res=nil, code="wantread" → triggers the `elseif not res` branch
  for _ = 1, 3 do request_results[#request_results+1] = {nil, "wantread", nil} end
  local AiClient = load_ai_client()
  local ok, err = pcall(AiClient.analyzeContent, { content = "test" })
  H.is_false("wantread causes error (not success)", ok)
  H.contains("wantread error mentions 'Connection failed'", tostring(err), "Connection failed")
  H.contains("wantread error mentions 'wantread'",          tostring(err), "wantread")
end

-- ── Section 3: retry count ─────────────────────────────────────────────────

-- On repeated connection failure the client retries exactly MAX_RETRY_ATTEMPTS times.
do
  local call_count = 0
  http_lib  = { TIMEOUT = 10, request = function(_) call_count = call_count + 1 return nil, nil, nil end }
  https_lib = { TIMEOUT = 10, request = function(_) call_count = call_count + 1 return nil, nil, nil end }
  local AiClient = load_ai_client()
  pcall(AiClient.analyzeContent, { content = "test" })
  H.eq("analyzeContent retries MAX_RETRY_ATTEMPTS (3) times",
       call_count, AiClient.MAX_RETRY_ATTEMPTS)
end

-- ── Section 4: success path ────────────────────────────────────────────────

-- When the server returns HTTP 200, analyzeContent returns the decoded table.
do
  make_libs()
  -- res=1, code=200 → success branch in http_request_with_retry
  request_results = { {1, 200, {}} }
  local AiClient = load_ai_client()
  -- Mutate the shared json table so the module sees the updated decode.
  package.loaded["json"].decode = function() return { answer = "ok" } end
  local ok, result = pcall(AiClient.analyzeContent, { content = "test" })
  H.is_true("analyzeContent succeeds on HTTP 200", ok)
  H.is_true("analyzeContent returns a table", type(result) == "table")
end

-- listBooks returns the decoded backend object.
do
  make_libs()
  request_results = { {1, 200, {}} }
  local AiClient = load_ai_client()
  package.loaded["json"].decode = function() return { ok = true, books = { { sha256 = "abc123" } } } end
  local ok, result = pcall(AiClient.listBooks)
  H.is_true("listBooks succeeds on HTTP 200", ok)
  H.eq("listBooks decodes books", #result.books, 1)
end

-- Backend create/import endpoints may legitimately return 201 Created.
do
  make_libs()
  request_results = { {1, 201, {}} }
  local AiClient = load_ai_client()
  package.loaded["json"].decode = function() return { ok = true } end
  local ok = pcall(AiClient.importEpub, { content_base64 = "YWJj" })
  H.is_true("importEpub succeeds on HTTP 201", ok)
end

do
  make_libs()
  request_results = { {1, 201, {}} }
  local AiClient = load_ai_client()
  package.loaded["json"].decode = function() return { highlight = { id = "h1" } } end
  local ok = pcall(AiClient.createHighlight, "abc123", { exact = "hello" })
  H.is_true("createHighlight succeeds on HTTP 201", ok)
end

-- downloadBook must fail loudly if the local file write fails, even if the
-- HTTP layer would otherwise report 200.
do
  local target = "/tmp/caudex-write-fail.epub"
  local removed = {}
  local original_io_open = io.open
  local original_os_remove = os.remove
  http_lib = { TIMEOUT = 10, request = function(_) return nil, nil, nil end }
  https_lib = {
    TIMEOUT = 10,
    request = function(params)
      last_https_timeout = https_lib.TIMEOUT
      params.sink("partial epub bytes")
      return 1, 200, {}
    end,
  }
  io.open = function(path, mode)
    if path == target and mode == "wb" then
      return {
        write = function() return nil, "disk full" end,
        close = function() return true end,
      }
    end
    return original_io_open(path, mode)
  end
  os.remove = function(path)
    table.insert(removed, path)
    return true
  end
  local AiClient = load_ai_client()
  local ok, err = pcall(AiClient.downloadBook, "abc123", target)
  io.open = original_io_open
  os.remove = original_os_remove
  H.is_false("downloadBook rejects local write failure", ok)
  H.contains("downloadBook write failure mentions local file", tostring(err), "writing local file")
  H.contains("downloadBook write failure preserves detail", tostring(err), "disk full")
  H.eq("downloadBook removes partial file after write failure", removed[1], target)
end

-- downloadBook also treats close/flush failure as a failed local write.
do
  local target = "/tmp/caudex-close-fail.epub"
  local removed = {}
  local original_io_open = io.open
  local original_os_remove = os.remove
  http_lib = { TIMEOUT = 10, request = function(_) return nil, nil, nil end }
  https_lib = {
    TIMEOUT = 10,
    request = function(params)
      params.sink("epub bytes")
      return 1, 200, {}
    end,
  }
  io.open = function(path, mode)
    if path == target and mode == "wb" then
      return {
        write = function(self) return self end,
        close = function() return nil, "flush failed" end,
      }
    end
    return original_io_open(path, mode)
  end
  os.remove = function(path)
    table.insert(removed, path)
    return true
  end
  local AiClient = load_ai_client()
  local ok, err = pcall(AiClient.downloadBook, "abc123", target)
  io.open = original_io_open
  os.remove = original_os_remove
  H.is_false("downloadBook rejects local close failure", ok)
  H.contains("downloadBook close failure preserves detail", tostring(err), "flush failed")
  H.eq("downloadBook removes partial file after close failure", removed[1], target)
end

-- ── Section 5: input validation ───────────────────────────────────────────

do
  make_libs()
  local AiClient = load_ai_client()

  local ok1, err1 = pcall(AiClient.analyzeContent, { content = "" })
  H.is_false("analyzeContent rejects empty content", ok1)
  H.contains("analyzeContent empty content error", tostring(err1), "requires content")

  local ok2 = pcall(AiClient.analyzeContent, nil)
  H.is_false("analyzeContent rejects nil params", ok2)

  local ok3 = pcall(AiClient.summarizeContent, { content = "" })
  H.is_false("summarizeContent rejects empty content", ok3)

  local ok4 = pcall(AiClient.dictionaryLookup, { term = "" })
  H.is_false("dictionaryLookup rejects empty term", ok4)
end
