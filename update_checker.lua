-- GitHub release checker + optional one-click updater for Caudex.
--
-- Safety notes:
--   * We never install silently.  The user must confirm from the UI.
--   * configuration.lua is preserved when files are copied over.
--   * KOReader should be restarted after installation because Lua modules are
--     cached by require().

local https       = require("ssl.https")
local ltn12       = require("ltn12")
local json        = require("json")
local meta        = require("_meta")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox  = require("ui/widget/confirmbox")
local UIManager   = require("ui/uimanager")
local _           = require("gettext")

local RELEASES_URL = "https://api.github.com/repos/midastruth/caudex.koplugin/releases/latest"
local TIMEOUT      = 10  -- seconds
local MAX_REDIRECTS = 5

local UpdateChecker = {}

-- ── Small utilities ───────────────────────────────────────────────────────

local function show_message(text, timeout)
  UIManager:show(InfoMessage:new {
    text    = text,
    timeout = timeout or 5,
  })
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function command_ok(result, how, code)
  -- Lua 5.1 returns the raw wait status number directly (exit 12 => 3072).
  -- Lua 5.2+ returns true/nil plus an exit reason and status code.
  if result == true or result == 0 then return true end

  if type(result) == "number" then
    local exit_code = result
    if result > 255 then exit_code = math.floor(result / 256) end
    if exit_code == 0 then return true end
    return false, "exit " .. tostring(exit_code) .. " (status " .. tostring(result) .. ")"
  end

  if result == nil and code ~= nil then
    return false, tostring(how or "exit") .. " " .. tostring(code)
  end

  return false, tostring(result) .. " " .. tostring(how) .. " " .. tostring(code)
end

local function run_command(command)
  return command_ok(os.execute(command))
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function read_command_first_line(command)
  local p = io.popen(command)
  if not p then return nil end
  local line = p:read("*l")
  p:close()
  return line
end

local function plugin_dir()
  local source = debug.getinfo(1, "S").source or ""
  source = source:gsub("^@", "")
  local dir = source:match("^(.*)/update_checker%.lua$")
  return dir or "."
end

local function tmp_path(name)
  return "/tmp/" .. name
end

local function timestamp()
  return os.date("%Y%m%d%H%M%S")
end

-- ── Version comparison ────────────────────────────────────────────────────

local function version_parts(value)
  value = tostring(value or "0"):gsub("^v", "")
  local parts = {}
  for part in value:gmatch("%d+") do
    parts[#parts + 1] = tonumber(part) or 0
  end
  if #parts == 0 then parts[1] = 0 end
  return parts
end

local function version_gt(a, b)
  local ap, bp = version_parts(a), version_parts(b)
  local n = math.max(#ap, #bp)
  for i = 1, n do
    local av, bv = ap[i] or 0, bp[i] or 0
    if av > bv then return true end
    if av < bv then return false end
  end
  return false
end

-- ── HTTPS helpers with redirect handling ──────────────────────────────────

local function request_url(url, extra_headers)
  local current_url = url
  local last_code, last_status = nil, nil

  for _ = 1, MAX_REDIRECTS + 1 do
    local chunks = {}
    local prev_timeout = https.TIMEOUT
    https.TIMEOUT = TIMEOUT

    local headers = {
      ["Accept"]     = "application/vnd.github+json",
      ["User-Agent"] = "caudex-koplugin-updater",
    }
    if type(extra_headers) == "table" then
      for k, v in pairs(extra_headers) do headers[k] = v end
    end

    local ok, _, code, response_headers, status = pcall(function()
      return https.request {
        url     = current_url,
        method  = "GET",
        headers = headers,
        sink    = ltn12.sink.table(chunks),
      }
    end)

    https.TIMEOUT = prev_timeout

    if not ok then
      return nil, nil, "request failed: " .. tostring(_)
    end

    last_code = tonumber(code)
    last_status = status

    if last_code and last_code >= 300 and last_code < 400
        and type(response_headers) == "table" then
      local location = response_headers.location or response_headers.Location
      if location and location ~= "" then
        current_url = location
        -- Some redirects return relative locations. GitHub normally does not,
        -- but support the common absolute-path form anyway.
        if current_url:sub(1, 1) == "/" then
          local scheme_host = url:match("^(https://[^/]+)")
          if scheme_host then current_url = scheme_host .. current_url end
        end
      else
        break
      end
    else
      return table.concat(chunks), last_code, last_status
    end
  end

  return nil, last_code, "too many redirects or redirect without Location: " .. tostring(last_status)
end

local function fetch_latest_release()
  local body, code, err = request_url(RELEASES_URL)
  if code ~= 200 or not body then
    return nil, "GitHub releases request failed: " .. tostring(code or err)
  end

  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= "table" or not data.tag_name then
    return nil, "GitHub releases response was not valid JSON."
  end
  return data
end

local function choose_download_url(release)
  local best_zip, fallback_zip
  if type(release.assets) == "table" then
    for _, asset in ipairs(release.assets) do
      if type(asset) == "table" and type(asset.browser_download_url) == "string" then
        local name = tostring(asset.name or "")
        local lower = name:lower()
        if lower:match("%.zip$") then
          fallback_zip = fallback_zip or asset.browser_download_url
          if lower:match("caudex%.koplugin") then
            best_zip = asset.browser_download_url
            break
          end
        end
      end
    end
  end
  return best_zip or fallback_zip or release.zipball_url
end

local function get_update_info()
  local release, err = fetch_latest_release()
  if not release then return nil, err end

  local latest = tostring(release.tag_name or ""):gsub("^v", "")
  local current = tostring(meta.version or "0")
  local available = version_gt(latest, current)

  return {
    available    = available,
    current      = current,
    latest       = latest,
    tag_name     = release.tag_name,
    release      = release,
    html_url     = release.html_url,
    download_url = choose_download_url(release),
  }
end

-- ── Installer ─────────────────────────────────────────────────────────────

local function download_zip(url)
  if not url or url == "" then
    return nil, "No downloadable zip asset was found in the latest release."
  end

  local path = tmp_path("caudex-update-" .. timestamp() .. ".zip")

  -- Prefer curl/wget: they handle CDN redirects and binary downloads
  -- reliably without Content-Type negotiation issues (HTTP 415).
  local curl_bin = read_command_first_line("command -v curl 2>/dev/null")
  local wget_bin = read_command_first_line("command -v wget 2>/dev/null")

  if curl_bin and curl_bin ~= "" then
    local ok = run_command(
      "curl -fsSL --max-time 120 -o " .. shell_quote(path) .. " " .. shell_quote(url)
    )
    if ok and file_exists(path) then return path end
  elseif wget_bin and wget_bin ~= "" then
    local ok = run_command(
      "wget -q --timeout=120 -O " .. shell_quote(path) .. " " .. shell_quote(url)
    )
    if ok and file_exists(path) then return path end
  end

  -- Fallback: download via ssl.https (buffers entire zip in RAM).
  local body, code, err = request_url(url, { ["Accept"] = "*/*" })
  if code ~= 200 or not body then
    return nil, "Download failed: " .. tostring(code or err)
  end

  local f = io.open(path, "wb")
  if not f then return nil, "Cannot write update zip: " .. path end
  f:write(body)
  f:close()
  return path
end

local function find_plugin_payload(staging_dir)
  -- Accept either:
  --   staging/caudex.koplugin/_meta.lua
  --   staging/<github-zipball-root>/_meta.lua
  --   staging/_meta.lua
  if file_exists(staging_dir .. "/_meta.lua") and file_exists(staging_dir .. "/main.lua") then
    return staging_dir
  end

  local preferred = staging_dir .. "/caudex.koplugin"
  if file_exists(preferred .. "/_meta.lua") and file_exists(preferred .. "/main.lua") then
    return preferred
  end

  local meta_path = read_command_first_line(
    "find " .. shell_quote(staging_dir) .. " -maxdepth 3 -type f -name _meta.lua 2>/dev/null"
  )
  if meta_path then
    local dir = meta_path:gsub("/_meta%.lua$", "")
    if file_exists(dir .. "/main.lua") then return dir end
  end
  return nil
end

local function install_zip(zip_path)
  local dst = plugin_dir()
  local staging = tmp_path("caudex-update-staging-" .. timestamp())

  local ok, err = run_command("command -v unzip >/dev/null 2>&1")
  if not ok then
    return false, "The system 'unzip' command was not found. Please update manually."
  end

  ok, err = run_command("rm -rf " .. shell_quote(staging) .. " && mkdir -p " .. shell_quote(staging))
  if not ok then return false, "Cannot create staging directory: " .. tostring(err) end

  ok, err = run_command("unzip -oq " .. shell_quote(zip_path) .. " -d " .. shell_quote(staging))
  if not ok then return false, "Cannot unzip update package: " .. tostring(err) end

  local src = find_plugin_payload(staging)
  if not src then
    return false, "The update package does not look like caudex.koplugin."
  end

  local config_backup = tmp_path("caudex-configuration-" .. timestamp() .. ".lua")
  local script = tmp_path("caudex-install-" .. timestamp() .. ".sh")
  -- Keep backup in /tmp instead of next to the plugin. Some devices allow
  -- writing inside the plugin dir but not creating siblings in its parent.
  local backup_dir = tmp_path("caudex-backup-" .. timestamp())

  local script_body = table.concat({
    "#!/bin/sh",
    "set -u",
    "SRC=" .. shell_quote(src),
    "DST=" .. shell_quote(dst),
    "CONFIG_BACKUP=" .. shell_quote(config_backup),
    "BACKUP_DIR=" .. shell_quote(backup_dir),
    "[ -f \"$SRC/_meta.lua\" ] || exit 10",
    "[ -f \"$SRC/main.lua\" ] || exit 11",
    "mkdir -p \"$BACKUP_DIR\" || true",
    "cp -a \"$DST\"/. \"$BACKUP_DIR\"/ 2>/dev/null || true",
    "if [ -f \"$DST/configuration.lua\" ]; then cp \"$DST/configuration.lua\" \"$CONFIG_BACKUP\" || exit 13; fi",
    "mkdir -p \"$DST\" || exit 16",
    "cp -a \"$SRC\"/. \"$DST\"/ || exit 14",
    "if [ -f \"$CONFIG_BACKUP\" ]; then cp \"$CONFIG_BACKUP\" \"$DST/configuration.lua\" || exit 15; fi",
    "rm -f \"$CONFIG_BACKUP\"",
    "exit 0",
    "",
  }, "\n")

  local f = io.open(script, "w")
  if not f then return false, "Cannot write installer script." end
  f:write(script_body)
  f:close()

  ok, err = run_command("sh " .. shell_quote(script))
  run_command("rm -f " .. shell_quote(script))

  if not ok then
    return false, "Installer failed: " .. tostring(err) ..
      "\nA backup may be available at:\n" .. backup_dir
  end

  return true, backup_dir
end

local function install_update(info, skip_initial_message)
  if not skip_initial_message then
    show_message(_("Caudex 正在下载 ") .. tostring(info.tag_name or info.latest) .. "...", 2)
  end

  local zip_path, err = download_zip(info.download_url)
  if not zip_path then
    show_message(_("Caudex 更新失败：\n") .. tostring(err), 8)
    return false
  end

  show_message(_("Caudex 正在安装..."), 2)
  local ok, install_result = install_zip(zip_path)
  run_command("rm -f " .. shell_quote(zip_path))

  if not ok then
    show_message(_("Caudex 更新失败：\n") .. tostring(install_result), 10)
    return false
  end

  show_message(_("下载完成。请重启 KOReader 使更新生效。"), 10)
  return true
end

local function prompt_install(info)
  UIManager:show(ConfirmBox:new {
    text = _("发现 Caudex 新版本 ") .. tostring(info.tag_name or info.latest) .. "\n\n" ..
           _("当前版本：v") .. tostring(info.current):gsub("^v", "") .. "\n\n" ..
           _("是否下载并安装？") .. "\n\n" ..
           _("configuration.lua 会被保留。"),
    ok_text = _("更新"),
    cancel_text = _("取消"),
    ok_callback = function()
      -- Match KOReader's OTA flow: show feedback first, then do blocking
      -- download/install work on the next UI tick so the dialog can repaint.
      show_message(_("Caudex 正在下载 ") .. tostring(info.tag_name or info.latest) .. "...", 3)
      UIManager:scheduleIn(1, function()
        install_update(info, true)
      end)
    end,
  })
end

-- ── Public API ────────────────────────────────────────────────────────────

function UpdateChecker.checkForUpdates(opts)
  opts = opts or {}
  local info, err = get_update_info()
  if not info then
    if opts.interactive then show_message(_("Caudex 检查更新失败：\n") .. tostring(err), 6) end
    return false, err
  end

  if info.available then
    if opts.offer_install then
      prompt_install(info)
    else
      show_message(
        _("发现 Caudex 新版本 ") .. tostring(info.tag_name or info.latest) ..
        _("，可在 Caudex 更新菜单中安装。"),
        6
      )
    end
    return true, info
  end

  if opts.interactive then
    show_message(_("Caudex 已是最新版本。当前版本：v") .. tostring(info.current):gsub("^v", ""), 5)
  end
  return false, info
end

function UpdateChecker.checkAndPromptInstall()
  return UpdateChecker.checkForUpdates { interactive = true, offer_install = true }
end

-- Exposed for tests or advanced use.
UpdateChecker._get_update_info = get_update_info
UpdateChecker._version_gt = version_gt

return UpdateChecker
