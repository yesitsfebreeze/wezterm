local wezterm = require("wezterm")
local bootstrap = require("conf.bootstrap")
local docker = require("conf.docker")
local split = require("conf.split")
local theme = require("conf.theme")


bootstrap.run()

local act = wezterm.action
local config = wezterm.config_builder()
local mux = wezterm.mux

local is_windows = os.getenv("OS") == "Windows_NT"

config.window_close_confirmation = "NeverPrompt"

theme.apply_to_config(config)
docker.apply_to_config(config)

wezterm.on("gui-attached", function()
  local window = mux.all_windows()[1]
  if window then
    window:gui_window():maximize()
  end
end)



wezterm.on("format-tab-title", function(tab, tabs, panes, config, hover, max_width)
  return { { Text = "" } }
end)


local workspace_switcher = wezterm.plugin.require("https://github.com/MLFlexer/smart_workspace_switcher.wezterm")
workspace_switcher.zoxide_path = "zoxide"

-- print tab indicators and workspace name at the upper right (registered after plugin to take priority)
wezterm.on("update-right-status", function(window, pane)
  local mux_win = window:mux_window()
  local tabs = mux_win:tabs()
  local active_id = window:active_tab():tab_id()

  -- Left status: current working directory
  local cwd = pane:get_current_working_dir()
  local dir = ""
  if cwd then
    dir = cwd.file_path or ""
    -- On Windows strip leading slash from /C:/...
    if is_windows then
      dir = dir:gsub("^/(%a:)", "%1")
    end
  end
  window:set_left_status(wezterm.format({
    { Foreground = { Color = "#6272a4" } },
    { Text = " " .. dir .. " " },
  }))

  -- Right status: tab indicators + workspace
  local cells = {}
  for i, tab in ipairs(tabs) do
    if tab:tab_id() == active_id then
      table.insert(cells, { Foreground = { Color = "#50fa7b" } })
    else
      table.insert(cells, { Foreground = { Color = "#6272a4" } })
    end
    table.insert(cells, { Text = tostring(i) })
  end

  table.insert(cells, { Foreground = { Color = "#6272a4" } })
  table.insert(cells, { Text = "  " .. window:active_workspace() .. " " })

  window:set_right_status(wezterm.format(cells))
end)

---------------------------------------------------------------------------
-- Keymaps
---------------------------------------------------------------------------
local keys = {
  { key = "d", mods = "CTRL|SHIFT", action = wezterm.action_callback(docker.mount_current_dir) },
  { key = "b", mods = "CTRL|SHIFT", action = wezterm.action_callback(docker.force_rebuild) },
  { key = "Tab", mods = "SHIFT", action = wezterm.action_callback(split.toggle) },

  { key = "s", mods = "CTRL|SHIFT", action = workspace_switcher.switch_workspace() },
  { key = "r", mods = "CTRL|SHIFT", action = act.ShowLauncherArgs({ flags = "FUZZY|WORKSPACES" }) },
  { key = "[", mods = "CTRL|SHIFT", action = act.SwitchWorkspaceRelative(1) },
  { key = "]", mods = "CTRL|SHIFT", action = act.SwitchWorkspaceRelative(-1) },
  { key = "p", mods = "CTRL|SHIFT", action = wezterm.action_callback(function(window) theme.cycle_background(window) end) },
}

config.keys = keys
return config
