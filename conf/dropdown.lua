local wezterm = require("wezterm")

local M = {}

local SIZE = 0.3
local dropdown_panes = {} -- tab_id -> pane_id

local function get_pane_cwd(pane)
  local cwd_uri = pane:get_current_working_dir()
  if cwd_uri then
    local path = cwd_uri.file_path
    if (os.getenv("OS") == "Windows_NT") then
      path = path:gsub("^/(%a:)", "%1")
    end
    return path
  end
  return nil
end

local function find_dropdown(tab)
  local tab_id = tab:tab_id()
  local dd_id = dropdown_panes[tab_id]
  if not dd_id then return nil end

  for _, info in ipairs(tab:panes_with_info()) do
    if info.pane:pane_id() == dd_id then
      return info
    end
  end

  -- dropdown pane was closed externally
  dropdown_panes[tab_id] = nil
  return nil
end

function M.toggle(win, pane)
  local tab = pane:tab()
  local tab_id = tab:tab_id()
  local panes = tab:panes_with_info()
  local dd_info = find_dropdown(tab)
  local is_zoomed = panes[1] and panes[1].is_zoomed

  if dd_info then
    -- dropdown exists
    if is_zoomed then
      if pane:pane_id() == dd_info.pane:pane_id() then
        -- dropdown is zoomed (visible full-screen), unzoom to show all panes
        win:perform_action(wezterm.action.TogglePaneZoomState, pane)
      else
        -- a non-dropdown pane is zoomed (dropdown hidden), unzoom to reveal dropdown
        win:perform_action(wezterm.action.TogglePaneZoomState, pane)
        dd_info.pane:activate()
      end
    else
      -- dropdown is visible, hide it by zooming a non-dropdown pane
      for _, info in ipairs(panes) do
        if info.pane:pane_id() ~= dd_info.pane:pane_id() then
          info.pane:activate()
          win:perform_action(wezterm.action.TogglePaneZoomState, info.pane)
          return
        end
      end
    end
  else
    -- no dropdown exists, create one
    if is_zoomed then
      win:perform_action(wezterm.action.TogglePaneZoomState, pane)
    end

    local cwd = get_pane_cwd(pane)
    local opts = { direction = "Top", size = SIZE }
    if cwd then opts.cwd = cwd end

    local new_pane = pane:split(opts)
    dropdown_panes[tab_id] = new_pane:pane_id()
  end
end

return M
