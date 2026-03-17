local wezterm = require("wezterm")

local is_windows = os.getenv("OS") == "Windows_NT"

local M = {}

function M.run(args)
  if type(args) == "string" then
    if is_windows then
      return wezterm.run_child_process({ "cmd.exe", "/c", args })
    else
      return wezterm.run_child_process({ "sh", "-c", args })
    end
  end
  return wezterm.run_child_process(args)
end

return M
