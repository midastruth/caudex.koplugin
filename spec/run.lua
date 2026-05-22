-- Test runner: luajit spec/run.lua
-- Run from the plugin root directory.

local base = (debug.getinfo(1, "S").source:match("@(.+)/spec/run%.lua$"))
          or "/home/midas/workspace/projects/caudex.koplugin"

-- Add plugin root to package.path so both "caudex.xxx" and "spec.xxx" resolve
package.path = base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path

print("caudex.koplugin – unit test suite")
print("base: " .. base)

-- Load helpers first (shared state for counts)
local H = require("spec.helpers")

-- Run each spec file in order
local specs = {
  "spec.test_util",
  "spec.test_config",
  "spec.test_highlight",
  "spec.test_errors",
  "spec.test_main",
  "spec.test_dialog_controller",
  "spec.test_workflow",
  "spec.test_background_jobs",
  "spec.test_ai_client",
  "spec.test_annotation_sync",
  "spec.test_auto_sync",
  "spec.test_markdown_renderer",
  "spec.test_caudexviewer",
}

for _, spec in ipairs(specs) do
  local ok, err = pcall(require, spec)
  if not ok then
    print("\n[ERROR loading " .. spec .. "]\n  " .. tostring(err))
    H.failed = H.failed + 1
    table.insert(H._failures, "load error: " .. spec)
  end
end

local all_passed = H.summary()
os.exit(all_passed and 0 or 1)
