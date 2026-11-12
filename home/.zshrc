# ── debug ────────
# `debug_zsh` reports startup timings
if [ -n "${ZSH_DEBUGRC+1}" ]; then
    zmodload zsh/zprof
fi

# ── prompt ────────
eval "$(starship init zsh)"

TRANSIENT_PROMPT="${PROMPT// prompt / prompt --profile transient }"
TRANSIENT_RPROMPT="${PROMPT// prompt / prompt --profile rtransient }"

autoload -Uz add-zsh-hook add-zle-hook-widget

transient-prompt-precmd() {
    TRAPINT() { transient-prompt; return $(( 128 + $1 )) }
    SAVED_PROMPT="$(eval "printf '%s' \"${TRANSIENT_PROMPT}\"")"
    SAVED_RPROMPT="$(eval "printf '%s' \"${TRANSIENT_RPROMPT}\"")"
}
add-zsh-hook precmd transient-prompt-precmd

transient-prompt() {
    PROMPT="$SAVED_PROMPT" RPROMPT="$SAVED_RPROMPT" zle .reset-prompt
}
add-zle-hook-widget zle-line-finish transient-prompt

# ── behaviour ────────
KEYTIMEOUT=1
WORDCHARS=${WORDCHARS//[\/]}

setopt AUTO_CD
setopt GLOB_DOTS
setopt INTERACTIVE_COMMENTS
setopt NO_BEEP

# ── history ────────
HISTSIZE=5000
SAVEHIST=$HISTSIZE

setopt EXTENDED_HISTORY
setopt HIST_VERIFY
setopt HIST_REDUCE_BLANKS
setopt HIST_IGNORE_SPACE
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_FIND_NO_DUPS

# ── keybindings ────────
bindkey -v

bindkey '^p' history-substring-search-up
bindkey '^n' history-substring-search-down
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down
bindkey -M vicmd 'k' history-substring-search-up
bindkey -M vicmd 'j' history-substring-search-down
bindkey -M viins '^Xs' sudo-command-line
bindkey -M vicmd '^Xs' sudo-command-line
bindkey -M viins '^W' backward-kill-word

# ── completion ────────
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' menu no
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompcache"

# fzf-tab: directories list, everything else previews through bat
zstyle ':fzf-tab:complete:*:*' fzf-preview \
    '[ -d $realpath ] && eza -1 --icons --color=always $realpath || bat -n --color=always $realpath 2>/dev/null'
zstyle ':fzf-tab:*' switch-group ',' '.'

# ── fzf ────────
# files come from fd: hidden ones included, .git left out
export FZF_DEFAULT_COMMAND="fd --type f --hidden --exclude .git"
export FZF_CTRL_T_COMMAND="fd --hidden --exclude .git"
export FZF_ALT_C_COMMAND="fd --type d --hidden --exclude .git"
# -1 means "terminal default", so the palette follows the terminal theme
export FZF_DEFAULT_OPTS="
  --height 40%
  --layout reverse
  --info inline
  --prompt '  '
  --pointer '>'
  --marker '+'
  --color 'fg:-1,bg:-1,hl:cyan'
  --color 'fg+:regular:white,bg+:-1,hl+:cyan'
  --color 'info:8,prompt:cyan,pointer:cyan,marker:green,spinner:8,header:8,border:8'
"

# ── man ────────
# man pages through bat, coloured as man
export MANPAGER="sh -c 'col -bx | bat -l man -p'"
export MANROFFOPT="-c"

# ── aliases ────────
alias ls='eza --icons -a --group-directories-first'
alias ll='eza --icons -a -l --group-directories-first --git --header'
alias lt='eza --icons -a -T -L 2 --group-directories-first'
alias lls='eza --icons -a -lT -L 1 --git --header'

alias grep='grep --color=auto'
alias c='clear'
alias debug_zsh='time ZSH_DEBUGRC=1 zsh -i -c exit'

# ── functions ────────
# `work` in a project folder: one tmux session named after it, Claude on the left and a shell on
# the right (lazygit is prefix g). Run again, from anywhere in tmux, it switches back to it.
work() {
    local name=${${PWD:t}//[.:]/_}
    if ! tmux has-session -t "=$name" 2>/dev/null; then
        tmux new-session -d -s "$name" -n work -c "$PWD"
        if (( $+commands[sandbox] )); then
            tmux send-keys -t "=$name:work" 'sandbox claude -r' Enter
        fi
        tmux split-window -h -l 35% -t "=$name:work" -c "$PWD"
        tmux select-pane -L -t "=$name:work"
    fi
    if [[ -n $TMUX ]]; then
        tmux switch-client -t "=$name"
    else
        tmux attach-session -t "=$name"
    fi
}

# ls after any directory change - covers cd, zoxide jumps and pushd
chpwd() { ls }

# don't append "command not found" to history
# https://www.zsh.org/mla/users//2014/msg00715.html
zshaddhistory() {
    local j=1
    while ([[ ${${(z)1}[$j]} == *=* ]]) {
        ((j++))
    }
    whence ${${(z)1}[$j]} >| /dev/null || return 1
}

# ── debug ────────
if [ -n "${ZSH_DEBUGRC+1}" ]; then
    zprof
fi