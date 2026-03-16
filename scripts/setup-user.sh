#!/usr/bin/env bash
set -e

USERNAME="${1:?Usage: setup-user.sh <username> <dotfiles_repo>}"
DOTFILES_REPO="${2:?Usage: setup-user.sh <username> <dotfiles_repo>}"
HOME_DIR="/home/$USERNAME"

# Create user if needed
if ! id "$USERNAME" &>/dev/null; then
  useradd -m -s /bin/zsh "$USERNAME"
  echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
fi

# --- SSH key setup ---
# Host .ssh dir is volume-mounted at /opt/host-ssh (read-only).
# Copy to a writable location with correct permissions for git SSH auth.
echo ">>> [capsule] Setting up SSH keys..."
MOUNTED_SSH="/opt/host-ssh"
SSH_DIR="$HOME_DIR/.ssh"

rm -rf "$SSH_DIR"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [ -d "$MOUNTED_SSH" ] && ls "$MOUNTED_SSH"/* &>/dev/null; then
  cp -a "$MOUNTED_SSH"/. "$SSH_DIR/"
  chmod 700 "$SSH_DIR"
  chmod 600 "$SSH_DIR"/* 2>/dev/null || true
  chmod 644 "$SSH_DIR"/*.pub 2>/dev/null || true
  # Add GitHub host key to known_hosts if not already present
  if ! grep -q "github.com" "$SSH_DIR/known_hosts" 2>/dev/null; then
    ssh-keyscan -t ed25519,rsa github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
  fi
else
  echo ">>> [capsule] WARNING: No SSH keys found at $MOUNTED_SSH"
  # Still add known_hosts so SSH doesn't prompt
  ssh-keyscan -t ed25519,rsa github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
fi

chown -R "$USERNAME:$USERNAME" "$SSH_DIR"

# Auto-detect the SSH private key
SSH_KEY=""
for candidate in id_ed25519 id_rsa id_ecdsa id_dsa; do
  if [ -f "$SSH_DIR/$candidate" ]; then
    SSH_KEY="$SSH_DIR/$candidate"
    echo ">>> [capsule] Using SSH key: $candidate"
    break
  fi
done
# Fallback: first file that looks like a private key
if [ -z "$SSH_KEY" ]; then
  for f in "$SSH_DIR"/*; do
    if [ -f "$f" ] && head -1 "$f" 2>/dev/null | grep -q "PRIVATE KEY"; then
      SSH_KEY="$f"
      echo ">>> [capsule] Using SSH key: $(basename "$f")"
      break
    fi
  done
fi

# --- Clone dotfiles ---
echo ">>> [capsule] Syncing dotfiles from $DOTFILES_REPO ..."
rm -rf "/tmp/dotfiles-$USERNAME"
CLONE_OK=0

if [ -n "$SSH_KEY" ]; then
  sudo -u "$USERNAME" \
    GIT_SSH_COMMAND="ssh -i $SSH_KEY -o UserKnownHostsFile=$SSH_DIR/known_hosts -o StrictHostKeyChecking=accept-new" \
    git clone "$DOTFILES_REPO" "/tmp/dotfiles-$USERNAME" && CLONE_OK=1 || {
      echo ">>> [capsule] WARNING: SSH clone failed (exit $?). Retrying without explicit key..."
      sudo -u "$USERNAME" git clone "$DOTFILES_REPO" "/tmp/dotfiles-$USERNAME" && CLONE_OK=1 || true
    }
else
  echo ">>> [capsule] WARNING: No SSH key detected, attempting clone anyway..."
  sudo -u "$USERNAME" git clone "$DOTFILES_REPO" "/tmp/dotfiles-$USERNAME" && CLONE_OK=1 || true
fi

if [ "$CLONE_OK" = "1" ] && [ -d "/tmp/dotfiles-$USERNAME" ]; then
  rsync -a --exclude '.git' "/tmp/dotfiles-$USERNAME/" "$HOME_DIR/"
  echo ">>> [capsule] Dotfiles applied successfully."
else
  echo ">>> [capsule] WARNING: Dotfiles clone failed. Continuing without dotfiles."
fi
rm -rf "/tmp/dotfiles-$USERNAME"

# --- Git credentials ---
if [ -f /opt/git-auth/.gitconfig ]; then
  cp -f /opt/git-auth/.gitconfig "$HOME_DIR/.gitconfig"
fi

if [ -f /opt/git-auth/.git-credentials ]; then
  cp -f /opt/git-auth/.git-credentials "$HOME_DIR/.git-credentials"
  chmod 600 "$HOME_DIR/.git-credentials"
  git config --global credential.helper store
fi

# --- Claude auth ---
ln -sf /opt/claude-auth/.claude "$HOME_DIR/.claude"
ln -sf /opt/claude-auth/.claude.json "$HOME_DIR/.claude.json"
chown -R "$USERNAME:$USERNAME" /opt/claude-auth/.claude 2>/dev/null || true
chown "$USERNAME:$USERNAME" /opt/claude-auth/.claude.json 2>/dev/null || true

# --- OpenCode auth ---
mkdir -p "$HOME_DIR/.local/share"
mkdir -p "$HOME_DIR/.config"
ln -sf /opt/opencode-auth/data "$HOME_DIR/.local/share/opencode"
ln -sf /opt/opencode-auth/config "$HOME_DIR/.config/opencode"
chown -R "$USERNAME:$USERNAME" /opt/opencode-auth/data 2>/dev/null || true
chown -R "$USERNAME:$USERNAME" /opt/opencode-auth/config 2>/dev/null || true

# --- Ensure .zshrc exists (prevent zsh-newuser-install prompt) ---
if [ ! -f "$HOME_DIR/.zshrc" ]; then
  echo ">>> [capsule] Creating default .zshrc..."
  cat > "$HOME_DIR/.zshrc" <<'ZSHEOF'
# Default capsule .zshrc
export ZSH=/opt/oh-my-zsh
ZSH_THEME="robbyrussell"
plugins=(git)
source $ZSH/oh-my-zsh.sh
ZSHEOF
fi

# --- Set up persistent SSH config for ongoing git operations ---
SSH_KEY_NAME=""
if [ -n "$SSH_KEY" ]; then
  SSH_KEY_NAME="$(basename "$SSH_KEY")"
fi

if [ -n "$SSH_KEY_NAME" ] && [ ! -f "$SSH_DIR/config" ]; then
  cat > "$SSH_DIR/config" <<SSHEOF
Host github.com
  IdentityFile ~/.ssh/$SSH_KEY_NAME
  UserKnownHostsFile ~/.ssh/known_hosts
  StrictHostKeyChecking accept-new
SSHEOF
  chmod 600 "$SSH_DIR/config"
fi

# --- Fix ownership ---
chown -R "$USERNAME:$USERNAME" "$HOME_DIR/"
echo ">>> [capsule] User setup complete for $USERNAME."
