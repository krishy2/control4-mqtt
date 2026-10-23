--- @module "mqtt.color"
--- Color space conversions used by the MQTT Light driver.
---
--- Control4's light_v2 proxy describes chromaticity as a CIE 1931 xy point plus
--- a color mode (0 = full color, 1 = color temperature). MQTT lights speak RGB,
--- HSB, HS, xy, Kelvin or mireds. This module converts between them. Every
--- function is pure Lua so it can be unit tested without a controller.
---
--- Conventions:
--- - r, g, b are 0-255 unless a function says otherwise.
--- - hue is 0-360, saturation and value/brightness are 0-100.
--- - Kelvin values are plain numbers (e.g. 2700).

--- @class MqttColor
local Color = {}

--- Clamp a number to a range.
--- @param v number
--- @param lo number
--- @param hi number
--- @return number
function Color.clamp(v, lo, hi)
  if v < lo then
    return lo
  elseif v > hi then
    return hi
  end
  return v
end

--- Round to the nearest integer (half away from zero).
--- @param v number
--- @return integer
function Color.round(v)
  if v >= 0 then
    return math.floor(v + 0.5)
  end
  return math.ceil(v - 0.5)
end

--- Round to a number of decimal places.
--- @param v number
--- @param places integer
--- @return number
function Color.roundTo(v, places)
  local m = 10 ^ places
  return Color.round(v * m) / m
end

-------------------------------------------------------------------------------
-- sRGB <-> CIE 1931 xy
-------------------------------------------------------------------------------

local function toLinear(c)
  if c <= 0.04045 then
    return c / 12.92
  end
  return ((c + 0.055) / 1.055) ^ 2.4
end

local function fromLinear(c)
  if c <= 0.0031308 then
    return 12.92 * c
  end
  return 1.055 * (c ^ (1 / 2.4)) - 0.055
end

--- Convert sRGB to a CIE 1931 xy chromaticity point.
--- Brightness is discarded: (255,0,0) and (128,0,0) give the same point.
--- @param r number 0-255
--- @param g number 0-255
--- @param b number 0-255
--- @return number|nil x nil for black
--- @return number|nil y
function Color.rgbToXy(r, g, b)
  local rl = toLinear(Color.clamp(r, 0, 255) / 255)
  local gl = toLinear(Color.clamp(g, 0, 255) / 255)
  local bl = toLinear(Color.clamp(b, 0, 255) / 255)

  -- sRGB (D65) to XYZ
  local X = rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375
  local Y = rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750
  local Z = rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041

  local sum = X + Y + Z
  if sum <= 0 then
    return nil, nil
  end
  return X / sum, Y / sum
end

--- Convert a CIE 1931 xy point to full-intensity sRGB.
--- The result is scaled so the brightest channel is 255; apply brightness
--- separately with Color.scaleRgb.
--- @param x number
--- @param y number
--- @return integer r
--- @return integer g
--- @return integer b
function Color.xyToRgb(x, y)
  if y <= 0 then
    return 255, 255, 255
  end
  local Y = 1.0
  local X = (Y / y) * x
  local Z = (Y / y) * (1 - x - y)

  -- XYZ to linear sRGB (D65)
  local rl = X * 3.2404542 - Y * 1.5371385 - Z * 0.4985314
  local gl = -X * 0.9692660 + Y * 1.8760108 + Z * 0.0415560
  local bl = X * 0.0556434 - Y * 0.2040259 + Z * 1.0572252

  -- Out of gamut: drop negative components, then normalize to the brightest.
  rl, gl, bl = math.max(rl, 0), math.max(gl, 0), math.max(bl, 0)
  local maxl = math.max(rl, gl, bl)
  if maxl <= 0 then
    return 255, 255, 255
  end
  rl, gl, bl = rl / maxl, gl / maxl, bl / maxl

  return Color.round(fromLinear(rl) * 255), Color.round(fromLinear(gl) * 255), Color.round(fromLinear(bl) * 255)
end

--- Scale an RGB color so its brightest channel matches a brightness percentage.
--- @param r number
--- @param g number
--- @param b number
--- @param brightness number 0-100
--- @return integer r
--- @return integer g
--- @return integer b
function Color.scaleRgb(r, g, b, brightness)
  local maxc = math.max(r, g, b)
  if maxc <= 0 then
    return 0, 0, 0
  end
  local f = (Color.clamp(brightness, 0, 100) / 100) * 255 / maxc
  return Color.round(r * f), Color.round(g * f), Color.round(b * f)
end

--- Brightness percentage carried by an RGB value (brightest channel).
--- @param r number
--- @param g number
--- @param b number
--- @return number brightness 0-100
function Color.rgbBrightness(r, g, b)
  return Color.clamp(math.max(r, g, b), 0, 255) / 255 * 100
end

-------------------------------------------------------------------------------
-- HSV <-> RGB
-------------------------------------------------------------------------------

--- Convert HSV to RGB.
--- @param h number hue 0-360
--- @param s number saturation 0-100
--- @param v number value 0-100
--- @return integer r
--- @return integer g
--- @return integer b
function Color.hsvToRgb(h, s, v)
  h = (h % 360) / 60
  s = Color.clamp(s, 0, 100) / 100
  v = Color.clamp(v, 0, 100) / 100
  local i = math.floor(h)
  local f = h - i
  local p = v * (1 - s)
  local q = v * (1 - s * f)
  local t = v * (1 - s * (1 - f))
  local r, g, b
  if i == 0 then
    r, g, b = v, t, p
  elseif i == 1 then
    r, g, b = q, v, p
  elseif i == 2 then
    r, g, b = p, v, t
  elseif i == 3 then
    r, g, b = p, q, v
  elseif i == 4 then
    r, g, b = t, p, v
  else
    r, g, b = v, p, q
  end
  return Color.round(r * 255), Color.round(g * 255), Color.round(b * 255)
end

--- Convert RGB to HSV.
--- @param r number 0-255
--- @param g number 0-255
--- @param b number 0-255
--- @return number h 0-360
--- @return number s 0-100
--- @return number v 0-100
function Color.rgbToHsv(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local maxc = math.max(r, g, b)
  local minc = math.min(r, g, b)
  local d = maxc - minc
  local h = 0
  if d > 0 then
    if maxc == r then
      h = ((g - b) / d) % 6
    elseif maxc == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h * 60
  end
  local s = maxc > 0 and (d / maxc) or 0
  return h, s * 100, maxc * 100
end

-------------------------------------------------------------------------------
-- Color temperature
-------------------------------------------------------------------------------

--- Convert a correlated color temperature to a CIE 1931 xy point on the
--- Planckian locus (Kim et al. cubic spline, valid 1667K-25000K).
--- @param kelvin number
--- @return number x
--- @return number y
function Color.cctToXy(kelvin)
  local T = Color.clamp(kelvin, 1667, 25000)
  local x
  if T <= 4000 then
    x = -0.2661239e9 / T ^ 3 - 0.2343589e6 / T ^ 2 + 0.8776956e3 / T + 0.179910
  else
    x = -3.0258469e9 / T ^ 3 + 2.1070379e6 / T ^ 2 + 0.2226347e3 / T + 0.240390
  end
  local y
  if T <= 2222 then
    y = -1.1063814 * x ^ 3 - 1.34811020 * x ^ 2 + 2.18555832 * x - 0.20219683
  elseif T <= 4000 then
    y = -0.9549476 * x ^ 3 - 1.37418593 * x ^ 2 + 2.09137015 * x - 0.16748867
  else
    y = 3.0817580 * x ^ 3 - 5.87338670 * x ^ 2 + 3.75112997 * x - 0.37001483
  end
  return x, y
end

--- Convert a CIE 1931 xy point to a correlated color temperature (McCamy).
--- @param x number
--- @param y number
--- @return number kelvin
function Color.xyToCct(x, y)
  local n = (x - 0.3320) / (0.1858 - y)
  return 449 * n ^ 3 + 3525 * n ^ 2 + 6823.3 * n + 5520.33
end

--- Convert Kelvin to mireds.
--- @param kelvin number
--- @return integer
function Color.kelvinToMired(kelvin)
  if kelvin <= 0 then
    return 0
  end
  return Color.round(1000000 / kelvin)
end

--- Convert mireds to Kelvin.
--- @param mired number
--- @return integer
function Color.miredToKelvin(mired)
  if mired <= 0 then
    return 0
  end
  return Color.round(1000000 / mired)
end

return Color
