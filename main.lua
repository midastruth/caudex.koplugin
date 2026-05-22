local Device       = require("device")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr   = require("ui/network/manager")
local InfoMessage  = require("ui/widget/infomessage")
local ConfirmBox   = require("ui/widget/confirmbox")
local UIManager    = require("ui/uimanager")
local _ = require("gettext")

local Config           = require("caudex.config")
local DialogController = require("caudex.dialog_controller")
local BackgroundJobs   = require("caudex.background_jobs")
local BookUpload       = require("caudex.book_upload")
local BookSync         = require("caudex.book_sync")
local UpdateChecker    = require("update_checker")
local AnnotationSync   = require("caudex.annotation_sync")

local Caudex = InputContainer:new {
  name        = "caudex",
  is_doc_only = false,
}

local updateMessageShown = false

local function isFileManagerUI(ui)
  return ui and type(ui.addFileDialogButtons) == "function"
end

local function autoUploadEnabled()
  local cfg = Config.get()
  return type(cfg) == "table"
      and (cfg.reader_ai_auto_upload_book == true
           or cfg.book_aware_auto_upload == true)
end

local function autoSyncEnabled()
  local cfg = Config.get()
  return type(cfg) == "table"
      and (cfg.reader_ai_auto_sync_books == true
           or cfg.book_aware_auto_sync == true)
end

local function autoSyncWebHighlightsEnabled()
  local cfg = Config.get()
  return type(cfg) == "table" and cfg.auto_sync_web_highlights == true
end

local function autoUploadNewHighlightsEnabled()
  local cfg = Config.get()
  return type(cfg) == "table"
      and (cfg.auto_upload_new_highlights == true
           or cfg.auto_sync_web_highlights == true)
end

local function isNewLocalHighlightEvent(items)
  if type(items) ~= "table" or tonumber(items.nb_highlights_added or 0) <= 0 then
    return false
  end
  local item = items[1]
  if type(item) ~= "table" then return false end
  -- Highlights pulled from Book-Aware already carry a backend id; do not
  -- re-trigger an upload for annotations we just created during a web sync.
  if type(item.bookaware_highlight_id) == "string" and item.bookaware_highlight_id ~= "" then
    return false
  end
  return type(item.text) == "string" and item.text ~= ""
end

local function isLocalDeletedBookAwareHighlightEvent(items)
  if type(items) ~= "table" then return false end
  -- Deletions caused by applying web-side tombstones are already represented
  -- on the backend; do not echo them back as KOReader-originated deletes.
  if items.bookaware_origin == "tombstone_apply" then
    return false
  end
  -- KOReader's ReaderBookmark:removeItemByIndex signals an actual annotation
  -- removal via `index_modified < 0`, regardless of whether the removed item
  -- was a plain highlight (nb_highlights_added = -1) or a highlight+note
  -- (nb_notes_added = -1, with nb_highlights_added absent). Detecting on
  -- nb_highlights_added alone misses the note case, which previously caused
  -- backend-side highlights with notes to survive local deletion and get
  -- reinstated by the next reinstate_missing pass.
  local idx_mod = tonumber(items.index_modified)
  local hl_delta = tonumber(items.nb_highlights_added or 0) or 0
  local note_delta = tonumber(items.nb_notes_added or 0) or 0
  local is_removal = (idx_mod ~= nil and idx_mod < 0)
      or (hl_delta < 0)
      or (note_delta < 0 and hl_delta <= 0)
  if not is_removal then return false end
  local item = items[1]
  return type(item) == "table"
      and type(item.bookaware_highlight_id) == "string"
      and item.bookaware_highlight_id ~= ""
end

local function placeCaudexBeforeToc()
  local ok, order = pcall(require, "ui/elements/reader_menu_order")
  if not ok or type(order) ~= "table" or type(order.navi) ~= "table" then
    return false
  end

  for i = #order.navi, 1, -1 do
    if order.navi[i] == "caudex" then
      table.remove(order.navi, i)
    end
  end

  local insert_at = 1
  for i, item_id in ipairs(order.navi) do
    if item_id == "table_of_contents" then
      insert_at = i
      break
    end
  end
  table.insert(order.navi, insert_at, "caudex")
  return true
end

local function checkNetworkAndConfig()
  local config_valid, config_result = Config.validate()
  if not config_valid then
    UIManager:show(InfoMessage:new {
      text    = _("Caudex插件配置错误：") .. config_result .. _("\n请检查configuration.lua文件。"),
      timeout = 5,
    })
    return false
  end
  if not NetworkMgr:isOnline() then
    UIManager:show(InfoMessage:new {
      text    = _("网络未连接，请检查网络设置后重试。"),
      timeout = 3,
    })
    return false
  end
  return true
end

function Caudex:init()
  self.ui.menu:registerToMainMenu(self)

  -- 文件管理器：长按书籍文件弹出"上传到 Book-Aware"按钮
  -- 注意：FileManager 加载插件时 file_chooser 可能尚未创建，不能用
  -- self.ui.file_chooser 判断；addFileDialogButtons 方法才是稳定特征。
  if isFileManagerUI(self.ui) then
    self.ui:addFileDialogButtons("caudex_upload_file", function(file, is_file)
      if not is_file then return end
      local ext = tostring(file or ""):lower():match("%.([^.]+)$")
      if ext ~= "epub" then return end
      return {
        {
          text = _("Upload to Book-Aware"),
          callback = function()
            if not checkNetworkAndConfig() then return end
            local NetworkMgr = require("ui/network/manager")
            NetworkMgr:runWhenOnline(function()
              BookUpload.upload_file(file)
            end)
          end,
        },
      }
    end)
    return
  end

  if not self.ui.highlight or type(self.ui.highlight.addToHighlightDialog) ~= "function" then
    return
  end

  self.ui.highlight:addToHighlightDialog("caudex_GPT", function(_reader_highlight_instance)
    return {
      text    = _("Caudex"),
      enabled = Device:hasClipboard(),
      callback = function()
        if not checkNetworkAndConfig() then return end
        NetworkMgr:runWhenOnline(function()
          if not updateMessageShown then
            UpdateChecker.checkForUpdates()
            updateMessageShown = true
          end
          local success, error_msg = pcall(function()
            DialogController.show(self.ui, _reader_highlight_instance)
          end)
          if not success then
            UIManager:show(InfoMessage:new {
              text    = _("Caudex运行失败：") .. tostring(error_msg),
              timeout = 5,
            })
          end
        end)
      end,
    }
  end)

  if autoUploadEnabled() then
    UIManager:scheduleIn(1, function()
      if not checkNetworkAndConfig() then return end
      NetworkMgr:runWhenOnline(function()
        BookUpload.upload_current(self.ui)
      end)
    end)
  end

  if autoSyncEnabled() then
    UIManager:scheduleIn(2, function()
      if not checkNetworkAndConfig() then return end
      NetworkMgr:runWhenOnline(function()
        BookSync.sync_all(self.ui)
      end)
    end)
  end

  if autoSyncWebHighlightsEnabled() then
    UIManager:scheduleIn(3, function()
      if self._auto_synced_sha then return end
      local cfg_ok = Config.validate()
      if not cfg_ok then return end
      NetworkMgr:runWhenOnline(function()
        if self._auto_synced_sha then return end
        self._auto_synced_sha = true
        local ok, err = pcall(AnnotationSync.sync, self.ui)
        if not ok then
          print("[book-aware] auto sync web highlights failed: " .. tostring(err))
        end
      end)
    end)
  end
end

-- Push local note/color changes during save/close (silent, best-effort).
local function pushWebHighlightChanges(self, reason)
  if not autoSyncWebHighlightsEnabled() then return end
  if isFileManagerUI(self.ui) then return end
  local cfg_ok = Config.validate()
  if not cfg_ok then return end
  if not NetworkMgr:isOnline() then return end
  local ok, err = pcall(AnnotationSync.push_changes_only, self.ui)
  if not ok then
    print("[book-aware] auto push on " .. tostring(reason) .. " failed: " .. tostring(err))
  end
end

function Caudex:onAnnotationsModified(items)
  if isFileManagerUI(self.ui) then return end

  if isLocalDeletedBookAwareHighlightEvent(items) then
    -- 关键：即便用户没开启自动同步，也要立刻把 tombstone 写入 sdr 的
    -- pending_deletes 队列，否则下一次手动 sync 会因后端 row 仍是 resolved
    -- 状态、本地缺失该 annotation，被 reinstate_missing() 复活，造成
    -- “删除→点同步→高亮回来”的故障。
    local deleted_item = items[1]
    local ok_q, q_result = pcall(AnnotationSync.queue_deleted_highlight, self.ui, deleted_item)
    if not ok_q then
      print("[book-aware] queue deleted highlight failed: " .. tostring(q_result))
      return
    end
    -- 立即向后端推送 DELETE 仅在自动同步开启时做；否则等用户下次手动
    -- sync 时 drain_pending_deletes 处理。
    if not autoSyncWebHighlightsEnabled() then return end
    UIManager:scheduleIn(1, function()
      if not autoSyncWebHighlightsEnabled() then return end
      local cfg_ok = Config.validate()
      if not cfg_ok then return end
      if not NetworkMgr:isOnline() then return end
      NetworkMgr:runWhenOnline(function()
        local ok, result = pcall(AnnotationSync.push_pending_deletes_only, self.ui)
        if not ok then
          print("[book-aware] auto delete highlight failed: " .. tostring(result))
        elseif type(result) == "table" and (result.failed or 0) > 0 then
          print("[book-aware] auto delete highlight partial failure: " .. tostring(result.failed))
        end
      end)
    end)
    return
  end

  if not autoUploadNewHighlightsEnabled() then return end
  if not isNewLocalHighlightEvent(items) then return end
  if self._auto_upload_new_highlights_scheduled then return end

  self._auto_upload_new_highlights_scheduled = true
  UIManager:scheduleIn(2, function()
    self._auto_upload_new_highlights_scheduled = false
    if not autoUploadNewHighlightsEnabled() then return end
    local cfg_ok = Config.validate()
    if not cfg_ok then return end
    if not NetworkMgr:isOnline() then return end
    NetworkMgr:runWhenOnline(function()
      local ok, result = pcall(AnnotationSync.push_new_highlights_only, self.ui)
      if not ok then
        print("[book-aware] auto upload new highlight failed: " .. tostring(result))
      elseif type(result) == "table" and (result.failed or 0) > 0 then
        print("[book-aware] auto upload new highlight partial failure: " .. tostring(result.failed))
      end
    end)
  end)
end

function Caudex:onSaveSettings()
  pushWebHighlightChanges(self, "save")
end

function Caudex:onCloseDocument()
  pushWebHighlightChanges(self, "close")
end

local function showAnnotationSyncResult(result)
  local summary = string.format(
    _("Web 高亮同步完成。\n同步：%d  恢复：%d  拉取：%d\n上传：%d  推送：%d  删除：%d\n冲突：%d  失败：%d"),
    result.resolved or 0, result.repaired or 0, result.pulled or 0,
    result.created or 0, result.pushed or 0, result.removed or 0,
    (result.conflict or 0) + (result.metadata_conflicts or 0), result.failed or 0
  )
  -- Surface per-annotation upload failure detail so the user can diagnose
  -- without diving into crash.log. Limit to the first few entries to keep
  -- the toast readable.
  local create_errors = type(result.create_errors) == "table" and result.create_errors or {}
  if #create_errors > 0 then
    local lines = { summary, "", _("上传失败详情：") }
    local max_lines = 3
    for i = 1, math.min(#create_errors, max_lines) do
      local e = create_errors[i]
      local exact_snip = (type(e.exact) == "string" and e.exact ~= "")
        and ("\"" .. e.exact .. "\"") or "?"
      table.insert(lines, string.format("%d. %s\n   %s",
        i, exact_snip, tostring(e.message or ""):sub(1, 200)))
    end
    if #create_errors > max_lines then
      table.insert(lines, string.format(_("…及其他 %d 条"),
        #create_errors - max_lines))
    end
    summary = table.concat(lines, "\n")
  end
  UIManager:show(InfoMessage:new {
    text    = summary,
    timeout = (result.failed or 0) > 0 and 12 or 5,
  })
end

local function isAnnotationSyncConfirmationRequired(err)
  return type(err) == "table" and err.bookaware_confirmation_required == true
end

local runManualAnnotationSync
runManualAnnotationSync = function(self, force)
  UIManager:show(InfoMessage:new {
    text    = force and _("正在按后端为准强制同步 Web 高亮...") or _("正在同步 Web 高亮..."),
    timeout = 1,
  })
  local opts = force and { force = true } or nil
  local ok, result = pcall(AnnotationSync.sync, self.ui, opts)
  if ok then
    showAnnotationSyncResult(result)
    return
  end

  if isAnnotationSyncConfirmationRequired(result) then
    local pending_removals = tonumber(result.pending_removals or 0) or 0
    UIManager:show(ConfirmBox:new {
      text = string.format(
        _("后端同步将删除本地 %d 条高亮。\n\n后端将作为高亮同步依据；如果你确认这些高亮已在后端删除，继续同步。"),
        pending_removals),
      ok_text = _("继续同步"),
      cancel_text = _("取消"),
      ok_callback = function()
        runManualAnnotationSync(self, true)
      end,
    })
    return
  end

  UIManager:show(InfoMessage:new {
    text    = _("Web 高亮同步失败：") .. tostring(result),
    timeout = 8,
  })
end

-- Caudex 入口：阅读器中放到 Navigation/导航 菜单的目录上方；文件管理器中仍放到 Tools/工具。
function Caudex:addToMainMenu(menu_items)
  local caudex_items = {
    {
      text = _("Recent results"),
      callback = function()
        local ok, err = pcall(function()
          BackgroundJobs.show_results_menu(self.ui)
        end)
        if not ok then
          UIManager:show(InfoMessage:new {
            text    = _("打开 Caudex 最近结果失败：") .. tostring(err),
            timeout = 6,
          })
        end
      end,
    },
  }

  if not isFileManagerUI(self.ui) then
    table.insert(caudex_items, {
      text = _("Upload current book to Book-Aware"),
      callback = function()
        if not checkNetworkAndConfig() then return end
        NetworkMgr:runWhenOnline(function()
          BookUpload.upload_current(self.ui)
        end)
      end,
    })
  end

  table.insert(caudex_items, {
    text = _("Book-Aware book sync"),
    callback = function()
      if not checkNetworkAndConfig() then return end
      NetworkMgr:runWhenOnline(function()
        BookSync.show(self.ui)
      end)
    end,
  })

  if not isFileManagerUI(self.ui) then
    table.insert(caudex_items, {
      text = _("Sync web highlights"),
      callback = function()
        if not checkNetworkAndConfig() then return end
        NetworkMgr:runWhenOnline(function()
          runManualAnnotationSync(self, false)
        end)
      end,
    })
  end

  if not isFileManagerUI(self.ui) then
    table.insert(caudex_items, {
      text = _("View conflict highlights"),
      callback = function()
        if not checkNetworkAndConfig() then return end
        NetworkMgr:runWhenOnline(function()
          local ok, data = pcall(AnnotationSync.list_conflicts, self.ui)
          if not ok then
            UIManager:show(InfoMessage:new {
              text    = _("无法获取冲突高亮：") .. tostring(data),
              timeout = 6,
            })
            return
          end
          if #data == 0 then
            UIManager:show(InfoMessage:new {
              text    = _("无冲突高亮。"),
              timeout = 3,
            })
            return
          end
          local lines = {}
          for i, hl in ipairs(data) do
            local excerpt = (type(hl.exact) == "string" and #hl.exact > 0)
              and hl.exact:sub(1, 60) or "?"
            local err = (hl.koreader and type(hl.koreader.error) == "string")
              and hl.koreader.error:sub(1, 120) or ""
            table.insert(lines, string.format(
              "%d. \"%s\"\n   %s", i, excerpt, err))
          end
          UIManager:show(InfoMessage:new {
            text = string.format(
              _("冲突高亮（%d）：\n\n%s"), #data, table.concat(lines, "\n\n")),
            timeout = 15,
          })
        end)
      end,
    })
  end

  table.insert(caudex_items, {
    text = _("检查 Caudex 更新"),
    callback = function()
      if not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new {
          text    = _("网络未连接，请检查网络设置后重试。"),
          timeout = 3,
        })
        return
      end
      NetworkMgr:runWhenOnline(function()
        UpdateChecker.checkAndPromptInstall()
      end)
    end,
  })

  local sorting_hint = "tools"
  if not isFileManagerUI(self.ui) then
    placeCaudexBeforeToc()
    sorting_hint = "navi"
  end

  menu_items.caudex = {
    text = _("Caudex"),
    sorting_hint = sorting_hint,
    sub_item_table = caudex_items,
  }
end

return Caudex
