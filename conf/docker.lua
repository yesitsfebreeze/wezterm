local wezterm = require("wezterm")

local M = {}

local is_windows = os.getenv("OS") == "Windows_NT"
local CONTAINER_PREFIX = "capsule"
local IMAGE_NAME = "capsule:latest"
local DOCKERFILE_DIR = wezterm.config_dir
local HOST_USER = is_windows and os.getenv("USERNAME") or os.getenv("USER")
local RECENT_FILE = wezterm.config_dir .. (is_windows and "\\.recent" or "/.recent")
local MAX_RECENT = 20
local DOCKERFILE = DOCKERFILE_DIR .. (is_windows and "\\Dockerfile" or "/Dockerfile")
local BUILD_STAMP = wezterm.config_dir .. (is_windows and "\\.docker_build" or "/.docker_build")
local DOTFILES_REPO = "https://github.com/yesitsfebreeze/dotfiles.git"

local home_dir = wezterm.home_dir
local ssh_dir = home_dir .. (is_windows and "\\.ssh" or "/.ssh")
local gitconfig = home_dir .. (is_windows and "\\.gitconfig" or "/.gitconfig")
local claude_dir = home_dir .. (is_windows and "\\.claude" or "/.claude")
local claude_json = home_dir .. (is_windows and "\\.claude.json" or "/.claude.json")

M.recent_picker_active = false
local docker_workdirs = {}
local known_containers = {}
local known_users = {}

local function docker_path(path)
  return path:gsub("\\", "/")
end

local function dir_name(path)
  return docker_path(path):match("([^/]+)$") or "workspace"
end

local function container_name(host_dir)
  return CONTAINER_PREFIX .. "-" .. dir_name(host_dir)
end

local function run_cmd(...)
  local args = { ... }
  local ok, stdout, stderr = wezterm.run_child_process(args)
  if not ok and stderr and stderr ~= "" then
    wezterm.log_error("docker: " .. table.concat(args, " ") .. " | " .. stderr)
  end
  return ok, (stdout or "")
end

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

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local v = f:read("*l")
  f:close()
  return v
end

local function write_file(path, content)
  local f = io.open(path, "w")
  if f then f:write(content); f:close() end
end

local function check_image_state()
  local mtime = file_mtime(DOCKERFILE)
  local stamp = read_file(BUILD_STAMP)

  if mtime and stamp and mtime == stamp then
    local ok = run_cmd("docker", "image", "inspect", IMAGE_NAME)
    if ok then return false, mtime end
    return true, mtime
  end

  if not mtime then
    local ok = run_cmd("docker", "image", "inspect", IMAGE_NAME)
    return not ok, nil
  end

  return true, mtime
end

local function volume_mounts(host_dir)
  local mount_src = docker_path(host_dir)
  local workdir = "/workspace/" .. dir_name(host_dir)
  return {
    mount_src .. ":" .. workdir,
    docker_path(ssh_dir) .. ":/home/" .. HOST_USER .. "/.ssh:ro",
    docker_path(gitconfig) .. ":/home/" .. HOST_USER .. "/.gitconfig:ro",
    docker_path(claude_dir) .. ":/opt/claude-auth/.claude",
    docker_path(claude_json) .. ":/opt/claude-auth/.claude.json",
  }
end

local function volume_flags(host_dir, sep)
  local parts = {}
  for _, m in ipairs(volume_mounts(host_dir)) do
    table.insert(parts, sep .. '-v "' .. m .. '"')
  end
  return table.concat(parts, " ")
end

local function write_script(path, content)
  local f = io.open(path, "w")
  if not f then
    wezterm.log_error("docker: failed to write " .. path)
    return false
  end
  f:write(content)
  f:close()
  return true
end

local function pane_build_and_connect(pane, host_dir, mtime)
  local name = dir_name(host_dir)
  local cname = container_name(host_dir)
  local workdir = "/workspace/" .. name
  local df = docker_path(DOCKERFILE)
  local dd = docker_path(DOCKERFILE_DIR)

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
docker exec $CNAME bash -c "git clone %s /tmp/dotfiles-$UNAME 2>/dev/null; cp -rn /tmp/dotfiles-$UNAME/. /home/$UNAME/; rm -rf /tmp/dotfiles-$UNAME; chown -R ${UNAME}:$UNAME /home/$UNAME/; ln -sf /opt/claude-auth/.claude /home/$UNAME/.claude; ln -sf /opt/claude-auth/.claude.json /home/$UNAME/.claude.json"

Write-Host ">>> [capsule] Connecting..." -ForegroundColor Green
docker exec -it -u $UNAME -w $WORKDIR $CNAME zsh
]],
      cname, name, workdir,
      IMAGE_NAME,
      df, HOST_USER, IMAGE_NAME, dd,
      stamp_write,
      volume_flags(host_dir, " `\n  "), IMAGE_NAME,
      DOTFILES_REPO
    )

    if not write_script(script_path, script) then return end
    pane:send_text("& '" .. script_path .. "'\r")
  else
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
docker exec "$CNAME" bash -c "git clone %s /tmp/dotfiles-$UNAME 2>/dev/null; cp -rn /tmp/dotfiles-$UNAME/. /home/$UNAME/; rm -rf /tmp/dotfiles-$UNAME; chown -R $UNAME:$UNAME /home/$UNAME/; ln -sf /opt/claude-auth/.claude /home/$UNAME/.claude; ln -sf /opt/claude-auth/.claude.json /home/$UNAME/.claude.json"

echo ">>> [capsule] Connecting..."
docker exec -it -u "$UNAME" -w "$WORKDIR" "$CNAME" zsh
]],
      cname, name, workdir,
      IMAGE_NAME,
      df, HOST_USER, IMAGE_NAME, dd,
      stamp_write,
      volume_flags(host_dir, " \\\n  "), IMAGE_NAME,
      DOTFILES_REPO
    )

    if not write_script(script_path, script) then return end
    pane:send_text("bash " .. script_path .. "\r")
  end
end

local function ensure_container(host_dir)
  local cname = container_name(host_dir)
  local workdir = "/workspace/" .. dir_name(host_dir)

  if known_containers[cname] then return workdir end

  local ok, stdout = run_cmd("docker", "inspect", "-f", "{{.State.Running}}", cname)
  if not (ok and stdout:match("true")) then
    run_cmd("docker", "rm", "-f", cname)

    local run_args = { "docker", "run", "-d", "--name", cname }
    for _, m in ipairs(volume_mounts(host_dir)) do
      table.insert(run_args, "-v")
      table.insert(run_args, m)
    end
    for _, a in ipairs({ "--restart", "unless-stopped", IMAGE_NAME, "sleep", "infinity" }) do
      table.insert(run_args, a)
    end

    if not run_cmd(table.unpack(run_args)) then
      wezterm.log_error("docker: failed to start " .. cname)
      return nil
    end
    known_users[cname] = nil
  end

  known_containers[cname] = true
  return workdir
end

local function pane_cwd(pane)
  local cwd_uri = pane:get_current_working_dir()
  if cwd_uri then
    local path = cwd_uri.file_path
    if is_windows then path = path:gsub("^/(%a:)", "%1") end
    return path
  end
  return wezterm.home_dir
end

local function ensure_user(cname, username)
  if known_users[cname] and known_users[cname][username] then return end
  local ok = run_cmd("docker", "exec", cname, "id", username)
  if not ok then
    run_cmd("docker", "exec", cname, "useradd", "-m", "-s", "/bin/zsh", username)
    run_cmd("docker", "exec", cname, "bash", "-c",
      "echo '" .. username .. " ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers")
  end
  run_cmd("docker", "exec", cname, "bash", "-c",
    "git clone " .. DOTFILES_REPO .. " /tmp/dotfiles-" .. username .. " 2>/dev/null && " ..
    "cp -rn /tmp/dotfiles-" .. username .. "/. /home/" .. username .. "/ && " ..
    "rm -rf /tmp/dotfiles-" .. username .. "; " ..
    "chown -R " .. username .. ":" .. username .. " /home/" .. username .. "/; " ..
    "ln -sf /opt/claude-auth/.claude /home/" .. username .. "/.claude; " ..
    "ln -sf /opt/claude-auth/.claude.json /home/" .. username .. "/.claude.json")
  if not known_users[cname] then known_users[cname] = {} end
  known_users[cname][username] = true
end

function M.is_in_docker(pane)
  return (pane:get_foreground_process_name() or ""):find("docker") ~= nil
end

function M.get_docker_workdir(pane)
  return docker_workdirs[pane:pane_id()]
end

local function read_recent()
  local f = io.open(RECENT_FILE, "r")
  if not f then return {} end
  local dirs = {}
  for line in f:lines() do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed and trimmed ~= "" then table.insert(dirs, trimmed) end
  end
  f:close()
  return dirs
end

local function add_recent(dir)
  local dirs = read_recent()
  local new = { dir }
  for _, d in ipairs(dirs) do
    if d ~= dir then table.insert(new, d) end
  end
  while #new > MAX_RECENT do table.remove(new) end
  local f = io.open(RECENT_FILE, "w")
  if not f then return end
  for _, d in ipairs(new) do f:write(d .. "\n") end
  f:close()
end

function M.apply_to_config(config)
  if is_windows then
    config.default_prog = { "pwsh.exe", "-NoLogo", "-NoExit", "-File",
      wezterm.config_dir .. "\\conf\\shell-integration.ps1" }
  end
end

local function fast_connect(pane, host_dir)
  local workdir = ensure_container(host_dir)
  if not workdir then
    docker_workdirs[pane:pane_id()] = nil
    pane:send_text("echo '>>> [capsule] Error: failed to start container.'\r")
    return
  end
  local user = dir_name(host_dir)
  local cname = container_name(host_dir)
  ensure_user(cname, user)
  pane:send_text(string.format("docker exec -it -u %s -w %s %s zsh\r", user, workdir, cname))
end

local function docker_connect(pane, host_dir)
  local rebuild_needed, mtime = check_image_state()
  add_recent(host_dir)
  docker_workdirs[pane:pane_id()] = "/workspace/" .. dir_name(host_dir)
  if rebuild_needed then
    pane_build_and_connect(pane, host_dir, mtime)
  else
    fast_connect(pane, host_dir)
  end
end

function M.mount_current_dir(win, pane)
  if M.is_in_docker(pane) then
    docker_workdirs[pane:pane_id()] = nil
    pane:send_text("exit\r")
    return
  end
  docker_connect(pane, pane_cwd(pane))
end

local function pick_recent(win, pane, on_select)
  local dirs = read_recent()
  if #dirs == 0 then return end

  local choices = {}
  for _, d in ipairs(dirs) do table.insert(choices, { label = d }) end

  M.recent_picker_active = true
  win:perform_action(
    wezterm.action.InputSelector({
      title = "",
      choices = choices,
      fuzzy = true,
      action = wezterm.action_callback(function(inner_win, inner_pane, id, label)
        M.recent_picker_active = false
        inner_win:perform_action(wezterm.action.EmitEvent("update-right-status"), inner_pane)
        if label then on_select(inner_win, inner_pane, label) end
      end),
    }),
    pane
  )
end

function M.show_recent(win, pane)
  pick_recent(win, pane, function(_, inner_pane, label)
    if M.is_in_docker(inner_pane) then
      docker_workdirs[inner_pane:pane_id()] = nil
      inner_pane:send_text("exit\r")
      wezterm.sleep_ms(500)
    end
    docker_connect(inner_pane, label)
  end)
end

function M.new_tab_recent(win, pane)
  pick_recent(win, pane, function(inner_win, inner_pane, label)
    inner_win:perform_action(wezterm.action.SpawnCommandInNewTab({ cwd = label }), inner_pane)
  end)
end

function M.force_rebuild(win, pane)
  pane_build_and_connect(pane, pane_cwd(pane), file_mtime(DOCKERFILE))
end

return M
