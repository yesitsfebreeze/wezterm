local wezterm = require("wezterm")

local M = {}

function M.toggle(win, pane)
  local tab = pane:tab()
  local panes = tab:panes_with_info()
  if #panes > 1 then
    local main = panes[1]
    if main.is_zoomed then
      win:perform_action(wezterm.action.TogglePaneZoomState, main.pane)
      panes[2].pane:activate()
    else
      main.pane:activate()
      win:perform_action(wezterm.action.TogglePaneZoomState, main.pane)
    end
  else
    win:perform_action(wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }), pane)
  end
end

return M
