local wezterm = require("wezterm")
local split = require("conf.split")

local M = {}

local is_windows = os.getenv("OS") == "Windows_NT"
local SEP = is_windows and "\\" or "/"
local CACHE_DIR = wezterm.config_dir .. SEP .. ".cache"
local CONTAINER_PREFIX = "capsule"
local IMAGE_NAME = "capsule:latest"
local DOCKERFILE_DIR = wezterm.config_dir
local HOST_USER = is_windows and os.getenv("USERNAME") or os.getenv("USER")
local RECENT_FILE = CACHE_DIR .. SEP .. "recent"
local MAX_RECENT = 20
local DOCKERFILE = DOCKERFILE_DIR .. (is_windows and "\\Dockerfile" or "/Dockerfile")
local BUILD_STAMP = CACHE_DIR .. SEP .. "docker_build"
local DOTFILES_REPO = "git@github.com:yesitsfebreeze/dotfiles.git"
local SCRIPTS_DIR = wezterm.config_dir .. (is_windows and "\\scripts" or "/scripts")

local home_dir = wezterm.home_dir
local ssh_dir = home_dir .. (is_windows and "\\.ssh" or "/.ssh")
local gitconfig = home_dir .. (is_windows and "\\.gitconfig" or "/.gitconfig")
local claude_dir = home_dir .. (is_windows and "\\.claude" or "/.claude")
local claude_json = home_dir .. (is_windows and "\\.claude.json" or "/.claude.json")
local opencode_auth = home_dir .. (is_windows and "\\.local\\share\\opencode" or "/.local/share/opencode")
local opencode_config = home_dir .. (is_windows and "\\.config\\opencode" or "/.config/opencode")

M.recent_picker_active = false
local docker_workdirs = {}
local known_containers = {}
local known_users = {}

-- Extract git credentials via `git credential fill`
local git_credentials_file = CACHE_DIR .. SEP .. "git-credentials"
local git_credentials_refreshed = false

local cache_dir_ensured = false
local cached_git_creds_exists = nil
local function ensure_cache_dir()
  if cache_dir_ensured then return end
  if is_windows then
    os.execute('mkdir "' .. CACHE_DIR:gsub("/", "\\") .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. CACHE_DIR .. '"')
  end
  cache_dir_ensured = true
end

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
  ensure_cache_dir()
  local f = io.open(path, "wb")
  if f then f:write(content); f:close() end
end

local function refresh_git_credentials()
  if git_credentials_refreshed then return end
  git_credentials_refreshed = true
  local ok, stdout
  if is_windows then
    ok, stdout = run_cmd("powershell.exe", "-NoProfile", "-Command",
      "& { echo 'protocol=https'; echo 'host=github.com' } | git credential fill")
  else
    ok, stdout = run_cmd("bash", "-c",
      "printf 'protocol=https\\nhost=github.com\\n' | git credential fill")
  end
  if not ok then return end
  local user = stdout:match("username=([^\r\n]+)")
  local pass = stdout:match("password=([^\r\n]+)")
  if user and pass then
    write_file(git_credentials_file, "https://" .. user .. ":" .. pass .. "@github.com\n")
  end
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

-- Volume mounts: .ssh is mounted directly into user home
local function volume_mounts(host_dir, username)
  refresh_git_credentials()
  local user_home = "/home/" .. username
  local mount_src = docker_path(host_dir)
  local workdir = "/workspace/" .. dir_name(host_dir)
  local mounts = {
    mount_src .. ":" .. workdir,
    docker_path(ssh_dir) .. ":/opt/host-ssh:ro",
    docker_path(gitconfig) .. ":/opt/git-auth/.gitconfig:ro",
    docker_path(claude_dir) .. ":/opt/claude-auth/.claude",
    docker_path(claude_json) .. ":/opt/claude-auth/.claude.json",
    docker_path(opencode_auth) .. ":/opt/opencode-auth/data",
    docker_path(opencode_config) .. ":/opt/opencode-auth/config",
  }
  local f
  if cached_git_creds_exists == nil then
    f = io.open(git_credentials_file, "r")
    cached_git_creds_exists = (f ~= nil)
  end
  if cached_git_creds_exists then
    table.insert(mounts, 3, docker_path(git_credentials_file) .. ":/opt/git-auth/.git-credentials:ro")
  end
  return mounts
end

local function volume_args_list(host_dir, username)
  local args = {}
  for _, m in ipairs(volume_mounts(host_dir, username)) do
    table.insert(args, "-v")
    table.insert(args, m)
  end
  return args
end

local function volume_flags_str(host_dir, username, sep)
  local parts = {}
  for _, m in ipairs(volume_mounts(host_dir, username)) do
    table.insert(parts, sep .. '-v "' .. m .. '"')
  end
  return table.concat(parts, " ")
end

-- Build + connect: calls external scripts
local function pane_build_and_connect(pane, host_dir, mtime)
  local name = dir_name(host_dir)
  local cname = container_name(host_dir)
  local workdir = "/workspace/" .. name

  os.remove(BUILD_STAMP)
  known_containers = {}
  known_users = {}

  if is_windows then
    local script = docker_path(SCRIPTS_DIR) .. "/build.ps1"
    local vol_flags = volume_flags_str(host_dir, name, " `\n  ")

    -- Build volume args as a PS array for splatting
    local vol_parts = {}
    for _, m in ipairs(volume_mounts(host_dir, name)) do
      table.insert(vol_parts, '"-v"')
      table.insert(vol_parts, '"' .. m .. '"')
    end
    local vol_array = table.concat(vol_parts, ", ")

    pane:send_text(string.format(
      "& '%s' -CName '%s' -Username '%s' -WorkDir '%s' -Image '%s' -Dockerfile '%s' -DockerfileDir '%s' -BuildUser '%s' -StampFile '%s' -DotfilesRepo '%s' -VolumeArgs %s\r",
      script, cname, name, workdir, IMAGE_NAME,
      docker_path(DOCKERFILE), docker_path(DOCKERFILE_DIR),
      HOST_USER, BUILD_STAMP, DOTFILES_REPO, vol_array
    ))
  else
    local script = SCRIPTS_DIR .. "/build.sh"
    local vol_flags = volume_flags_str(host_dir, name, " \\\n  ")

    -- Pass volume args as trailing arguments
    local vol_parts = {}
    for _, m in ipairs(volume_mounts(host_dir, name)) do
      table.insert(vol_parts, '-v "' .. m .. '"')
    end
    local vol_str = table.concat(vol_parts, " ")

    pane:send_text(string.format(
      "bash '%s' '%s' '%s' '%s' '%s' '%s' '%s' '%s' '%s' '%s' %s\r",
      script, cname, name, workdir, IMAGE_NAME,
      docker_path(DOCKERFILE), docker_path(DOCKERFILE_DIR),
      HOST_USER, BUILD_STAMP, DOTFILES_REPO, vol_str
    ))
  end
end

-- Fast connect: container already running, just ensure user + exec
local function ensure_container(host_dir, username)
  local cname = container_name(host_dir)
  local workdir = "/workspace/" .. dir_name(host_dir)

  if known_containers[cname] then return workdir end

  local ok, stdout = run_cmd("docker", "inspect", "-f", "{{.State.Running}}", cname)
  if not (ok and stdout:match("true")) then
    run_cmd("docker", "rm", "-f", cname)

    local run_args = { "docker", "run", "-d", "--name", cname }
    for _, a in ipairs(volume_args_list(host_dir, username)) do
      table.insert(run_args, a)
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

local function ensure_user(cname, username)
  if known_users[cname] and known_users[cname][username] then return end
  run_cmd("docker", "exec", cname, "/usr/local/bin/setup-user.sh", username, DOTFILES_REPO)
  if not known_users[cname] then known_users[cname] = {} end
  known_users[cname][username] = true
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

local function fast_connect(pane, host_dir)
  local user = dir_name(host_dir)
  local workdir = ensure_container(host_dir, user)
  if not workdir then
    docker_workdirs[pane:pane_id()] = nil
    pane:send_text("echo '>>> [capsule] Error: failed to start container.'\r")
    return
  end
  local cname = container_name(host_dir)
  ensure_user(cname, user)
  pane:send_text(string.format("docker exec -it -u %s -w %s %s zsh\r", user, workdir, cname))
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
  ensure_cache_dir()
  local f = io.open(RECENT_FILE, "w")
  if not f then return end
  for _, d in ipairs(new) do f:write(d .. "\n") end
  f:close()
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

-- Public API

function M.is_in_docker(pane)
  return (pane:get_foreground_process_name() or ""):find("docker") ~= nil
end

function M.get_docker_workdir(pane)
  return docker_workdirs[pane:pane_id()]
end

function M.apply_to_config(config)
  if is_windows then
    config.default_prog = { "pwsh.exe", "-NoLogo", "-NoExit", "-File",
      wezterm.config_dir .. "\\scripts\\shell-integration.ps1" }
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
    win:perform_action(wezterm.action.Multiple({
      wezterm.action.SpawnCommandInNewTab({ cwd = label }),
      wezterm.action_callback(function(window, pane)
        split.create_layout(window:active_tab())
      end),
    }), inner_pane)
  end)
end

function M.force_rebuild(win, pane)
  pane_build_and_connect(pane, pane_cwd(pane), file_mtime(DOCKERFILE))
end

return M
