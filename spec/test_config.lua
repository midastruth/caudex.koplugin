local H = require("spec.helpers")

H.section("B. caudex/config.lua")

-- Helper: load a fresh Config with a given mock configuration value.
-- config_mock can be any value (table, string, nil …).
local function with_config(config_mock, fn)
  H.reset("caudex.config", "configuration")
  package.loaded["configuration"] = config_mock
  local Config = require("caudex.config")
  fn(Config)
  H.reset("caudex.config", "configuration")
end

-- Non-table return from configuration.lua
with_config("not a table", function(Config)
  local ok, msg = Config.validate()
  H.is_false("non-table config: validate() returns false", ok)
  H.contains("non-table config: error mentions 'non-table'", msg, "non-table")
end)

-- nil configuration (module not found: require raises an error)
-- LuaJIT does NOT treat package.loaded[x]=false as "cached absent" — it still
-- searches the disk.  Use package.preload to inject a failing loader instead.
do
  H.reset("caudex.config", "configuration")
  package.preload["configuration"] = function() error("configuration not found") end
  local Config2 = require("caudex.config")
  local ok, msg = Config2.validate()
  H.is_false("nil config: validate() returns false", ok)
  package.preload["configuration"] = nil
  H.reset("caudex.config", "configuration")
end

-- Both URLs empty
with_config({ reader_ai_base_url = "", base_url = "" }, function(Config)
  local ok, _ = Config.validate()
  H.is_false("empty URLs: validate() returns false", ok)
end)

-- base_url is an OpenAI completions endpoint → rejected
with_config({ base_url = "https://api.openai.com/v1/chat/completions" }, function(Config)
  local ok, _ = Config.validate()
  H.is_false("OpenAI completions URL: validate() returns false", ok)
end)

-- Valid reader_ai_base_url
with_config({ reader_ai_base_url = "https://example.com" }, function(Config)
  local ok, cfg = Config.validate()
  H.is_true("reader_ai_base_url set: validate() returns true", ok)
  H.is_true("reader_ai_base_url: returns cfg table", type(cfg) == "table")
end)

-- Valid non-OpenAI base_url
with_config({ base_url = "https://example.com/ai" }, function(Config)
  local ok, _ = Config.validate()
  H.is_true("non-OpenAI base_url: validate() returns true", ok)
end)

-- reader_ai_base_url takes priority over base_url
with_config({ reader_ai_base_url = "https://primary.example.com",
              base_url           = "" }, function(Config)
  local ok, _ = Config.validate()
  H.is_true("reader_ai_base_url wins over empty base_url", ok)
end)
