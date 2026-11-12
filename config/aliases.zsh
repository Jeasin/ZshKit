# 开发与运行别名
alias uvt="uv tool"
alias vim='nvim'
alias bat="${HOME}/.local/bin/UnixBin/bat-wrapper"

# macOS 系统控制别名
alias iconon="defaults write com.apple.finder CreateDesktop -bool true; killall Finder"
alias iconoff="defaults write com.apple.finder CreateDesktop -bool false; killall Finder"
alias mton="/bin/launchctl setenv MTL_HUD_ENABLED 1"
alias mtoff="/bin/launchctl setenv MTL_HUD_ENABLED 0"

# 烤机
alias warmac='workers=$(sysctl -n hw.logicalcpu); start=$SECONDS; for ((i=0; i<workers; i++)); do (while :; do ((x = (x * 1103515245 + 12345) % 2147483647)); done) & done; while :; do printf "\r🔥 CPU 烤机中 | %02d:%02d:%02d | %d Workers" "$(( (SECONDS-start)/3600 ))" "$(( (SECONDS-start)%3600/60 ))" "$(( (SECONDS-start)%60 ))" "$workers"; sleep 1; done'

# 第三方开关
alias ssoff="PROMPT='%n@%m %1~ %# '; RPROMPT=''" # Starship
alias sson='eval "$(starship init zsh)"'         # Starship

# 第三方条件启动
alias imev='zsh -c '\''for f; do magick "$f" -crop "%[fx:floor(w/2)*2]x%[fx:floor(h/2)*2]+0+0" +repage -define png:compression-level=1 "$f"; done'\'' _'
# alias ffmpeg='ffmpeg -hide_banner -loglevel fatal -stats'
alias ffprobe='ffprobe -hide_banner'
alias ffplay='ffplay -hide_banner'
alias flac-min='flac --silent --no-verbose'
alias spek='spek 2>/dev/null'
alias amdl='amdl -c ~/.config/amdl/config.yaml'
alias as="MTL_HUD_ENABLED=1 MTL_HUD_OPACITY=0.3 MTL_HUD_METRICS=fps open -a 'Astris'"
alias ssh='ssh -F "$XDG_CONFIG_HOME/ssh/config"'
alias mosh='mosh --ssh="ssh -F $HOME/.config/ssh/config"'


# ------------------------------------------
# Core utilities (原生工具安全增强)
# ------------------------------------------

# 给原生 grep 和 diff 加上色彩高亮 (不影响参数兼容性)
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

# 1. eza (现代 ls 替代品)
alias l='eza --icons=auto'                                                                                                           # ls
alias la='eza -a --icons=auto'                                                                                                       # ls -a             显示隐藏
alias ll='eza -lh --icons=auto --git -H --time-style="+%Y-%m-%d %H:%M"' lh='ll'                                                      # ls -l             显示详细
alias lla='eza -lah --icons=auto --git -H --time-style="+%Y-%m-%d %H:%M"' lal='lla' lah='lla'                                        # ls -al            显示隐藏+详细
alias llt='eza -lh --sort=modified --reverse --icons=auto -H --time-style="+%Y-%m-%d %H:%M"' ltl='llt' lht='llt' lht='llt'           # ls -lt            显示详细+时序
alias lls='eza -lh --sort=size --reverse --icons=auto -H --time-style="+%Y-%m-%d %H:%M"'                                             # 按大小降序

# 显示大小与精简列的 eza tree 别名函数
etr() {
  [[ "$1" =~ ^[0-9]+$ ]] && set -- -L "$1" "${@:2}"
  eza -l --tree --total-size \
      --no-permissions --no-user --no-time \
      --icons=auto --group-directories-first "$@"
}

# 2. 兼容 Linux/Mac 下 fd 命令名称
if command -v fdfind >/dev/null 2>&1; then
  alias fd='fdfind'
fi

# 3. zoxide
alias cd='z'