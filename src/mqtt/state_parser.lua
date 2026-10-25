--- @module "lib.state_parser"
--- Generic state parsing utilities using "match one, default other" logic.
---
--- This module extracts the common pattern used for parsing boolean states from
--- MQTT payloads throughout the MQTT General driver. The logic handles three cases:
--- 1. Both values specified: require exact match for either
--- 2. Only trueValue specified: match = true, any other value = false
--- 3. Only falseValue specified: match = false, any other value = true
---
--- Used by: availability parsing, relay state parsing, contact state parsing

--- @class StateParser
local StateParser = {}

--- Split a JSONPath (without "$") into steps: { key = "a" }, { index = 0 }
--- or { filter = { path = { "component" }, value = "input:0" } }.
--- @return table[]|nil steps nil when the path cannot be read
local function jsonPathSteps(path)
  local steps = {}
  local i, n = 1, #path
  while i <= n do
    local c = path:sub(i, i)
    if c == "." then
      i = i + 1
    elseif c == "[" then
      local close
      if path:sub(i, i + 1) == "[?" then
        -- [?(@.a.b=='x')] or [?(@.a=="x")] or [?(@.a==3)]
        local expr, rest = path:match("^%[%?%((.-)%)%](.*)$", i)
        if expr == nil then
          return nil
        end
        local lhs, rhs = expr:match("^%s*@%.([%w_%.]+)%s*==%s*(.-)%s*$")
        if lhs == nil then
          return nil
        end
        local value = rhs:match("^'(.*)'$") or rhs:match('^"(.*)"$')
        if value == nil then
          value = tonumber(rhs)
          if value == nil then
            return nil
          end
        end
        local keys = {}
        for k in lhs:gmatch("[^.]+") do
          keys[#keys + 1] = k
        end
        steps[#steps + 1] = { filter = { path = keys, value = value } }
        i = n - #rest + 1
      else
        close = path:find("]", i, true)
        if close == nil then
          return nil
        end
        local inner = path:sub(i + 1, close - 1)
        local quoted = inner:match("^'(.*)'$") or inner:match('^"(.*)"$')
        if quoted then
          steps[#steps + 1] = { key = quoted }
        elseif inner:match("^%d+$") then
          steps[#steps + 1] = { index = tonumber(inner) }
        else
          return nil
        end
        i = close + 1
      end
    else
      local j = i
      while j <= n and path:sub(j, j) ~= "." and path:sub(j, j) ~= "[" do
        j = j + 1
      end
      steps[#steps + 1] = { key = path:sub(i, j - 1) }
      i = j
    end
  end
  return steps
end

--- Extract a value from a JSON table using JSONPath syntax.
--- Supports `$` root prefix, dot notation, bracket array indexing, quoted
--- bracket keys and a filter that picks the first array element whose field
--- equals a value.
---
--- @param jsonTable table The parsed JSON table.
--- @param jsonPath string JSONPath expression (e.g., "$.state.power" or "$.sensors[0].temp").
--- @return any|nil value The extracted value, or nil if path not found.
---
--- Examples:
--- ```lua
--- local t = { state = { power = "ON" }, sensors = { { temp = 72 } } }
--- StateParser.extractJsonPath(t, "$.state.power")   --> "ON"
--- StateParser.extractJsonPath(t, "$.sensors[0].temp") --> 72
--- StateParser.extractJsonPath(t, "$")                --> t (root)
--- StateParser.extractJsonPath(t, "$.missing")        --> nil
--- -- Shelly NotifyEvent: the event of one input
--- StateParser.extractJsonPath(e, "$.params.events[?(@.component=='input:0')].event")
--- ```
function StateParser.extractJsonPath(jsonTable, jsonPath)
  if not jsonPath or jsonPath == "" or jsonPath == "$" then
    return jsonTable
  end

  if not string.match(jsonPath, "^%$") then
    return nil
  end

  local path = string.match(jsonPath, "^%$(.*)$") or ""
  if path == "" or path == "." then
    return jsonTable
  end

  local steps = jsonPathSteps(path)
  if steps == nil then
    return nil
  end
  local current = jsonTable
  for _, step in ipairs(steps) do
    if type(current) ~= "table" then
      return nil
    end
    if step.key ~= nil then
      current = current[step.key]
    elseif step.index ~= nil then
      current = current[step.index + 1] -- Lua 1-indexed
    else
      local found = nil
      for _, element in ipairs(current) do
        local v = element
        for _, k in ipairs(step.filter.path) do
          v = type(v) == "table" and v[k] or nil
        end
        if v ~= nil and (v == step.filter.value or tostring(v) == tostring(step.filter.value)) then
          found = element
          break
        end
      end
      current = found
    end
  end

  return current
end

--- Parse a boolean state from payload using "match one, default other" logic.
---
--- @param payload string The payload to parse.
--- @param trueValue string|nil Value indicating true/on/open/available state.
--- @param falseValue string|nil Value indicating false/off/closed/unavailable state.
--- @return boolean|nil state True, false, or nil if cannot determine.
---
--- Examples:
--- ```lua
--- -- Both specified: require exact match
--- StateParser.parse("ON", "ON", "OFF")  --> true
--- StateParser.parse("OFF", "ON", "OFF") --> false
--- StateParser.parse("???", "ON", "OFF") --> nil (no match)
---
--- -- Only trueValue: match = true, else = false
--- StateParser.parse("online", "online", nil)  --> true
--- StateParser.parse("offline", "online", nil) --> false
---
--- -- Only falseValue: match = false, else = true
--- StateParser.parse("offline", nil, "offline") --> false
--- StateParser.parse("online", nil, "offline")  --> true
---
--- -- Neither specified: cannot determine
--- StateParser.parse("anything", nil, nil) --> nil
--- ```
function StateParser.parse(payload, trueValue, falseValue)
  -- Normalize empty strings to nil
  if trueValue == "" then
    trueValue = nil
  end
  if falseValue == "" then
    falseValue = nil
  end

  -- If both are specified, require exact match
  if trueValue ~= nil and falseValue ~= nil then
    if payload == trueValue then
      return true
    elseif payload == falseValue then
      return false
    end
    return nil
  end

  -- If only trueValue is specified: match = true, otherwise = false
  if trueValue ~= nil then
    return payload == trueValue
  end

  -- If only falseValue is specified: match = false, otherwise = true
  if falseValue ~= nil then
    return payload ~= falseValue
  end

  -- Neither specified, cannot determine
  return nil
end

return StateParser
