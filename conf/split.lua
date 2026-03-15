local wezterm = require("wezterm")

local M = {}

function M.toggle(win, pane)
  local tab = pane:tab()
  local panes = tab:panes_with_info()
  if #panes > 1 then
    local main_pane = panes[1].pane
    local is_zoomed = panes[1].is_zoomed
    if is_zoomed then
      win:perform_action(wezterm.action.TogglePaneZoomState, main_pane)
      panes[2].pane:activate()
    else
      main_pane:activate()
      win:perform_action(wezterm.action.TogglePaneZoomState, main_pane)
    end
  else
    win:perform_action(wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }), pane)
  end
end

return M
