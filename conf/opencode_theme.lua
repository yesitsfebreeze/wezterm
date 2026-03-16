-- Minimal opencode theme integration.
-- The theme file at dotfiles/.config/opencode/themes/wezterm.json
-- simply sets "background": "none" so opencode inherits the terminal
-- background. No dynamic generation needed.

local M = {}

function M.sync()
  -- nothing to do — the static theme file handles everything
end

return M
