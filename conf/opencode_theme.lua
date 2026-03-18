-- OpenCode "feb" theme generator.
-- Works around the ConPTY limitation on Windows where OSC 4/10/11 color
-- queries are stripped, preventing OpenCode's built-in theme detection from
-- detecting terminal colors.
--
-- WezTerm detects dark/light via native Windows APIs (window:get_appearance),
-- so we read the active color scheme, build a grayscale ramp from the
-- background color, and write the result as a JSON theme file that OpenCode
-- picks up automatically.

local wezterm = require("wezterm")
local theme = require("conf.theme")

local M = {}

local is_windows = os.getenv("OS") == "Windows_NT"
local SEP = is_windows and "\\" or "/"
local THEME_DIR = os.getenv("HOME")
  or os.getenv("USERPROFILE")
  or (os.getenv("HOMEDRIVE") .. os.getenv("HOMEPATH"))
THEME_DIR = THEME_DIR .. SEP .. ".config" .. SEP .. "opencode" .. SEP .. "themes"

local THEME_FILE = THEME_DIR .. SEP .. "feb.json"

local CACHE_DIR = wezterm.config_dir .. SEP .. ".cache"
local HASH_FILE = CACHE_DIR .. SEP .. "theme_hash"
local THEME_SRC = wezterm.config_dir .. SEP .. "conf" .. SEP .. "theme.lua"

local function djb2(s)
  local h = 5381
  for i = 1, #s do
    h = ((h * 33) + s:byte(i)) % 0x100000000
  end
  return string.format("%08x", h)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function theme_changed()
  local src = read_file(THEME_SRC)
  if not src then return true end
  local current = djb2(src)
  local saved = read_file(HASH_FILE)
  if saved then saved = saved:match("^%S+") end
  return current ~= saved, current
end

local function save_hash(hash)
  if is_windows then
    os.execute('mkdir "' .. CACHE_DIR:gsub("/", "\\") .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. CACHE_DIR .. '"')
  end
  local f = io.open(HASH_FILE, "w")
  if f then f:write(hash) f:close() end
end

-- Parse "#rrggbb" hex color to r, g, b (0-255)
local function hex_to_rgb(hex)
  if not hex or type(hex) ~= "string" then return nil end
  local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)")
  if not r then return nil end
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

-- Convert r, g, b (0-255) to "#rrggbb"
local function rgb_to_hex(r, g, b)
  return string.format("#%02x%02x%02x", math.floor(r), math.floor(g), math.floor(b))
end

-- Compute relative luminance (0-1)
local function luminance(r, g, b)
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255
end

-- Blend two colors by factor t (0 = a, 1 = b)
local function blend(ar, ag, ab, br, bg, bb, t)
  return ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t
end

-- Generate 12 grayscale steps from a background color, preserving its hue tint.
-- Mirrors OpenCode's generateGrayScale logic: shifts up to 40% toward
-- white (dark mode) or black (light mode).
local function generate_grayscale(bgr, bgg, bgb, is_dark)
  local target_r, target_g, target_b
  if is_dark then
    target_r, target_g, target_b = 255, 255, 255
  else
    target_r, target_g, target_b = 0, 0, 0
  end
  local steps = {}
  local max_shift = 0.40
  for i = 1, 12 do
    local t = (i / 12) * max_shift
    local r, g, b = blend(bgr, bgg, bgb, target_r, target_g, target_b, t)
    steps[i] = rgb_to_hex(r, g, b)
  end
  return steps
end

-- Build the full OpenCode theme JSON string from WezTerm scheme colors.
local function build_theme_json(colors, is_dark)
  local bg_hex = colors.background or "#1a1b26"
  local fg_hex = colors.foreground or "#c0caf5"

  local bgr, bgg, bgb = hex_to_rgb(bg_hex)
  if not bgr then bgr, bgg, bgb = 26, 27, 38 end

  local gray = generate_grayscale(bgr, bgg, bgb, is_dark)

  -- ANSI color indices from the scheme
  local ansi = colors.ansi or {}
  local brights = colors.brights or {}

  -- Standard ANSI mapping:
  -- 0=black 1=red 2=green 3=yellow 4=blue 5=magenta 6=cyan 7=white
  local black   = ansi[1] or "#000000"
  local red     = ansi[2] or "#ff0000"
  local green   = ansi[3] or "#00ff00"
  local yellow  = ansi[4] or "#ffff00"
  local blue    = ansi[5] or "#0000ff"
  local magenta = ansi[6] or "#ff00ff"
  local cyan    = ansi[7] or "#00ffff"

  local bright_black   = brights[1] or black
  local bright_red     = brights[2] or red
  local bright_green   = brights[3] or green
  local bright_yellow  = brights[4] or yellow
  local bright_blue    = brights[5] or blue
  local bright_magenta = brights[6] or magenta
  local bright_cyan    = brights[7] or cyan

  -- Escape a hex color for JSON
  local function q(s)
    return '"' .. s .. '"'
  end

  local lines = {
    '{',
    '  "$schema": "https://opencode.ai/theme.json",',
    '  "theme": {',
    '    "primary": '              .. q(blue)         .. ',',
    '    "secondary": '            .. q(magenta)      .. ',',
    '    "accent": '               .. q(cyan)         .. ',',
    '    "error": '                .. q(red)          .. ',',
    '    "warning": '              .. q(yellow)       .. ',',
    '    "success": '              .. q(green)        .. ',',
    '    "info": '                 .. q(cyan)         .. ',',
    '    "text": '                 .. q(fg_hex)       .. ',',
    '    "textMuted": '            .. q(gray[5])      .. ',',
    '    "background": "none",',
    '    "backgroundPanel": "none",',
    '    "backgroundElement": '    .. q(gray[2])      .. ',',
    '    "border": '               .. q(gray[3])      .. ',',
    '    "borderActive": '         .. q(gray[5])      .. ',',
    '    "borderSubtle": '         .. q(gray[2])      .. ',',
    '    "diffAdded": '            .. q(green)        .. ',',
    '    "diffRemoved": '          .. q(red)          .. ',',
    '    "diffContext": '          .. q(gray[4])      .. ',',
    '    "diffHunkHeader": '       .. q(gray[4])      .. ',',
    '    "diffHighlightAdded": '   .. q(bright_green) .. ',',
    '    "diffHighlightRemoved": ' .. q(bright_red)   .. ',',
    '    "diffAddedBg": "none",',
    '    "diffRemovedBg": "none",',
    '    "diffContextBg": "none",',
    '    "diffLineNumber": '       .. q(gray[3])      .. ',',
    '    "diffAddedLineNumberBg": "none",',
    '    "diffRemovedLineNumberBg": "none",',
    '    "markdownText": '         .. q(fg_hex)       .. ',',
    '    "markdownHeading": '      .. q(blue)         .. ',',
    '    "markdownLink": '         .. q(cyan)         .. ',',
    '    "markdownLinkText": '     .. q(bright_cyan)  .. ',',
    '    "markdownCode": '         .. q(green)        .. ',',
    '    "markdownBlockQuote": '   .. q(gray[5])      .. ',',
    '    "markdownEmph": '         .. q(yellow)       .. ',',
    '    "markdownStrong": '       .. q(bright_yellow) .. ',',
    '    "markdownHorizontalRule": ' .. q(gray[3])    .. ',',
    '    "markdownListItem": '     .. q(blue)         .. ',',
    '    "markdownListEnumeration": ' .. q(cyan)      .. ',',
    '    "markdownImage": '        .. q(magenta)      .. ',',
    '    "markdownImageText": '    .. q(bright_blue)  .. ',',
    '    "markdownCodeBlock": '    .. q(fg_hex)       .. ',',
    '    "syntaxComment": '        .. q(gray[5])         .. ',',
    '    "syntaxKeyword": '        .. q(bright_magenta)  .. ',',
    '    "syntaxFunction": '       .. q(bright_blue)     .. ',',
    '    "syntaxVariable": '       .. q(bright_cyan)     .. ',',
    '    "syntaxString": '         .. q(bright_green)    .. ',',
    '    "syntaxNumber": '         .. q(bright_yellow)   .. ',',
    '    "syntaxType": '           .. q(bright_cyan)     .. ',',
    '    "syntaxOperator": '       .. q(bright_blue)     .. ',',
    '    "syntaxPunctuation": '    .. q(fg_hex),
    '  }',
    '}',
  }
  return table.concat(lines, "\n")
end

-- Ensure the themes directory exists.
local function ensure_theme_dir()
  if is_windows then
    os.execute('mkdir "' .. THEME_DIR:gsub("/", "\\") .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. THEME_DIR .. '"')
  end
end

-- Write the feb theme JSON file based on current WezTerm scheme and
-- system appearance.
function M.write_theme(appearance)
  local colors = theme.get_colors()
  if not colors then
    wezterm.log_error("opencode_theme: could not get theme colors")
    return
  end

  local is_dark = true
  if appearance then
    is_dark = appearance:find("Dark") ~= nil
  end

  local json = build_theme_json(colors, is_dark)

  ensure_theme_dir()
  local f = io.open(THEME_FILE, "w")
  if not f then
    wezterm.log_error("opencode_theme: cannot write " .. THEME_FILE)
    return
  end
  f:write(json)
  f:close()
end

-- Called once at config load time to generate the initial theme file.
function M.sync()
  local changed, hash = theme_changed()
  if not changed then return end
  -- At config load time we don't have a window yet, so we can't call
  -- get_appearance(). Default to dark; the window-config-reloaded event
  -- will correct it immediately once a window exists.
  M.write_theme(nil)
  if hash then save_hash(hash) end
end

-- Call this from a window-config-reloaded event handler to keep the
-- theme in sync with system appearance changes.
function M.on_reload(window)
  local changed, hash = theme_changed()
  if not changed then return end
  local appearance = window:get_appearance()
  M.write_theme(appearance)
  if hash then save_hash(hash) end
end

return M
