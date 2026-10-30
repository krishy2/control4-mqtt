--- Rolling history of numeric values for the MQTT General w Webview graphs.
---
--- Each field keeps a fixed number of time slots (default 96 x 15 minutes = 24 hours)
--- in a ring buffer, in RAM only: nothing is written to flash, so the history starts
--- again after a controller or driver restart. A slot holds the average of every value
--- that arrived during it; the current slot keeps a running sum and count until the
--- next slot starts.
---
--- Memory: two arrays of `size` numbers per field (slot id and average), about 1.5 KB
--- per field for 96 slots plus the Lua table overhead.

local History = {}
History.__index = History

--- Slot length in seconds (15 minutes).
History.STEP = 900

--- Number of slots kept (96 x 15 minutes = 24 hours, the current slot included).
History.SIZE = 96

--- Create a history.
--- @param step number|nil Slot length in seconds.
--- @param size integer|nil Number of slots.
--- @return table
function History.new(step, size)
  return setmetatable({ step = step or History.STEP, size = size or History.SIZE, series = {} }, History)
end

--- Slot number of a time (seconds since the epoch).
--- @param now number
--- @return integer
function History:slotOf(now)
  return math.floor(now / self.step)
end

--- Move a series' finished current slot into the ring.
local function closeSlot(self, s)
  if s.cur ~= nil and s.n > 0 then
    local i = s.cur % self.size + 1
    s.id[i] = s.cur
    s.avg[i] = s.sum / s.n
  end
end

--- Add a value to a field's current slot.
--- @param key string
--- @param value number
--- @param now number Seconds since the epoch.
function History:add(key, value, now)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return
  end
  local slot = self:slotOf(now)
  local s = self.series[key]
  if s == nil then
    s = { id = {}, avg = {}, cur = nil, sum = 0, n = 0 }
    self.series[key] = s
  end
  if s.cur ~= slot then
    closeSlot(self, s)
    s.cur, s.sum, s.n = slot, 0, 0
  end
  s.sum = s.sum + value
  s.n = s.n + 1
end

--- Average of a field's slot `slot`, or nil.
--- @param key string
--- @param slot integer
--- @return number|nil
function History:value(key, slot)
  local s = self.series[key]
  if s == nil then
    return nil
  end
  if s.cur == slot and s.n > 0 then
    return s.sum / s.n
  end
  local i = slot % self.size + 1
  if s.id[i] == slot then
    return s.avg[i]
  end
  return nil
end

--- The points of the last 24 hours (the window ending with the slot of `now`).
--- @param key string
--- @param now number Seconds since the epoch.
--- @return table[]|nil points { slot, average } oldest first, or nil without history
function History:points(key, now)
  local s = self.series[key]
  if s == nil then
    return nil
  end
  local last = self:slotOf(now)
  local first = last - self.size + 1
  local out = {}
  for slot = first, last do
    local v = self:value(key, slot)
    if v ~= nil then
      out[#out + 1] = { slot, v }
    end
  end
  return out
end

--- Forget one field.
--- @param key string
function History:drop(key)
  self.series[key] = nil
end

--- Forget every field.
function History:clear()
  self.series = {}
end

return History
