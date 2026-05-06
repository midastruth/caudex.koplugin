local H = require("spec.helpers")

H.section("G. askgpt/background_jobs.lua")

local spy = H.mock_koreader()

-- ── Mock BackgroundJobs dependencies ─────────────────────────────────────

H.reset("askgpt.background_jobs", "askgpt.ai_client", "askgpt.formatter", "askgpt.errors")

package.loaded["askgpt.ai_client"] = {
  summarizeContent = function() return { summary = "ok" } end,
  analyzeContent   = function() return {} end,
}
package.loaded["askgpt.formatter"] = {
  summary  = function() return "formatted summary" end,
  analysis = function() return "formatted analysis" end,
}

local errors_shown = {}
package.loaded["askgpt.errors"] = {
  show              = function(msg) table.insert(errors_shown, msg) end,
  show_request_error = function(msg) table.insert(errors_shown, msg) end,
}

local fake_ui = {
  document = {
    getProps = function() return { title = "Book", authors = "Author" } end,
  },
}

-- ── Scenario 1: fork failure in submit_summary ────────────────────────────

spy.ffiutil._fork_fails = true

local BJ = require("askgpt.background_jobs")

errors_shown = {}
spy.shown    = {}

H.no_error("submit_summary with fork failure does not crash", function()
  BJ.submit_summary(fake_ui, { content = "text content" }, "text content",
                    "Book Title", "Author")
end)

H.is_true("fork failure: Errors.show was called", #errors_shown > 0)
H.contains("fork failure: error message mentions 资源",
           errors_shown[1] or "", "资源")

-- ── Scenario 2: fork failure in submit_analyze ───────────────────────────

errors_shown = {}
H.no_error("submit_analyze with fork failure does not crash", function()
  BJ.submit_analyze(fake_ui, { content = "text content" }, "text content",
                    "Book Title", "Author")
end)
H.is_true("fork failure submit_analyze: Errors.show was called", #errors_shown > 0)

-- ── Scenario 3: show_results_menu with no completed jobs ─────────────────
-- After two fork-failures both jobs have status="failed", not "done".
-- show_results_menu should show the "no results" InfoMessage.

spy.shown = {}
H.no_error("show_results_menu runs without error", function()
  BJ.show_results_menu(fake_ui)
end)

-- Find the InfoMessage text shown
local info_text = nil
for _, w in ipairs(spy.shown) do
  if w._type == "InfoMessage" and type(w.text) == "string" then
    info_text = w.text
    break
  end
end
H.contains("show_results_menu with no done jobs shows 暂无已完成",
           info_text or "", "暂无已完成")

-- ── Scenario 4: submit_summary with empty content shows error ────────────

errors_shown = {}
H.no_error("submit_summary with empty content does not crash", function()
  BJ.submit_summary(fake_ui, { content = "" }, "", "T", "A")
end)
H.is_true("empty content: error shown", #errors_shown > 0)

-- ── Scenario 5: show_results_menu with done jobs is robust ───────────────

H.reset("askgpt.background_jobs")
spy.ffiutil._fork_fails = false

-- Override scheduleIn to fire immediately (simulate instant subprocess done)
spy.UIManager.scheduleIn = function(_, delay, fn)
  if fn then fn() end
end
spy.ffiutil.readAllFromFD = function(_fd)
  return '{"status":"done","text":"done result"}'
end
package.loaded["json"].decode = function(_raw)
  return { status = "done", text = "done result" }
end

local BJ2 = require("askgpt.background_jobs")

-- Regression: a non-string highlighted_text used to make Recent results crash
-- while building snippets.
spy.shown = {}
BJ2.submit_summary(fake_ui, { content = "hello", highlighted_text = { text = "hello" } },
                   "hello", "T", "A")
spy.shown = {}
H.no_error("show_results_menu with table highlighted_text does not crash", function()
  BJ2.show_results_menu(fake_ui)
end)
H.is_true("show_results_menu with done job shows ButtonDialog",
          spy.shown[1] and spy.shown[1]._type == "ButtonDialog")
H.contains("done job button uses extracted snippet",
           spy.shown[1] and spy.shown[1].buttons[1][1].text or "", "hello")

-- Regression: missing created_at in a done job could crash table.sort.
local old_time = os.time
os.time = function() return nil end
BJ2.submit_summary(fake_ui, { content = "first" }, "first", "T", "A")
os.time = function() return 123 end
BJ2.submit_summary(fake_ui, { content = "second" }, "second", "T", "A")
os.time = old_time
spy.shown = {}
H.no_error("show_results_menu with missing created_at does not crash", function()
  BJ2.show_results_menu(fake_ui)
end)
H.is_true("show_results_menu after created_at regression shows ButtonDialog",
          spy.shown[1] and spy.shown[1]._type == "ButtonDialog")
