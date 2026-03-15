local wezterm = require("wezterm")

local M = {}

local is_windows = os.getenv("OS") == "Windows_NT"

local CONTAINER_NAME = "capsule"
local IMAGE_NAME = "capsule:latest"
local DOCKERFILE_DIR = wezterm.config_dir
local HOST_USER = is_windows and os.getenv("USERNAME") or os.getenv("USER")
local RECENT_FILE = wezterm.config_dir .. (is_windows and "\\.recent" or "/.recent")
local MAX_RECENT = 20

M.recent_picker_active = false

-- Track the Docker workdir per pane (pane_id -> workdir)
local docker_workdirs = {}

-- In-memory caches to avoid repeated docker commands
local container_mounts = {}  -- set of mounted workdirs
local known_users = {}       -- set of users created in container

local DOCKERFILE = DOCKERFILE_DIR .. (is_windows and "\\Dockerfile" or "/Dockerfile")
local BUILD_STAMP = wezterm.config_dir .. (is_windows and "\\.docker_build" or "/.docker_build")

-- Resolve all paths in Lua so we don't rely on shell variable expansion
local home_dir = wezterm.home_dir
local ssh_dir = home_dir .. (is_windows and "\\.ssh" or "/.ssh")
local gitconfig = home_dir .. (is_windows and "\\.gitconfig" or "/.gitconfig")
local user_dir = wezterm.config_dir .. (is_windows and "\\user" or "/user")

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
  local args = { ... }
  local ok, stdout, stderr = wezterm.run_child_process(args)
  if not ok and stderr and stderr ~= "" then
    wezterm.log_error("docker: cmd failed: " .. table.concat(args, " ") .. " stderr: " .. stderr)
  end
  return ok, (stdout or "")
end

-- Get file modification time as a comparable string
local function file_mtime(path)
  local ok, stdout
  if is_windows then
    ok, stdout = run_cmd("powershell.exe", "-NoProfile", "-Command",
      "(Get-Item '" .. path .. "').LastWriteTimeUtc.Ticks")
  else
    ok, stdout = run_cmd("stat", "-c", "%Y", path)
  end
  if ok and stdout then return stdout:match("^%s*(.-)%s*$") end
  return nil
end

-- Read the build stamp
local function read_build_stamp()
  local f = io.open(BUILD_STAMP, "r")
  if not f then return nil end
  local v = f:read("*l")
  f:close()
  return v
end

-- Write the build stamp with current Dockerfile mtime
local function write_build_stamp(mtime)
  local f = io.open(BUILD_STAMP, "w")
  if f then
    f:write(mtime)
    f:close()
  end
end

-- Build the Docker image
local function build_image()
  wezterm.log_info("docker: building image " .. IMAGE_NAME)
  run_cmd("docker", "build",
    "-f", docker_path(DOCKERFILE),
    "--build-arg", "USERNAME=" .. HOST_USER,
    "-t", IMAGE_NAME, docker_path(DOCKERFILE_DIR))
end

-- Ensure the Docker image is built and up-to-date
local function ensure_image()
  local mtime = file_mtime(DOCKERFILE)
  local stamp = read_build_stamp()

  if mtime and stamp and mtime == stamp then
    wezterm.log_info("docker: image up-to-date (stamp matches)")
    return
  end

  -- Check if image exists at all
  local ok = run_cmd("docker", "image", "inspect", IMAGE_NAME)
  if not ok or (mtime and mtime ~= stamp) then
    if mtime and mtime ~= stamp then
      wezterm.log_info("docker: Dockerfile changed, rebuilding")
      -- Remove old image to force clean build
      run_cmd("docker", "stop", CONTAINER_NAME)
      run_cmd("docker", "rm", CONTAINER_NAME)
      run_cmd("docker", "rmi", IMAGE_NAME)
      container_mounts = {}
      known_users = {}
    end
    build_image()
  else
    wezterm.log_info("docker: image exists")
  end

  if mtime then write_build_stamp(mtime) end
end

-- Ensure the container is running with the given host_dir mounted
local function ensure_container(host_dir)
  local mount_src = docker_path(host_dir)
  local name = dir_name(host_dir)
  local workdir = "/workspace/" .. name
  local ssh = docker_path(ssh_dir)
  local gc = docker_path(gitconfig)

  -- If we already mounted this workdir in this session, skip all checks
  if container_mounts[workdir] then
    wezterm.log_info("docker: mount cached for " .. workdir .. ", skipping")
    return workdir
  end

  -- Check if container is running
  wezterm.log_info("docker: inspecting container " .. CONTAINER_NAME)
  local ok, stdout = run_cmd("docker", "inspect", "-f", "{{.State.Running}}", CONTAINER_NAME)
  local running = ok and stdout:match("true")

  if not running then
    wezterm.log_info("docker: container not running, removing stale")
    run_cmd("docker", "rm", "-f", CONTAINER_NAME)
    wezterm.log_info("docker: starting container " .. CONTAINER_NAME)
    local started = run_cmd("docker", "run", "-d", "--name", CONTAINER_NAME,
      "-v", mount_src .. ":" .. workdir,
      "-v", ssh .. ":/home/" .. HOST_USER .. "/.ssh:ro",
      "-v", gc .. ":/home/" .. HOST_USER .. "/.gitconfig:ro",
      "-v", docker_path(user_dir) .. ":/etc/skel:ro",
      "--restart", "unless-stopped",
      IMAGE_NAME, "sleep", "infinity")
    if not started then
      wezterm.log_error("docker: failed to start container")
      return nil
    end
    container_mounts = {}
    known_users = {}
  else
    wezterm.log_info("docker: container running, checking mount for " .. workdir)
    local dir_ok = run_cmd("docker", "exec", CONTAINER_NAME, "test", "-d", workdir)
    if not dir_ok then
      wezterm.log_info("docker: re-creating container with mount for " .. workdir)
      run_cmd("docker", "stop", CONTAINER_NAME)
      run_cmd("docker", "rm", CONTAINER_NAME)
      local started = run_cmd("docker", "run", "-d", "--name", CONTAINER_NAME,
        "-v", mount_src .. ":" .. workdir,
        "-v", ssh .. ":/home/" .. HOST_USER .. "/.ssh:ro",
        "-v", gc .. ":/home/" .. HOST_USER .. "/.gitconfig:ro",
        "-v", docker_path(user_dir) .. ":/etc/skel:ro",
        "--restart", "unless-stopped",
        IMAGE_NAME, "sleep", "infinity")
      if not started then
        wezterm.log_error("docker: failed to start container")
        return nil
      end
      container_mounts = {}
      known_users = {}
    end
  end

  container_mounts[workdir] = true
  wezterm.log_info("docker: container ready, workdir=" .. workdir)
  return workdir
end

-- Get the current working directory from a pane
local function pane_cwd(pane)
  local cwd_uri = pane:get_current_working_dir()
  if cwd_uri then
    local path = cwd_uri.file_path
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

-- Ensure a user exists inside the container; create if missing
local function ensure_user(username)
  if known_users[username] then
    wezterm.log_info("docker: user '" .. username .. "' already known, skipping")
    return
  end
  wezterm.log_info("docker: checking user '" .. username .. "'")
  local ok = run_cmd("docker", "exec", CONTAINER_NAME, "id", username)
  if not ok then
    wezterm.log_info("docker: creating user '" .. username .. "'")
    run_cmd("docker", "exec", CONTAINER_NAME, "useradd", "-m", "-s", "/bin/zsh", username)
    run_cmd("docker", "exec", CONTAINER_NAME, "bash", "-c",
      "echo '" .. username .. " ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers")
  else
    wezterm.log_info("docker: user '" .. username .. "' exists")
  end
  known_users[username] = true
end

-- Check if the pane is currently inside a docker exec session
function M.is_in_docker(pane)
  local proc = pane:get_foreground_process_name() or ""
  return proc:find("docker") ~= nil
end

-- Get the Docker workdir for a pane (nil if not in docker)
function M.get_docker_workdir(pane)
  return docker_workdirs[pane:pane_id()]
end

-- Read the recent directories list from .recent file
local function read_recent()
  local f = io.open(RECENT_FILE, "r")
  if not f then return {} end
  local dirs = {}
  for line in f:lines() do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed and trimmed ~= "" then
      table.insert(dirs, trimmed)
    end
  end
  f:close()
  return dirs
end

-- Write the recent directories list to .recent file
local function write_recent(dirs)
  local f = io.open(RECENT_FILE, "w")
  if not f then return end
  for _, d in ipairs(dirs) do
    f:write(d .. "\n")
  end
  f:close()
end

-- Add a directory to the top of the recent list (deduplicating)
local function add_recent(dir)
  local dirs = read_recent()
  local new = { dir }
  for _, d in ipairs(dirs) do
    if d ~= dir then
      table.insert(new, d)
    end
  end
  while #new > MAX_RECENT do
    table.remove(new)
  end
  write_recent(new)
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
  wezterm.log_info("docker: mount_current_dir called")
  if M.is_in_docker(pane) then
    wezterm.log_info("docker: already in docker, exiting")
    docker_workdirs[pane:pane_id()] = nil
    send_command(pane, "exit")
    return
  end
  local cwd = pane_cwd(pane)
  wezterm.log_info("docker: cwd=" .. cwd)
  ensure_image()
  local workdir = ensure_container(cwd)
  if not workdir then
    wezterm.log_error("docker: ensure_container failed, aborting")
    return
  end
  wezterm.log_info("docker: adding to recent")
  add_recent(cwd)
  docker_workdirs[pane:pane_id()] = workdir
  local user = dir_name(cwd)
  ensure_user(user)
  local cmd = string.format("docker exec -it -u %s -w %s %s zsh", user, workdir, CONTAINER_NAME)
  wezterm.log_info("docker: exec command: " .. cmd)
  send_command(pane, cmd)
end

-- Connect to docker with an arbitrary host directory
local function docker_connect(pane, host_dir)
  wezterm.log_info("docker: docker_connect called for " .. host_dir)
  ensure_image()
  local workdir = ensure_container(host_dir)
  if not workdir then
    wezterm.log_error("docker: ensure_container failed, aborting")
    return
  end
  wezterm.log_info("docker: adding to recent")
  add_recent(host_dir)
  docker_workdirs[pane:pane_id()] = workdir
  local user = dir_name(host_dir)
  ensure_user(user)
  local cmd = string.format("docker exec -it -u %s -w %s %s zsh", user, workdir, CONTAINER_NAME)
  wezterm.log_info("docker: exec command: " .. cmd)
  send_command(pane, cmd)
end

-- Show recent Docker directories as a selector
function M.show_recent(win, pane)
  local dirs = read_recent()
  if #dirs == 0 then
    wezterm.log_info("docker: no recent directories")
    return
  end

  local choices = {}
  for _, d in ipairs(dirs) do
    table.insert(choices, { label = d })
  end

  M.recent_picker_active = true

  win:perform_action(
    wezterm.action.InputSelector({
      title = "",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(inner_win, inner_pane, id, label)
        M.recent_picker_active = false
        inner_win:perform_action(wezterm.action.EmitEvent("update-right-status"), inner_pane)
        if label then
          if M.is_in_docker(inner_pane) then
            docker_workdirs[inner_pane:pane_id()] = nil
            send_command(inner_pane, "exit")
            wezterm.sleep_ms(500)
          end
          docker_connect(inner_pane, label)
        end
      end),
    }),
    pane
  )
end

-- Show recent directories and open a new tab in the selected one
function M.new_tab_recent(win, pane)
  local dirs = read_recent()
  if #dirs == 0 then
    wezterm.log_info("docker: no recent directories")
    return
  end

  local choices = {}
  for _, d in ipairs(dirs) do
    table.insert(choices, { label = d })
  end

  M.recent_picker_active = true

  win:perform_action(
    wezterm.action.InputSelector({
      title = "",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(inner_win, inner_pane, id, label)
        M.recent_picker_active = false
        inner_win:perform_action(wezterm.action.EmitEvent("update-right-status"), inner_pane)
        if label then
          inner_win:perform_action(
            wezterm.action.SpawnCommandInNewTab({
              cwd = label,
            }),
            inner_pane
          )
        end
      end),
    }),
    pane
  )
end

function M.force_rebuild(win, pane)
  run_cmd("docker", "stop", CONTAINER_NAME)
  run_cmd("docker", "rm", CONTAINER_NAME)
  run_cmd("docker", "rmi", IMAGE_NAME)
  container_mounts = {}
  known_users = {}
  build_image()
  local mtime = file_mtime(DOCKERFILE)
  if mtime then write_build_stamp(mtime) end
  local cwd = pane_cwd(pane)
  local workdir = ensure_container(cwd)
  if not workdir then return end
  local user = dir_name(cwd)
  ensure_user(user)
  send_command(pane, string.format("docker exec -it -u %s -w %s %s zsh", user, workdir, CONTAINER_NAME))
end

return M
