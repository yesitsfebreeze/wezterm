local wezterm = require("wezterm")

local M = {}

local THEME = "Gooey (Gogh)"
local CURSOR = "#F3A246"
local BG = "#19191f"
local OPACITY = 0.7
local STATE_FILE = wezterm.config_dir .. "/.image"

local function read_saved_image()
  local f = io.open(STATE_FILE, "r")
  if not f then return nil end
  local path = f:read("*l")
  f:close()
  return (path and path ~= "") and path or nil
end

local function save_image(path)
  local f = io.open(STATE_FILE, "w")
  if not f then return end
  f:write(path)
  f:close()
end

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = deep_copy(v) end
  return out
end

local function deep_merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      deep_merge(dst[k], v)
    else
      dst[k] = deep_copy(v)
    end
  end
  return dst
end

function M.build_background(image_path)
  return {
    { width = "100%", height = "100%", opacity = OPACITY * OPACITY, source = { Color = BG } },
    { source = { File = image_path }, opacity = OPACITY },
    { width = "100%", height = "100%", opacity = OPACITY, source = { Color = BG } },
  }
end

function M.get_images()
  local images = {}
  for _, entry in ipairs(wezterm.glob(wezterm.config_dir .. "/images/*")) do
    if entry:lower():match("%.png$") or entry:lower():match("%.jpe?g$")
      or entry:lower():match("%.gif$") or entry:lower():match("%.bmp$")
      or entry:lower():match("%.webp$") then
      table.insert(images, entry)
    end
  end
  table.sort(images)
  return images
end

function M.apply_to_config(config)
  config.term = "xterm-256color"
  config.default_cursor_style = "BlinkingBlock"
  config.animation_fps = 1
  config.cursor_blink_rate = 0
  config.audible_bell = "Disabled"
  config.scrollback_lines = 3500
  config.enable_scroll_bar = false
  config.window_decorations = "RESIZE"

  config.font_dirs = { wezterm.config_dir .. "/fonts" }
  config.font = wezterm.font("DepartureMono Nerd Font Mono")
  if wezterm.target_triple:match("darwin") then
    config.font = wezterm.font("Departure Mono")
  end
  config.font_size = 13
  config.line_height = 1.01

  config.window_padding = { left = 11, right = 7, top = 7, bottom = 0 }

  config.enable_tab_bar = true
  config.use_fancy_tab_bar = false
  config.tab_bar_at_bottom = false
  config.show_new_tab_button_in_tab_bar = false
  config.tab_max_width = 0

  local colors = deep_copy(wezterm.color.get_builtin_schemes()[THEME])
  colors.cursor_bg = CURSOR
  colors.cursor_border = CURSOR
  colors.background = BG

  deep_merge(colors, {
    tab_bar = {
      background = "transparent",
      active_tab = { bg_color = BG, fg_color = CURSOR, intensity = "Bold" },
      inactive_tab = { bg_color = "transparent", fg_color = colors.foreground },
      inactive_tab_hover = { bg_color = "transparent", fg_color = CURSOR },
      new_tab = { bg_color = "transparent", fg_color = colors.foreground },
      new_tab_hover = { bg_color = "transparent", fg_color = CURSOR },
    },
  })

  config.colors = colors

  local images = M.get_images()
  local current = read_saved_image() or images[1] or (wezterm.config_dir .. "/images/bg1.png")
  config.background = M.build_background(current)
end

function M.cycle_background(window)
  local images = M.get_images()
  if #images == 0 then return end

  local current = read_saved_image() or ""
  local next_index = 1
  for i, img in ipairs(images) do
    if img == current then
      next_index = (i % #images) + 1
      break
    end
  end

  local next_image = images[next_index]
  save_image(next_image)
  local overrides = window:get_config_overrides() or {}
  overrides.background = M.build_background(next_image)
  window:set_config_overrides(overrides)
end

return M
