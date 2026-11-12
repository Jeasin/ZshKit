# ==========================================================
# ZshKit —— 交互式 Shell 主配置
#
# Plugins:  fast-syntax-highlighting, zsh-autosuggestions,
#           zsh-history-substring-search
# Prompt:   starship
# Tools:    zoxide, fzf, fd, eza, bat, ripgrep
# ==========================================================

# 历史记录（放 XDG_STATE_HOME，不跟随配置目录一起被替换）
HISTFILE="${XDG_STATE_HOME}/zsh/history"
HISTSIZE=100000
SAVEHIST=100000

setopt APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_FIND_NO_DUPS

# Shell 行为选项
setopt AUTO_CD
setopt NO_BEEP
setopt NUMERIC_GLOB_SORT
setopt INTERACTIVE_COMMENTS
PROMPT_EOL_MARK=""
unsetopt BANG_HIST

# ------------------------------------------
# 会话录制（自写插件：plugins/sessionlog.jeasin）
#
# 必须放在这里而不是 plugins.zsh 里：它可能要 exec 一层 pty 中继。
# 放在最前面，被 exec 掉的才只是一层空壳，内层 shell 做完整初始化。
# ------------------------------------------
[[ -r "$ZDOTDIR/plugins/sessionlog.jeasin/sessionlog.jeasin.plugin.zsh" ]] &&
  source "$ZDOTDIR/plugins/sessionlog.jeasin/sessionlog.jeasin.plugin.zsh"

# ------------------------------------------
# Completion 补全系统初始化
# ------------------------------------------
autoload -Uz compinit

[[ -d "$XDG_CACHE_HOME/zsh" ]] || mkdir -p "$XDG_CACHE_HOME/zsh"

# 24 小时内的 dump 走 -C 快路径
# 注意：[[ ]] 内不做文件名生成，(N.mh-24) 在那里不生效，必须用数组取长度
zcdump="$XDG_CACHE_HOME/zsh/zcompdump"
zcfresh=( $zcdump(N.mh-24) )
if (( $#zcfresh )); then
  compinit -C -d "$zcdump"
else
  compinit -d "$zcdump"
  zcompile "$zcdump"
fi
unset zcdump zcfresh

zstyle ':completion:*' use-cache on                                          # 开启补全的磁盘缓存
zstyle ':completion:*' cache-path "$XDG_CACHE_HOME/zsh/zcompcache"           # 缓存目录规范到 ~/.cache/zsh/
zstyle ':completion:*' menu select                                           # 补全菜单交互式选择
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'                    # 忽略大小写

# ------------------------------------------
# GnuPG pinentry 需要当前终端（非交互 shell 不该设，否则会写成 "not a tty"）
# ------------------------------------------
[[ -t 0 ]] && export GPG_TTY="$(tty)"

# ==========================================
# 第三方工具
# ==========================================

# zoxide
(( $+commands[zoxide] )) && eval "$(zoxide init zsh)"

# fzf（键位与补全脚本随 brew 安装，用 brew --prefix 定位，兼容 Intel）
_fzf_shell="$(brew --prefix 2>/dev/null)/opt/fzf/shell"
if [[ -r "$_fzf_shell/key-bindings.zsh" ]]; then
  source "$_fzf_shell/key-bindings.zsh"
  source "$_fzf_shell/completion.zsh"
fi
unset _fzf_shell

# ==========================================
# 配置文件引用加载
# ==========================================
for _f in aliases.zsh plugins.zsh fzf.zsh bindings.zsh prompt.zsh; do
  [[ -r "$ZDOTDIR/$_f" ]] && source "$ZDOTDIR/$_f"
done
unset _f

# 个人密钥（仓库里只有空模板；缺失也不影响启动）
if [[ -r "$ZDOTDIR/secrets.zsh" ]]; then
  source "$ZDOTDIR/secrets.zsh"
fi
