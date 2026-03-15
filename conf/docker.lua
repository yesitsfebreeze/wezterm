local wezterm = require("wezterm")

local M = {}

local is_windows = os.getenv("OS") == "Windows_NT"

local CONTAINER_PREFIX = "capsule"
local IMAGE_NAME = "capsule:latest"
local DOCKERFILE_DIR = wezterm.config_dir
local HOST_USER = is_windows and os.getenv("USERNAME") or os.getenv("USER")
local RECENT_FILE = wezterm.config_dir .. (is_windows and "\\.recent" or "/.recent")
local MAX_RECENT = 20

M.recent_picker_active = false

-- Track the Docker workdir per pane (pane_id -> workdir)
local docker_workdirs = {}

-- In-memory caches to avoid repeated docker commands
local known_containers = {}  -- set of container names known to be running
local known_users = {}       -- container_name -> set of users created

local DOCKERFILE = DOCKERFILE_DIR .. (is_windows and "\\Dockerfile" or "/Dockerfile")
local BUILD_STAMP = wezterm.config_dir .. (is_windows and "\\.docker_build" or "/.docker_build")

-- Resolve all paths in Lua so we don't rely on shell variable expansion
local home_dir = wezterm.home_dir
local ssh_dir = home_dir .. (is_windows and "\\.ssh" or "/.ssh")
local gitconfig = home_dir .. (is_windows and "\\.gitconfig" or "/.gitconfig")
local claude_dir = home_dir .. (is_windows and "\\.claude" or "/.claude")
local claude_json = home_dir .. (is_windows and "\\.claude.json" or "/.claude.json")
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

-- Derive a per-project container name from the host directory
local function container_name(host_dir)
  return CONTAINER_PREFIX .. "-" .. dir_name(host_dir)
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

-- Check if a rebuild is needed (fast: only file I/O + docker image inspect)
-- Returns: needs_rebuild (bool), mtime (string or nil)
local function check_image_state()
  local mtime = file_mtime(DOCKERFILE)
  local stamp = read_build_stamp()

  if mtime and stamp and mtime == stamp then
    wezterm.log_info("docker: stamp matches, checking image exists")
    local ok = run_cmd("docker", "image", "inspect", IMAGE_NAME)
    if ok then
      wezterm.log_info("docker: image up-to-date")
      return false, mtime
    end
    wezterm.log_info("docker: stamp matched but image missing, rebuilding")
    return true, mtime
  end

  if not mtime then
    -- No Dockerfile found; check if image exists at all
    local ok = run_cmd("docker", "image", "inspect", IMAGE_NAME)
    return not ok, nil
  end

  wezterm.log_info("docker: Dockerfile changed or no stamp, rebuild needed")
  return true, mtime
end

-- Build the volume mount arguments shared by both scripts and ensure_container
local function volume_mounts(host_dir)
  local mount_src = docker_path(host_dir)
  local name = dir_name(host_dir)
  local workdir = "/workspace/" .. name
  return {
    mount_src .. ":" .. workdir,
    docker_path(ssh_dir) .. ":/home/" .. HOST_USER .. "/.ssh:ro",
    docker_path(gitconfig) .. ":/home/" .. HOST_USER .. "/.gitconfig:ro",
    docker_path(claude_dir) .. ":/opt/claude-auth/.claude",
    docker_path(claude_json) .. ":/opt/claude-auth/.claude.json",
    docker_path(user_dir) .. ":/etc/skel:ro",
  }
end

-- Generate docker run volume flags as a string for shell scripts
local function volume_flags(host_dir, sep)
  local mounts = volume_mounts(host_dir)
  local parts = {}
  for _, m in ipairs(mounts) do
    table.insert(parts, sep .. '-v "' .. m .. '"')
  end
  return table.concat(parts, " ")
end

-- Shell snippet to set up a user inside the container (works for both bash and powershell)
local function user_setup_script(is_ps)
  local suppress = is_ps and "2>$null | Out-Null" or "2>/dev/null"
  local and_op = is_ps and "\n  " or " && \\\n  "
  local or_op = is_ps and "\nif ($LASTEXITCODE -ne 0) {\n" or " || \\\n  ("
  local or_end = is_ps and "\n}" or ")"

  local check = 'docker exec $CNAME id $UNAME ' .. suppress
  local create = 'docker exec $CNAME useradd -m -s /bin/zsh $UNAME' .. and_op ..
    'docker exec $CNAME bash -c "echo \'$UNAME ALL=(ALL) NOPASSWD:ALL\' >> /etc/sudoers"'
  local setup = 'docker exec $CNAME bash -c "cp -rn /etc/skel/. /home/$UNAME/ 2>/dev/null; ' ..
    'chown -R $UNAME:$UNAME /home/$UNAME/; ' ..
    'ln -sf /opt/claude-auth/.claude /home/$UNAME/.claude; ' ..
    'ln -sf /opt/claude-auth/.claude.json /home/$UNAME/.claude.json"'

  return check .. or_op .. create .. or_end .. "\n" .. setup
end

-- Write a build-and-connect script to a temp file and send it to the pane.
-- All slow operations (docker build, docker run) run in the terminal so the
-- user sees live output and WezTerm's event loop is never blocked.
local function pane_build_and_connect(pane, host_dir, mtime)
  local name = dir_name(host_dir)
  local cname = container_name(host_dir)
  local workdir = "/workspace/" .. name
  local df = docker_path(DOCKERFILE)
  local dd = docker_path(DOCKERFILE_DIR)
  local vflags_ps = volume_flags(host_dir, " `\n  ")
  local vflags_sh = volume_flags(host_dir, " \\\n  ")

  -- Clear caches; the image will be rebuilt
  os.remove(BUILD_STAMP)
  known_containers = {}
  known_users = {}

  if is_windows then
    local script_path = (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp") .. "\\capsule_build.ps1"
    local stamp_write = mtime
      and string.format('\nSet-Content -Path "%s" -Value "%s" -NoNewline', BUILD_STAMP, mtime)
      or ""

    local script = string.format([[
$ErrorActionPreference = 'Continue'
$CNAME = "%s"
$UNAME = "%s"
$WORKDIR = "%s"

Write-Host ""
Write-Host ">>> [capsule] Stopping old container/image..." -ForegroundColor DarkGray
docker stop $CNAME 2>$null | Out-Null
docker rm   $CNAME 2>$null | Out-Null
docker rmi  %s 2>$null | Out-Null

Write-Host ">>> [capsule] Building Docker image..." -ForegroundColor Cyan
docker build -f "%s" --build-arg USERNAME=%s -t %s "%s"
if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host ">>> [capsule] BUILD FAILED. Fix the Dockerfile and press Ctrl+Shift+D to retry." -ForegroundColor Red
  return
}%s

Write-Host ">>> [capsule] Starting container..." -ForegroundColor Cyan
docker run -d --name $CNAME%s --restart unless-stopped %s sleep infinity
if ($LASTEXITCODE -ne 0) {
  Write-Host ">>> [capsule] Failed to start container." -ForegroundColor Red
  return
}

Write-Host ">>> [capsule] Setting up user '$UNAME'..." -ForegroundColor Cyan
docker exec $CNAME id $UNAME 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  docker exec $CNAME useradd -m -s /bin/zsh $UNAME
  docker exec $CNAME bash -c "echo '$UNAME ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers"
}
docker exec $CNAME bash -c "cp -rn /etc/skel/. /home/$UNAME/ 2>$null; chown -R ${UNAME}:$UNAME /home/$UNAME/; ln -sf /opt/claude-auth/.claude /home/$UNAME/.claude; ln -sf /opt/claude-auth/.claude.json /home/$UNAME/.claude.json"

Write-Host ">>> [capsule] Connecting..." -ForegroundColor Green
docker exec -it -u $UNAME -w $WORKDIR $CNAME zsh
]],
      -- variables
      cname, name, workdir,
      -- rmi
      IMAGE_NAME,
      -- build
      df, HOST_USER, IMAGE_NAME, dd,
      -- stamp
      stamp_write,
      -- run
      vflags_ps, IMAGE_NAME
    )

    local f = io.open(script_path, "w")
    if not f then
      wezterm.log_error("docker: failed to write build script to " .. script_path)
      return
    end
    f:write(script)
    f:close()

    pane:send_text("& '" .. script_path .. "'\r")

  else
    -- Unix: write a bash script
    local script_path = "/tmp/capsule_build.sh"
    local stamp_write = mtime
      and string.format("printf '%%s' '%s' > '%s'", mtime, BUILD_STAMP)
      or "true"

    local script = string.format([[
#!/usr/bin/env bash
CNAME="%s"
UNAME="%s"
WORKDIR="%s"

echo ""
echo ">>> [capsule] Stopping old container/image..."
(docker stop "$CNAME"; docker rm "$CNAME"; docker rmi %s) 2>/dev/null || true

echo ">>> [capsule] Building Docker image..."
if ! docker build -f '%s' --build-arg USERNAME=%s -t %s '%s'; then
  echo ""
  echo ">>> [capsule] BUILD FAILED. Fix the Dockerfile and press Ctrl+Shift+D to retry."
  exit 1
fi
%s

echo ">>> [capsule] Starting container..."
docker run -d --name "$CNAME"%s --restart unless-stopped %s sleep infinity || { echo ">>> [capsule] Failed to start container."; exit 1; }

echo ">>> [capsule] Setting up user '$UNAME'..."
docker exec "$CNAME" id "$UNAME" 2>/dev/null || \
  (docker exec "$CNAME" useradd -m -s /bin/zsh "$UNAME" && \
   docker exec "$CNAME" bash -c "echo '$UNAME ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers")
docker exec "$CNAME" bash -c "cp -rn /etc/skel/. /home/$UNAME/ 2>/dev/null; chown -R $UNAME:$UNAME /home/$UNAME/; ln -sf /opt/claude-auth/.claude /home/$UNAME/.claude; ln -sf /opt/claude-auth/.claude.json /home/$UNAME/.claude.json"

echo ">>> [capsule] Connecting..."
docker exec -it -u "$UNAME" -w "$WORKDIR" "$CNAME" zsh
]],
      -- variables
      cname, name, workdir,
      -- rmi
      IMAGE_NAME,
      -- build
      df, HOST_USER, IMAGE_NAME, dd,
      -- stamp write
      stamp_write,
      -- run
      vflags_sh, IMAGE_NAME
    )

    local f = io.open(script_path, "w")
    if not f then
      wezterm.log_error("docker: failed to write build script to " .. script_path)
      return
    end
    f:write(script)
    f:close()

    pane:send_text("bash " .. script_path .. "\r")
  end
end

-- Ensure the container is running with the given host_dir mounted.
-- Only called on the fast path (image already up-to-date).
local function ensure_container(host_dir)
  local name = dir_name(host_dir)
  local cname = container_name(host_dir)
  local workdir = "/workspace/" .. name

  if known_containers[cname] then
    wezterm.log_info("docker: container " .. cname .. " cached as running, skipping")
    return workdir
  end

  wezterm.log_info("docker: inspecting container " .. cname)
  local ok, stdout = run_cmd("docker", "inspect", "-f", "{{.State.Running}}", cname)
  local running = ok and stdout:match("true")

  if not running then
    wezterm.log_info("docker: container " .. cname .. " not running, removing stale")
    run_cmd("docker", "rm", "-f", cname)
    wezterm.log_info("docker: starting container " .. cname)

    local mounts = volume_mounts(host_dir)
    local run_args = { "docker", "run", "-d", "--name", cname }
    for _, m in ipairs(mounts) do
      table.insert(run_args, "-v")
      table.insert(run_args, m)
    end
    table.insert(run_args, "--restart")
    table.insert(run_args, "unless-stopped")
    table.insert(run_args, IMAGE_NAME)
    table.insert(run_args, "sleep")
    table.insert(run_args, "infinity")

    local started = run_cmd(table.unpack(run_args))
    if not started then
      wezterm.log_error("docker: failed to start container " .. cname)
      return nil
    end
    known_users[cname] = nil
  end

  known_containers[cname] = true
  wezterm.log_info("docker: container " .. cname .. " ready, workdir=" .. workdir)
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
local function ensure_user(cname, username)
  if known_users[cname] and known_users[cname][username] then
    wezterm.log_info("docker: user '" .. username .. "' already known in " .. cname .. ", skipping")
    return
  end
  wezterm.log_info("docker: checking user '" .. username .. "' in " .. cname)
  local ok = run_cmd("docker", "exec", cname, "id", username)
  if not ok then
    wezterm.log_info("docker: creating user '" .. username .. "'")
    run_cmd("docker", "exec", cname, "useradd", "-m", "-s", "/bin/zsh", username)
    run_cmd("docker", "exec", cname, "bash", "-c",
      "echo '" .. username .. " ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers")
  end
  -- Copy skel dotfiles and symlink shared claude auth into user's home
  run_cmd("docker", "exec", cname, "bash", "-c",
    "cp -rn /etc/skel/. /home/" .. username .. "/ 2>/dev/null; " ..
    "chown -R " .. username .. ":" .. username .. " /home/" .. username .. "/; " ..
    "ln -sf /opt/claude-auth/.claude /home/" .. username .. "/.claude; " ..
    "ln -sf /opt/claude-auth/.claude.json /home/" .. username .. "/.claude.json")
  if not known_users[cname] then known_users[cname] = {} end
  known_users[cname][username] = true
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

-- Fast-path connect: ensure container + user, then exec into it
local function fast_connect(pane, host_dir)
  local workdir = ensure_container(host_dir)
  if not workdir then
    wezterm.log_error("docker: ensure_container failed, aborting")
    docker_workdirs[pane:pane_id()] = nil
    send_command(pane, "echo '>>> [capsule] Error: failed to start container. Check wezterm logs.'")
    return
  end
  local user = dir_name(host_dir)
  local cname = container_name(host_dir)
  ensure_user(cname, user)
  local cmd = string.format("docker exec -it -u %s -w %s %s zsh", user, workdir, cname)
  wezterm.log_info("docker: exec command: " .. cmd)
  send_command(pane, cmd)
end

-- Connect to docker for a given host directory (build if needed, else fast path)
local function docker_connect(pane, host_dir)
  wezterm.log_info("docker: docker_connect called for " .. host_dir)
  local rebuild_needed, mtime = check_image_state()
  add_recent(host_dir)
  docker_workdirs[pane:pane_id()] = "/workspace/" .. dir_name(host_dir)
  if rebuild_needed then
    pane_build_and_connect(pane, host_dir, mtime)
  else
    fast_connect(pane, host_dir)
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
  docker_connect(pane, cwd)
end

-- Show an InputSelector from the recent dirs list and call on_select(pane, label) on pick
local function pick_recent(win, pane, on_select)
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
          on_select(inner_win, inner_pane, label)
        end
      end),
    }),
    pane
  )
end

-- Show recent Docker directories as a selector
function M.show_recent(win, pane)
  pick_recent(win, pane, function(inner_win, inner_pane, label)
    if M.is_in_docker(inner_pane) then
      docker_workdirs[inner_pane:pane_id()] = nil
      send_command(inner_pane, "exit")
      wezterm.sleep_ms(500)
    end
    docker_connect(inner_pane, label)
  end)
end

-- Show recent directories and open a new tab in the selected one
function M.new_tab_recent(win, pane)
  pick_recent(win, pane, function(inner_win, inner_pane, label)
    inner_win:perform_action(
      wezterm.action.SpawnCommandInNewTab({
        cwd = label,
      }),
      inner_pane
    )
  end)
end

-- Force a full rebuild; runs everything in the pane so the user sees output
function M.force_rebuild(win, pane)
  wezterm.log_info("docker: force_rebuild called")
  local cwd = pane_cwd(pane)
  local mtime = file_mtime(DOCKERFILE)
  -- Let pane_build_and_connect handle stop/rm/rmi before building
  pane_build_and_connect(pane, cwd, mtime)
end

return M
