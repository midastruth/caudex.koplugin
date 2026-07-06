local H = require("spec.helpers")

H.section("G. caudex/background_jobs.lua")

local spy = H.mock_koreader()

-- ── Mock BackgroundJobs dependencies ─────────────────────────────────────

H.reset("caudex.background_jobs", "caudex.ai_client", "caudex.formatter", "caudex.errors")

package.loaded["caudex.ai_client"] = {
  summarizeContent = function() return { summary = "ok" } end,
  analyzeContent   = function() return {} end,
  researchContent  = function() return { answer = { text = "deep answer" } } end,
}
package.loaded["caudex.formatter"] = {
  summary  = function() return "formatted summary" end,
  analysis = function() return "formatted analysis" end,
  ask      = function() return "formatted research" end,
}

local errors_shown = {}
package.loaded["caudex.errors"] = {
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

local BJ = require("caudex.background_jobs")

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

-- ── Scenario 2b: fork failure in submit_research ─────────────────────────

errors_shown = {}
H.no_error("submit_research with fork failure does not crash", function()
  BJ.submit_research(fake_ui, { term = "deep topic" }, "deep topic",
                     "Book Title", "Author")
end)
H.is_true("fork failure submit_research: Errors.show was called", #errors_shown > 0)

-- ── Scenario 2c: submit_research with empty text shows error ──────────────

errors_shown = {}
H.no_error("submit_research with empty text does not crash", function()
  BJ.submit_research(fake_ui, { term = "" }, "", "T", "A")
end)
H.is_true("research empty text: error shown", #errors_shown > 0)

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

H.reset("caudex.background_jobs")
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

local BJ2 = require("caudex.background_jobs")

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

-- ── Scenario 6: completed research job opens viewer with working callbacks ─

-- research subprocess returns a done result -> viewer should support 追问/存笔记
spy.ffiutil.readAllFromFD = function(_fd)
  return '{"status":"done","text":"deep research result"}'
end
package.loaded["json"].decode = function(_raw)
  return { status = "done", text = "deep research result" }
end

local note_saved = nil
local research_ui = {
  document = { getProps = function() return { title = "Book", authors = "Author" } end },
  highlight = {
    selected_text = { text = "topic", pos0 = { page = 1 }, pos1 = { page = 1 } },
    addNote = function(_self, text) note_saved = text end,
    onClose = function() end,
  },
}

-- Capture the viewer that open_result_viewer builds for research jobs.
local captured_research_viewer = nil
package.loaded["caudexviewer"] = {
  new = function(_, args)
    captured_research_viewer = {
      _type = "CaudexViewer",
      onAskQuestion = args.onAskQuestion,
      onAddToNote   = args.onAddToNote,
      update = function(self, t) self.text = t end,
    }
    return captured_research_viewer
  end,
}

H.reset("caudex.background_jobs")
local BJ3 = require("caudex.background_jobs")

spy.shown = {}
H.no_error("submit_research success does not crash", function()
  BJ3.submit_research(research_ui, { term = "deep topic", question = "why?" },
                      "deep topic", "Book", "Author")
end)

-- open the most recent research result from the menu
spy.shown = {}
H.no_error("show_results_menu with research job does not crash", function()
  BJ3.show_results_menu(research_ui)
end)
H.is_true("research results menu shows ButtonDialog",
          spy.shown[1] and spy.shown[1]._type == "ButtonDialog")

-- click the research result button to open the viewer
local research_btn = spy.shown[1] and spy.shown[1].buttons[1][1]
H.is_true("research result button exists", research_btn ~= nil)
H.no_error("opening research result viewer does not crash", function()
  research_btn.callback()
end)
H.is_true("research viewer was created", captured_research_viewer ~= nil)
H.is_true("research viewer supports follow-up",
          type(captured_research_viewer.onAskQuestion) == "function")
H.is_true("research viewer supports add-to-note",
          type(captured_research_viewer.onAddToNote) == "function")

-- exercising add-to-note should call highlight:addNote
H.no_error("research add-to-note does not crash", function()
  captured_research_viewer:onAddToNote()
end)
H.eq("research add-to-note saved the result text", note_saved, "deep research result")

-- ── Scenario 7: closing pending follow-up viewer keeps it dismissed ────────

local function install_followup_viewer_spy(created)
  package.loaded["caudexviewer"] = {
    new = function(_, args)
      local obj = {
        _type          = "CaudexViewer",
        text           = args.text,
        show_add_note  = args.show_add_note,
        onAskQuestion  = args.onAskQuestion,
        onAddToNote    = args.onAddToNote,
        onHideChat     = args.onHideChat,
        close_callback = args.close_callback,
        update = function(self, t) self.text = t end,
      }
      obj.onClose = function(self)
        self._closed = true
        if self.close_callback then self.close_callback() end
      end
      table.insert(created, obj)
      return obj
    end,
  }
end

local function count_shown_caudex_viewers()
  local n = 0
  for _, w in ipairs(spy.shown) do
    if w._type == "CaudexViewer" then n = n + 1 end
  end
  return n
end

local function open_first_research_viewer(BJ, ui)
  spy.shown = {}
  BJ.show_results_menu(ui)
  local btn = spy.shown[1] and spy.shown[1].buttons[1][1]
  if btn then btn.callback() end
end

local followup_raw = '{"status":"done","text":"initial research result"}'
spy.ffiutil.readAllFromFD = function(_fd) return followup_raw end
package.loaded["json"].decode = function(raw)
  if raw and raw:find("follow%-up", 1, false) then
    return { status = "done", text = "follow-up result" }
  end
  return { status = "done", text = "initial research result" }
end

local pending_schedules = {}
local defer_schedules = false
spy.UIManager.scheduleIn = function(_, delay, fn)
  if defer_schedules then
    table.insert(pending_schedules, { delay = delay, fn = fn })
  elseif fn then
    fn()
  end
end

local dismissed_viewers = {}
install_followup_viewer_spy(dismissed_viewers)
H.reset("caudex.background_jobs")
local BJ4 = require("caudex.background_jobs")
BJ4.submit_research(research_ui, { term = "deep topic" }, "deep topic", "Book", "Author")
open_first_research_viewer(BJ4, research_ui)
local initial_viewer = dismissed_viewers[1]
H.is_true("follow-up dismissal setup opened initial viewer", initial_viewer ~= nil)

spy.shown = {}
pending_schedules = {}
defer_schedules = true
followup_raw = '{"status":"done","text":"follow-up result"}'
H.no_error("starting follow-up creates pending viewer", function()
  initial_viewer:onAskQuestion("more?")
end)
local pending_viewer = dismissed_viewers[2]
H.is_true("follow-up pending viewer was created", pending_viewer ~= nil)
H.eq("pending follow-up viewer is shown once", count_shown_caudex_viewers(), 1)

pending_viewer:onClose()
H.no_error("follow-up completion after normal close does not crash", function()
  pending_schedules[1].fn()
end)
H.eq("normal close: follow-up completion does not recreate viewer", #dismissed_viewers, 2)
H.eq("normal close: follow-up completion does not show viewer", count_shown_caudex_viewers(), 1)

defer_schedules = false

-- ── Scenario 8: Hide chat still reopens when follow-up completes ───────────

local hidden_viewers = {}
install_followup_viewer_spy(hidden_viewers)
H.reset("caudex.background_jobs")
local BJ5 = require("caudex.background_jobs")
followup_raw = '{"status":"done","text":"initial research result"}'
BJ5.submit_research(research_ui, { term = "deep topic" }, "deep topic", "Book", "Author")
open_first_research_viewer(BJ5, research_ui)
initial_viewer = hidden_viewers[1]
H.is_true("hide chat setup opened initial viewer", initial_viewer ~= nil)

spy.shown = {}
pending_schedules = {}
defer_schedules = true
followup_raw = '{"status":"done","text":"follow-up result"}'
initial_viewer:onAskQuestion("more?")
pending_viewer = hidden_viewers[2]
H.is_true("hide chat pending viewer was created", pending_viewer ~= nil)
H.no_error("hide chat callback does not crash", function()
  pending_viewer:onHideChat()
end)
pending_schedules[1].fn()
H.eq("hide chat: follow-up completion recreates final viewer", #hidden_viewers, 3)
H.eq("hide chat: follow-up completion shows final viewer", count_shown_caudex_viewers(), 2)

defer_schedules = false
spy.UIManager.scheduleIn = function(_, delay, fn)
  if fn then fn() end
end

-- Restore default CaudexViewer mock for any later specs.
package.loaded["caudexviewer"] = nil

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
