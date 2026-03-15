local wezterm = require("wezterm")

local M = {}

local is_windows = os.getenv("OS") == "Windows_NT"

local CONTAINER_NAME = "wezterm-dev"
local IMAGE_NAME = "wezterm-dev:latest"
local DOCKERFILE_DIR = wezterm.config_dir
local HOST_USER = is_windows and os.getenv("USERNAME") or os.getenv("USER")

-- Resolve all paths in Lua so we don't rely on shell variable expansion
local home_dir = wezterm.home_dir
local ssh_dir = home_dir .. (is_windows and "\\.ssh" or "/.ssh")
local gitconfig = home_dir .. (is_windows and "\\.gitconfig" or "/.gitconfig")

-- Convert Windows backslash paths to forward slashes for Docker
local function docker_path(path)
  return path:gsub("\\", "/")
end

-- Extract the directory name from a path for the container mount point
local function dir_name(path)
  local p = docker_path(path)
  return p:match("([^/]+)$") or "workspace"
end

-- Run a command via run_child_process; returns success, stdout
local function run_cmd(...)
  local ok, stdout, stderr = wezterm.run_child_process({ ... })
  return ok, (stdout or "")
end

-- Ensure the Docker image is built
local function ensure_image()
  local ok = run_cmd("docker", "image", "inspect", IMAGE_NAME)
  if not ok then
    wezterm.log_info("docker: building image " .. IMAGE_NAME)
    run_cmd("docker", "build", "--progress=plain",
      "--build-arg", "USERNAME=" .. HOST_USER,
      "-t", IMAGE_NAME, docker_path(DOCKERFILE_DIR))
  end
end

-- Ensure the container is running with the given host_dir mounted
local function ensure_container(host_dir)
  local mount_src = docker_path(host_dir)
  local name = dir_name(host_dir)
  local workdir = "/workspace/" .. name
  local ssh = docker_path(ssh_dir)
  local gc = docker_path(gitconfig)

  -- Check if container is running
  local ok, stdout = run_cmd("docker", "inspect", "-f", "{{.State.Running}}", CONTAINER_NAME)
  local running = ok and stdout:match("true")

  if not running then
    -- Remove stale container if any
    run_cmd("docker", "rm", "-f", CONTAINER_NAME)
    -- Start fresh with volume mounts
    wezterm.log_info("docker: starting container " .. CONTAINER_NAME)
    run_cmd("docker", "run", "-d", "--name", CONTAINER_NAME,
      "-v", mount_src .. ":" .. workdir,
      "-v", ssh .. ":/home/" .. HOST_USER .. "/.ssh:ro",
      "-v", gc .. ":/home/" .. HOST_USER .. "/.gitconfig:ro",
      "--restart", "unless-stopped",
      IMAGE_NAME, "sleep", "infinity")
  else
    -- Container is running; check if our workdir is already mounted
    local dir_ok = run_cmd("docker", "exec", CONTAINER_NAME, "test", "-d", workdir)
    if not dir_ok then
      wezterm.log_info("docker: re-creating container with mount for " .. workdir)
      run_cmd("docker", "stop", CONTAINER_NAME)
      run_cmd("docker", "rm", CONTAINER_NAME)
      run_cmd("docker", "run", "-d", "--name", CONTAINER_NAME,
        "-v", mount_src .. ":" .. workdir,
        "-v", ssh .. ":/home/" .. HOST_USER .. "/.ssh:ro",
        "-v", gc .. ":/home/" .. HOST_USER .. "/.gitconfig:ro",
        "--restart", "unless-stopped",
        IMAGE_NAME, "sleep", "infinity")
    end
  end

  return workdir
end

-- Get the current working directory from a pane
local function pane_cwd(pane)
  local cwd_uri = pane:get_current_working_dir()
  if cwd_uri then
    local path = cwd_uri.file_path
    -- file_path returns URI-style "/C:/..." on Windows; strip the leading slash
    if is_windows then
      path = path:gsub("^/(%a:)", "%1")
    end
    return path
  end
  return wezterm.home_dir
end

-- Send a command to the pane
local function send_command(pane, cmd)
  pane:send_text(cmd .. "\r")
end

-- Check if the pane is currently inside a docker exec session
local function is_in_docker(pane)
  local proc = pane:get_foreground_process_name() or ""
  return proc:find("docker") ~= nil
end

-- Apply container-related config (default shell is a normal shell)
function M.apply_to_config(config)
  if is_windows then
    local shell_integration = wezterm.config_dir .. "\\conf\\shell-integration.ps1"
    config.default_prog = { "pwsh.exe", "-NoLogo", "-NoExit", "-File", shell_integration }
  end
end


-- Toggle: if in docker, exit; if not, exec into docker
function M.mount_current_dir(win, pane)
	if is_in_docker(pane) then
		send_command(pane, "exit")
		return
	end
	local cwd = pane_cwd(pane)
	ensure_image()
	local workdir = ensure_container(cwd)
	send_command(pane, string.format("docker exec -it -w %s %s zsh", workdir, CONTAINER_NAME))
end

function M.force_rebuild(win, pane)
	run_cmd("docker", "stop", CONTAINER_NAME)
	run_cmd("docker", "rm", CONTAINER_NAME)
	run_cmd("docker", "rmi", IMAGE_NAME)
	local cwd = pane_cwd(pane)
	ensure_image()
	local workdir = ensure_container(cwd)
	send_command(pane, string.format("docker exec -it -w %s %s zsh", workdir, CONTAINER_NAME))
end

return M
