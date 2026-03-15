local wezterm = require("wezterm")

local M = {}

local VERSION = "1"
local STAMP_FILE = wezterm.config_dir .. (os.getenv("OS") == "Windows_NT" and "\\" or "/") .. ".bootstrap"

local dependencies = {
	{
		name = 'zoxide',
		win = 'winget install --accept-source-agreements --accept-package-agreements -e ajeetdsouza.zoxide',
		mac = 'brew install zoxide',
		linux = 'curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh'
	},
	{
		name = 'docker',
		win = 'winget install --accept-source-agreements --accept-package-agreements -e Docker.DockerDesktop',
		mac = 'brew install --cask docker',
		linux = 'curl -fsSL https://get.docker.com | sh'
	},
}

local is_windows = os.getenv("OS") == "Windows_NT"
local is_mac = (function()
  local ok, stdout = pcall(function()
    local _, s = wezterm.run_child_process({ "uname", "-s" })
    return s
  end)
  return ok and stdout and stdout:match("Darwin") ~= nil
end)()

local function read_stamp()
  local f = io.open(STAMP_FILE, "r")
  if not f then return nil end
  local v = f:read("*l")
  f:close()
  return v
end

local function write_stamp()
  local f = io.open(STAMP_FILE, "w")
  if f then
    f:write(VERSION)
    f:close()
  end
end

local function has_command(name)
  if is_windows then
    local ok, _, stderr = wezterm.run_child_process({ "cmd.exe", "/c", "where " .. name })
    return ok and (stderr == nil or stderr == "")
  else
    local ok = wezterm.run_child_process({ "sh", "-c", "command -v " .. name })
    return ok
  end
end

function M.run()
  local current = read_stamp()
  if current == VERSION then
    return
  end
  wezterm.log_info("bootstrap: updating from v" .. (current or "none") .. " to v" .. VERSION)
  
	for _, dep in ipairs(dependencies) do
		if has_command(dep.name) then
			wezterm.log_info("bootstrap: " .. dep.name .. " already installed")
			return
		end
		wezterm.log_info("bootstrap: installing " .. dep.name .. "...")
		if is_windows then
			wezterm.run_child_process({ dep.win })
		elseif is_mac then
			wezterm.run_child_process({ dep.mac })
		else
			wezterm.run_child_process({ dep.linux })
		end
	end
			
  write_stamp()
  wezterm.log_info("bootstrap: done (v" .. VERSION .. ")")
end

return M
