-- 通用工具函数
local Util = {}

function Util.trim(text)
  return (text or ""):match("^%s*(.-)%s*$")
end

function Util.clone_table(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = value
  end
  return copy
end

function Util.file_stat(filepath)
  if not filepath or filepath == "" then return nil, nil end

  local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
  if ok_lfs and lfs and type(lfs.attributes) == "function" then
    local ok_attr, attr = pcall(lfs.attributes, filepath)
    if ok_attr and type(attr) == "table" then
      return attr.size, attr.modification
    end
  end

  local file = io.open(filepath, "rb")
  if not file then return nil, nil end
  local size = file:seek("end")
  file:close()
  return size, nil
end

local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function fallback_base64(data)
  local out = {}
  local index = 1
  for i = 1, #data, 3 do
    local a = data:byte(i)
    local b = data:byte(i + 1)
    local c = data:byte(i + 2)
    local triple = a * 65536 + (b or 0) * 256 + (c or 0)
    local n1 = math.floor(triple / 262144) % 64 + 1
    local n2 = math.floor(triple / 4096) % 64 + 1
    local n3 = math.floor(triple / 64) % 64 + 1
    local n4 = triple % 64 + 1
    out[index] = BASE64_ALPHABET:sub(n1, n1)
    out[index + 1] = BASE64_ALPHABET:sub(n2, n2)
    out[index + 2] = b and BASE64_ALPHABET:sub(n3, n3) or "="
    out[index + 3] = c and BASE64_ALPHABET:sub(n4, n4) or "="
    index = index + 4
  end
  return table.concat(out)
end

function Util.base64_file(filepath)
  if not filepath or filepath == "" then
    return nil, "missing file path"
  end

  local file, open_err = io.open(filepath, "rb")
  if not file then
    return nil, open_err or "cannot open file"
  end
  local data = file:read("*all") or ""
  file:close()

  local ok_mime, mime = pcall(require, "mime")
  if ok_mime and mime and type(mime.b64) == "function" then
    local ok_b64, encoded = pcall(mime.b64, data)
    if ok_b64 and type(encoded) == "string" and encoded ~= "" then
      return encoded
    end
  end
  return fallback_base64(data)
end

-- Hash an in-memory string using KOReader's ffi/sha2 module. Returns the hex
-- digest, or (nil, err) when the SHA library is unavailable.
function Util.sha256_string(data)
  if type(data) ~= "string" then
    return nil, "sha256_string requires a string"
  end
  local ok_sha, sha = pcall(require, "ffi/sha2")
  if not ok_sha or type(sha) ~= "table" or type(sha.sha256) ~= "function" then
    return nil, "ffi/sha2.sha256 unavailable"
  end
  local ok, digest = pcall(sha.sha256, data)
  if not ok then return nil, tostring(digest) end
  if type(digest) ~= "string" or digest == "" then
    return nil, "empty sha256 digest"
  end
  return digest
end

function Util.sha256_file(filepath)
  if not filepath or filepath == "" then
    return nil, "missing file path"
  end

  local ok_sha, sha = pcall(require, "ffi/sha2")
  if not ok_sha or type(sha) ~= "table" or type(sha.sha256) ~= "function" then
    return nil, "ffi/sha2.sha256 unavailable"
  end

  local file, open_err = io.open(filepath, "rb")
  if not file then
    return nil, open_err or "cannot open file"
  end

  local ok_hash, digest = pcall(function()
    local ok_init, update = pcall(sha.sha256)
    if ok_init and type(update) == "function" then
      while true do
        local chunk = file:read(64 * 1024)
        if not chunk then break end
        update(chunk)
      end
      return update()
    end

    file:seek("set", 0)
    local data = file:read("*all") or ""
    return sha.sha256(data)
  end)
  file:close()

  if not ok_hash then
    return nil, tostring(digest)
  end
  if type(digest) ~= "string" or digest == "" then
    return nil, "empty sha256 digest"
  end
  return digest
end

-- 将逗号分隔字符串拆分为去空格后的数组；nil/空字符串均返回空表
function Util.split_csv(text)
  if not text then return {} end
  local parts = {}
  for part in tostring(text):gmatch("[^,]+") do
    local trimmed = Util.trim(part)
    if trimmed ~= "" then
      table.insert(parts, trimmed)
    end
  end
  return parts
end

return Util
