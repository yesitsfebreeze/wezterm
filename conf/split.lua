local wezterm = require("wezterm")

local M = {}

local last_pane_id = nil

function M.create_layout(tab)
  local panes = tab:panes_with_info()
  if #panes >= 3 then return end

  if #panes == 1 then
    panes[1].pane:split({ direction = "Right", size = 0.67 })
    panes = tab:panes_with_info()
  end

  if #panes == 2 then
    panes[2].pane:split({ direction = "Right", size = 0.5 })
    panes = tab:panes_with_info()
  end

  if #panes >= 3 then
    panes[2].pane:activate()
  end
end

function M.toggle(win, pane)
  local tab = pane:tab()
  local panes = tab:panes_with_info()
  
  local is_zoomed = panes[1] and panes[1].is_zoomed
  
  if is_zoomed then
    win:perform_action(wezterm.action.TogglePaneZoomState, pane)
    return
  end
  
  if #panes < 3 then
    local current_id = pane:pane_id()
    M.create_layout(tab)
    
    local new_panes = tab:panes_with_info()
    if #new_panes == 3 then
      local idx_to_activate = 1
      for i, info in ipairs(new_panes) do
        if info.pane:pane_id() == current_id then
          idx_to_activate = i % 3 + 1
          break
        end
      end
      new_panes[idx_to_activate].pane:activate()
    end
    last_pane_id = current_id
  else
    local current = pane:pane_id()
    local current_idx = nil
    
    for i, info in ipairs(panes) do
      if info.pane:pane_id() == current then
        current_idx = i
        break
      end
    end
    
    if current_idx then
      local next_idx = (current_idx % #panes) + 1
      panes[next_idx].pane:activate()
      last_pane_id = current
    end
  end
end

function M.toggle_zoom(win, pane)
  win:perform_action(wezterm.action.TogglePaneZoomState, pane)
end

return M
