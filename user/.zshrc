# This config is distributed via Docker (Linux) — do not add macOS or platform-specific plugins/tools.

# If you come from bash you might have to change your $PATH.
# export PATH=$HOME/bin:$HOME/.local/bin:/usr/local/bin:$PATH

export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="nanotech"
ENABLE_CORRECTION="true"

COMPLETION_WAITING_DOTS="true"


HIST_STAMPS="dd/mm/yyyy"

# Standard plugins can be found in $ZSH/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
plugins=(git)

source $ZSH/oh-my-zsh.sh

export MANPATH="/usr/local/man:$MANPATH"
export LANG=en_US.UTF-8

export PATH="$HOME/.local/bin:$PATH"
alias ls="eza --group-directories-first --icons --all"

cd() {
  builtin cd "$@" || return
  ls
}

alias .="open ."
alias ..="cd .."
alias c='cd'
alias e="nvim"
alias dk='docker rm -f $(docker ps -a -q)'

di() {
  cd ~/dev/diw/diw-installer/customers/$@
}

dc() {
  cd ~/dev/diw/diw-sources/customers/$@
}



alias cl="claude --dangerously-skip-permissions"
alias oc="opencode"

# opencode
export PATH=/Users/feb/.opencode/bin:$PATH

# Sync .files repo and reload .zshrc
reload() {
  local cwd="$PWD"
  builtin cd ~
  git add -A
  git commit -m "sync"
  git pull --rebase
  git push
  builtin cd "$cwd"
  source ~/.zshrc
}

# Sync command to download and rsync .files repo (Dockerfile logic)
mount() {
  local cwd="$PWD"
  cd ~/docker
  just run "$cwd"
}
