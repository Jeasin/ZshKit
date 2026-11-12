# ==========================================================
# 别名与函数
#
# 约定：指向"可能不存在的东西"的别名一律带守卫，
#       否则会把本来能用的命令遮蔽成坏的（比如 bat / ssh）。
# ==========================================================

# ------------------------------------------
# 开发与运行
# ------------------------------------------
alias uvt="uv tool"
alias vim='nvim'

# bat 包装脚本（本机自备；没有就保留系统/brew 的 bat）
[[ -x "$HOME/.local/bin/UnixBin/bat-wrapper" ]] &&
  alias bat="$HOME/.local/bin/UnixBin/bat-wrapper"

alias imev='zsh -c '\''for f; do magick "$f" -crop "%[fx:floor(w/2)*2]x%[fx:floor(h/2)*2]+0+0" +repage -define png:compression-level=1 "$f"; done'\'' _'

# alias ffmpeg='ffmpeg -hide_banner -loglevel fatal -stats'
alias ffprobe='ffprobe -hide_banner'
alias ffplay='ffplay -hide_banner'
alias flac-min='flac --silent --no-verbose'
alias spek='spek 2>/dev/null'
alias amdl='amdl -c "$XDG_CONFIG_HOME/amdl/config.yaml"'

# SSH：只有存在自定义 config 时才接管，否则用默认行为
if [[ -r "$XDG_CONFIG_HOME/ssh/config" ]]; then
  alias ssh="ssh -F $XDG_CONFIG_HOME/ssh/config"
  alias mosh="mosh --ssh='ssh -F $XDG_CONFIG_HOME/ssh/config'"
fi

# ------------------------------------------
# macOS 系统控制
# ------------------------------------------
alias iconon="defaults write com.apple.finder CreateDesktop -bool true; killall Finder"
alias iconoff="defaults write com.apple.finder CreateDesktop -bool false; killall Finder"
alias mton="/bin/launchctl setenv MTL_HUD_ENABLED 1"
alias mtoff="/bin/launchctl setenv MTL_HUD_ENABLED 0"

# 烤机
alias warmac='workers=$(sysctl -n hw.logicalcpu); start=$SECONDS; for ((i=0; i<workers; i++)); do (while :; do ((x = (x * 1103515245 + 12345) % 2147483647)); done) & done; while :; do printf "\r🔥 CPU 烤机中 | %02d:%02d:%02d | %d Workers" "$(( (SECONDS-start)/3600 ))" "$(( (SECONDS-start)%3600/60 ))" "$(( (SECONDS-start)%60 ))" "$workers"; sleep 1; done'

# 第三方开关
alias ssoff="PROMPT='%n@%m %1~ %# '; RPROMPT=''"   # 关掉 starship
alias sson='eval "$(starship init zsh)"'           # 打开 starship

# ------------------------------------------
# 原生工具安全增强
# ------------------------------------------
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias df='df -h'

# 快捷切换上次目录：直接输入 - 即可
function -- -() { builtin cd - }

# Git 历史日志美化
alias glog='PAGER="less -F -X" git log'
alias gadog='PAGER="less -F -X" git log --all --decorate --oneline --graph'

# ==========================================
# 第三方现代工具
# ==========================================

# eza
alias l='eza --icons=auto'
alias la='eza -a --icons=auto'
alias ll='eza -lh --icons=auto --git -H --time-style="+%Y-%m-%d %H:%M"' lh='ll'
alias lla='eza -lah --icons=auto --git -H --time-style="+%Y-%m-%d %H:%M"' lal='lla' lah='lla'
alias llt='eza -lh --sort=modified --reverse --icons=auto -H --time-style="+%Y-%m-%d %H:%M"' ltl='llt' lht='llt'
alias lls='eza -lh --sort=size --reverse --icons=auto -H --time-style="+%Y-%m-%d %H:%M"'

# 显示大小与精简列的 eza tree
etr() {
  [[ "$1" =~ ^[0-9]+$ ]] && set -- -L "$1" "${@:2}"
  eza -l --tree --total-size \
      --no-permissions --no-user --no-time \
      --icons=auto --group-directories-first "$@"
}

# fd 在 Linux 上叫 fdfind
if command -v fdfind >/dev/null 2>&1; then
  alias fd='fdfind'
fi

# zoxide（没装就别劫持 cd）
if (( $+commands[zoxide] )); then
  alias cd='z'
fi
