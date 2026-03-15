export ZSH="/opt/oh-my-zsh"
ZSH_THEME="nanotech"
ENABLE_CORRECTION="true"
COMPLETION_WAITING_DOTS="true"
HIST_STAMPS="dd/mm/yyyy"
plugins=(git)
source $ZSH/oh-my-zsh.sh

export MANPATH="/usr/local/man:$MANPATH"
export LANG=en_US.UTF-8
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"

alias ls="eza --group-directories-first --icons --all"
alias ..="cd .."
alias .="open ."
alias e="nvim"
alias dk='docker rm -f $(docker ps -a -q)'
alias cl="claude --dangerously-skip-permissions"
alias oc="opencode"

cd() {
  builtin cd "$@" || return
  ls
}

reload() {
  local cwd="$PWD"
  builtin cd ~
  git add -A && git commit -m "sync" && git pull --rebase && git push
  builtin cd "$cwd"
  source ~/.zshrc
}
