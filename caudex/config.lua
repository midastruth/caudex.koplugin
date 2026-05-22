-- 配置加载与校验模块；是全局唯一加载 configuration.lua 的地方
local Config = {}

local _cfg    = nil
local _loaded = false

local function load()
  if _loaded then return _cfg end
  _loaded = true
  local ok, result = pcall(function() return require("configuration") end)
  if ok and type(result) == "table" then
    _cfg = result
  else
    print(ok and "configuration.lua did not return a table, skipping..."
              or "configuration.lua not found or failed to load, skipping...")
  end
  return _cfg
end

-- 返回原始配置表（可能为 nil）
function Config.get()
  return load()
end

-- 校验逻辑与 ai_client.resolve_base_url() 严格一致：
--   1. reader_ai_base_url 是非空字符串 → 有效
--   2. base_url 是非空字符串且不含 /chat/completions → 有效
--   3. 否则 → 无效（不接受静默回退到默认本地地址）
function Config.validate()
  local cfg = load()
  if not cfg then
    return false, "configuration.lua not found or returned a non-table value"
  end
  if type(cfg.reader_ai_base_url) == "string" and cfg.reader_ai_base_url ~= "" then
    return true, cfg
  end
  if type(cfg.base_url) == "string" and cfg.base_url ~= ""
      and not cfg.base_url:match("/chat/completions") then
    return true, cfg
  end
  return false,
    "No valid API endpoint configured (set reader_ai_base_url or a non-OpenAI base_url)"
end

-- 返回 translate_to 目标语言，未配置返回 nil
function Config.get_translate_target()
  local cfg = load()
  if cfg and cfg.features and cfg.features.translate_to
      and cfg.features.translate_to ~= "" then
    return cfg.features.translate_to
  end
  return nil
end

-- 返回全局语言配置，未配置返回 "auto"
function Config.get_language()
  local cfg = load()
  if cfg then
    if type(cfg.language) == "string" and cfg.language ~= "" then
      return cfg.language
    end
    if cfg.features and type(cfg.features.dictionary_language) == "string"
        and cfg.features.dictionary_language ~= "" then
      return cfg.features.dictionary_language
    end
  end
  return "auto"
end

return Config
