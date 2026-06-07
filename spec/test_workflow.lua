local H = require("spec.helpers")

H.section("F. caudex/workflow.lua")

local spy = H.mock_koreader()

-- ── Mock all workflow dependencies ────────────────────────────────────────

H.reset("caudex.workflow", "caudex.background_jobs", "caudex.ai_client",
        "caudexviewer", "caudex.formatter", "caudex.errors",
        "caudex.util", "caudex.highlight")

local bj_calls = {}
package.loaded["caudex.background_jobs"] = {
  submit_summary    = function(...) table.insert(bj_calls, { kind="summary", n = select("#",...) }) end,
  submit_analyze    = function(...) table.insert(bj_calls, { kind="analyze", n = select("#",...) }) end,
  show_results_menu = function() end,
}

local ai_calls = {}
package.loaded["caudex.ai_client"] = {
  dictionaryLookup = function(params)
    table.insert(ai_calls, params)
    return { term = params.term, definition = "mock definition" }
  end,
  MAX_RETRY_ATTEMPTS = 3,
}

package.loaded["caudexviewer"] = {
  new = function(_, args)
    return { _type = "CaudexViewer", update = function() end }
  end,
}

local formatter_calls = {}
package.loaded["caudex.formatter"] = {
  dictionary = function(args)
    table.insert(formatter_calls, args)
    return "dict:" .. (args.term or "?")
  end,
  summary    = function(args) return "sum" end,
  analysis   = function(args) return "ana" end,
}

package.loaded["caudex.errors"] = {
  show              = function() end,
  show_request_error = function() end,
}

-- Make scheduleIn execute its callback synchronously so lookup is testable
spy.UIManager.scheduleIn = function(_, delay, fn)
  if fn then fn() end
end

local Workflow = require("caudex.workflow")

-- Shared fake UI
local fake_ui = {
  getCurrentPage = function() return 12 end,
  document = {
    file = "/tmp/test-book.epub",
    getProps = function() return { title = "Test Book", authors = "Test Author" } end,
    getPageCount = function() return 100 end,
  },
  doc_settings = {
    readSetting = function(_, key)
      if key == "file_sha256" then return "abc123" end
      if key == "file_sha256_path" then return "/tmp/test-book.epub" end
      return nil
    end,
    saveSetting = function() end,
  },
  toc = {
    getTocTitleOfCurrentPage = function() return "Chapter 1" end,
  },
  highlight = {
    addNote  = function() end,
    onClose  = function() end,
    addToHighlightDialog = function() end,
  },
  menu = { registerToMainMenu = function() end },
}

-- ── summarize → BackgroundJobs.submit_summary ─────────────────────────────

bj_calls = {}
H.no_error("summarize() runs without error", function()
  Workflow.summarize(fake_ui, { content = "some text" }, "some text")
end)
H.eq("summarize() delegates to BackgroundJobs", #bj_calls, 1)
H.eq("summarize() kind is 'summary'", bj_calls[1] and bj_calls[1].kind, "summary")

-- ── analyze → BackgroundJobs.submit_analyze ───────────────────────────────

bj_calls = {}
H.no_error("analyze() runs without error", function()
  Workflow.analyze(fake_ui, { content = "some text" }, "some text")
end)
H.eq("analyze() delegates to BackgroundJobs", #bj_calls, 1)
H.eq("analyze() kind is 'analyze'", bj_calls[1] and bj_calls[1].kind, "analyze")

-- ── lookup → synchronous, does NOT touch BackgroundJobs ──────────────────

bj_calls = {}
ai_calls = {}
formatter_calls = {}
spy.shown = {}

H.no_error("lookup() runs without error", function()
  Workflow.lookup(fake_ui, {
    term             = "serendipity",
    highlighted_text = "serendipity",
  }, "serendipity")
end)

H.eq("lookup() does NOT call BackgroundJobs", #bj_calls, 0)
H.eq("lookup() calls AiClient.dictionaryLookup", #ai_calls, 1)
H.eq("lookup() passes unified read action to AiClient", ai_calls[1] and ai_calls[1].action, "ask")
H.eq("lookup() passes question to AiClient", ai_calls[1] and ai_calls[1].question, "")
H.eq("lookup() passes book.sha256 to AiClient", ai_calls[1] and ai_calls[1].book and ai_calls[1].book.sha256, "abc123")
H.eq("lookup() passes book.title to AiClient", ai_calls[1] and ai_calls[1].book and ai_calls[1].book.title, "Test Book")
H.eq("lookup() passes location.chapter to AiClient", ai_calls[1] and ai_calls[1].location and ai_calls[1].location.chapter, "Chapter 1")
H.eq("lookup() passes location.progress to AiClient", ai_calls[1] and ai_calls[1].location and ai_calls[1].location.progress, 0.12)
H.eq("lookup() passes file_sha256 to formatter", formatter_calls[1] and formatter_calls[1].file_sha256, "abc123")

-- Viewer should have been shown
local viewer_shown = false
for _, w in ipairs(spy.shown) do
  if w._type == "CaudexViewer" then viewer_shown = true end
end
H.is_true("lookup() shows CaudexViewer", viewer_shown)

-- ── ask() → SSE 流式 ──────────────────────────────────────────────────────

-- Stub AiClient.streamAsk / streamResearch and ffi/util for ask()/research() tests
local stream_ask_calls = {}
package.loaded["caudex.ai_client"].streamAsk = function(params, tmpfile)
  table.insert(stream_ask_calls, { params = params, tmpfile = tmpfile })
end
local stream_research_calls = {}
package.loaded["caudex.ai_client"].streamResearch = function(params, tmpfile)
  table.insert(stream_research_calls, { params = params, tmpfile = tmpfile })
end
package.loaded["caudex.formatter"].ask = function(args)
  return "ask:" .. (args.question or "?")
end
package.loaded["caudex.errors"].show = function(msg)
  stream_ask_calls._last_error = msg
end

local fork_should_fail = false
local fork_calls = {}
package.loaded["ffi/util"] = {
  runInSubProcess = function(fn, with_pipe)
    table.insert(fork_calls, { with_pipe = with_pipe })
    if fork_should_fail then return nil end
    return 999  -- fake pid
  end,
  isSubProcessDone = function(pid) return true end,
}
package.loaded["json"] = {
  encode = function(t) return "{}" end,
  decode = function(s)
    if s == "{}" then return {} end
    return nil
  end,
}

-- Reset workflow to pick up new stubs
H.reset("caudex.workflow")
local Workflow2 = require("caudex.workflow")

-- ask() with empty text should show error and NOT fork
fork_calls = {}
stream_ask_calls._last_error = nil
H.no_error("ask() with empty text does not crash", function()
  Workflow2.ask(fake_ui, { term = "", highlighted_text = "" }, "")
end)
H.eq("ask() empty text: no fork",  #fork_calls, 0)
H.is_true("ask() empty text: error shown",
          stream_ask_calls._last_error ~= nil)

-- ask() fork failure
fork_should_fail = true
fork_calls = {}
spy.shown = {}
stream_ask_calls._last_error = nil
H.no_error("ask() fork failure does not crash", function()
  Workflow2.ask(fake_ui, { term = "hello", question = "what?" }, "hello")
end)
H.eq("ask() fork failure: one fork attempted", #fork_calls, 1)
H.is_true("ask() fork failure: error shown",
          stream_ask_calls._last_error ~= nil)

-- ask() successful fork: opens viewer immediately
fork_should_fail = false
fork_calls = {}
spy.shown = {}
H.no_error("ask() successful fork runs without error", function()
  Workflow2.ask(fake_ui, { term = "hello", question = "what?" }, "hello")
end)
H.eq("ask() successful fork: forked once", #fork_calls, 1)
local ask_viewer_shown = false
for _, w in ipairs(spy.shown) do
  if w._type == "CaudexViewer" then ask_viewer_shown = true end
end
H.is_true("ask() successful fork: CaudexViewer shown immediately", ask_viewer_shown)

-- ── research() → /ai/research/stream 深度研究流 ───────────────────────────

-- research() with empty text should show error and NOT fork
fork_should_fail = false
fork_calls = {}
stream_ask_calls._last_error = nil
H.no_error("research() with empty text does not crash", function()
  Workflow2.research(fake_ui, { term = "", highlighted_text = "" }, "")
end)
H.eq("research() empty text: no fork", #fork_calls, 0)
H.is_true("research() empty text: error shown",
          stream_ask_calls._last_error ~= nil)

-- research() successful fork: opens viewer immediately
fork_should_fail = false
fork_calls = {}
spy.shown = {}
H.no_error("research() successful fork runs without error", function()
  Workflow2.research(fake_ui, {
    term     = "hello",
    question = "focus?",
    action   = "analyze",
  }, "hello")
end)
H.eq("research() successful fork: forked once", #fork_calls, 1)
local research_viewer_shown = false
for _, w in ipairs(spy.shown) do
  if w._type == "CaudexViewer" then research_viewer_shown = true end
end
H.is_true("research() successful fork: CaudexViewer shown immediately", research_viewer_shown)
