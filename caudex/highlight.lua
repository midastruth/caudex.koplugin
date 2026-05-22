-- 从 KOReader 高亮数据结构中提取 highlighted_text / context_text
local Util = require("caudex.util")

local Highlight = {}

local function extract_string(value)
  if type(value) == "string" then
    return value
  elseif type(value) == "table" then
    if type(value.text) == "string" then
      return value.text
    end
    -- 尝试拼接 before / selection / after
    local before    = type(value.before)    == "string" and value.before    or nil
    local selection = type(value.selection) == "string" and value.selection or nil
    local after     = type(value.after)     == "string" and value.after     or nil
    if before or selection or after then
      local parts = {}
      if before    and before    ~= "" then table.insert(parts, before)    end
      if selection and selection ~= "" then table.insert(parts, selection) end
      if after     and after     ~= "" then table.insert(parts, after)     end
      if #parts > 0 then return table.concat(parts, " ") end
    end
    -- 数组中第一个非空字符串
    for _, item in ipairs(value) do
      if type(item) == "string" and item ~= "" then return item end
    end
  end
  return nil
end

-- 返回 highlighted_text, context_text
function Highlight.extract(source)
  local highlighted_text = ""
  local context_text = nil

  if type(source) == "table" then
    local selected = source.selected_text or source
    if type(selected) == "table" then
      highlighted_text = selected.text or highlighted_text
      -- Iterate over field names so ipairs never stops early on a nil value.
      local candidate_fields = {
        "context", "paragraph", "sentence", "snippet",
        "selection_context", "text_block", "full_text", "extended_text",
      }
      for _, field in ipairs(candidate_fields) do
        local t = extract_string(selected[field])
        if t and t ~= "" then
          context_text = t
          break
        end
      end
    end
  elseif type(source) == "string" then
    highlighted_text = source
  end

  highlighted_text = Util.trim(highlighted_text)
  if not context_text or context_text == "" then
    context_text = highlighted_text
  end
  return highlighted_text, Util.trim(context_text)
end

return Highlight
