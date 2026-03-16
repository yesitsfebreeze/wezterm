local wezterm = require("wezterm")

local M = {}

local VERSION = "1"
local SEP = os.getenv("OS") == "Windows_NT" and "\\" or "/"
local CACHE_DIR = wezterm.config_dir .. SEP .. ".cache"
local STAMP_FILE = CACHE_DIR .. SEP .. "bootstrap"
local is_windows = os.getenv("OS") == "Windows_NT"

local is_mac = (function()
  local ok, stdout = pcall(function()
    local _, s = wezterm.run_child_process({ "uname", "-s" })
    return s
  end)
  return ok and stdout and stdout:match("Darwin") ~= nil
end)()

local dependencies = {
  {
    name = "zoxide",
    win = "winget install --accept-source-agreements --accept-package-agreements -e ajeetdsouza.zoxide",
    mac = "brew install zoxide",
    linux = "curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh",
  },
  {
    name = "docker",
    win = "winget install --accept-source-agreements --accept-package-agreements -e Docker.DockerDesktop",
    mac = "brew install --cask docker",
    linux = "curl -fsSL https://get.docker.com | sh",
  },
}

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
  local f = io.open(STAMP_FILE, "r")
  local current = f and f:read("*l")
  if f then f:close() end
  if current == VERSION then return end

  for _, dep in ipairs(dependencies) do
    if not has_command(dep.name) then
      local cmd = (is_windows and dep.win) or (is_mac and dep.mac) or dep.linux
      wezterm.run_child_process({ cmd })
    end
  end

  if is_windows then
    os.execute('mkdir "' .. CACHE_DIR:gsub("/", "\\") .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. CACHE_DIR .. '"')
  end
  f = io.open(STAMP_FILE, "w")
  if f then f:write(VERSION); f:close() end
end

return M
