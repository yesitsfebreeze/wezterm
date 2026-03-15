local wezterm = require("wezterm")
local bootstrap = require("conf.bootstrap")
local docker = require("conf.docker")
local split = require("conf.split")
local theme = require("conf.theme")

bootstrap.run()

local act = wezterm.action
local config = wezterm.config_builder()
local is_windows = os.getenv("OS") == "Windows_NT"

config.window_close_confirmation = "NeverPrompt"
theme.apply_to_config(config)
docker.apply_to_config(config)

wezterm.on("gui-attached", function()
  local window = wezterm.mux.all_windows()[1]
  if window then window:gui_window():maximize() end
end)

wezterm.on("format-tab-title", function()
  return { { Text = "" } }
end)

wezterm.on("update-right-status", function(window, pane)
  local tabs = window:mux_window():tabs()
  local active_id = window:active_tab():tab_id()

  if docker.recent_picker_active then
    window:set_left_status(wezterm.format({
      { Foreground = { Color = "#6272a4" } },
      { Text = " Recent: " },
    }))
  else
    local in_docker = docker.is_in_docker(pane)
    local left = in_docker
      and {
        { Foreground = { Color = "#000000" } },
        { Background = { Color = "#F3A246" } },
        { Attribute = { Intensity = "Bold" } },
        { Text = " D " },
        { Attribute = { Intensity = "Normal" } },
        { Background = { Color = "transparent" } },
      }
      or {
        { Foreground = { Color = "#F3A246" } },
        { Attribute = { Intensity = "Bold" } },
        { Text = " L " },
        { Attribute = { Intensity = "Normal" } },
      }

    local dir = ""
    if in_docker then
      dir = docker.get_docker_workdir(pane) or ""
    else
      local cwd = pane:get_current_working_dir()
      if cwd then
        dir = cwd.file_path or ""
        if is_windows then dir = dir:gsub("^/(%a:)", "%1") end
      end
    end

    table.insert(left, { Foreground = { Color = "#6272a4" } })
    table.insert(left, { Text = " " .. dir .. " " })
    window:set_left_status(wezterm.format(left))
  end

  local cells = {}
  for i, tab in ipairs(tabs) do
    local color = tab:tab_id() == active_id and "#50fa7b" or "#6272a4"
    table.insert(cells, { Foreground = { Color = color } })
    table.insert(cells, { Text = tostring(i) })
  end
  table.insert(cells, { Foreground = { Color = "#6272a4" } })
  table.insert(cells, { Text = "  " .. wezterm.strftime("%H:%M") .. " " })
  window:set_right_status(wezterm.format(cells))
end)

config.keys = {
  { key = "d", mods = "CTRL|SHIFT", action = wezterm.action_callback(docker.mount_current_dir) },
  { key = "b", mods = "CTRL|SHIFT", action = wezterm.action_callback(docker.force_rebuild) },
  { key = "Tab", mods = "SHIFT", action = wezterm.action_callback(split.toggle) },
  { key = "s", mods = "CTRL|SHIFT", action = wezterm.action_callback(docker.show_recent) },
  { key = "t", mods = "CTRL|SHIFT", action = wezterm.action_callback(docker.new_tab_recent) },
  { key = "p", mods = "CTRL|SHIFT", action = wezterm.action_callback(function(w) theme.cycle_background(w) end) },
  { key = "v", mods = "CTRL", action = act.PasteFrom("Clipboard") },
}

return config
