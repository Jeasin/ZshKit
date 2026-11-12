# ==========================================================
# grayprompt.jeasin —— 空行回车后，把刚提交的那行提示符刷成灰色
#
# 效果：在空命令行上按回车，上面那一行（含 starship 的 Apple 图标）
#       会在命令输出前变灰，看起来像一条"空行"，把上一次输入和
#       这次的输出在视觉上分开。
#
# 挂的是 zle-line-finish（ZLE 结束、换行之前触发），不是 accept-line：
#   - 不劫持回车，所以 zsh-autosuggestions 的"回车接受建议"、
#     fast-syntax-highlighting 的高亮都不受影响；
#   - 此刻光标就在提示符末尾，$BUFFER / $POSTDISPLAY 还是最新值。
#
# 用 add-zle-hook-widget 挂，而不是 `zle -N zle-line-finish`：
#   fast-syntax-highlighting（"Always wrap special zle-line-finish widget"）
#   和 zsh-history-substring-search 都占用这个 widget，直接 zle -N 会把它们
#   顶掉——高亮插件收不到"本行结束"的通知，粘贴/行尾的临时高亮不会及时收尾。
#   add-zle-hook-widget 会把已有 widget 存成 hook #0 再串在后面。
#
# 和最早那版（写在 prompt.zsh 里，已移除）的区别：
#   1. 不再 `print -P "$PROMPT" | sed` —— 每次回车 fork 两个进程，
#      宽度也算不准。现在用 ${(%%)PROMPT} 在 shell 内展开、
#      用模式替换剥 ANSI，零 fork。
#   2. 补 `\e[K`：清掉行尾残留，不会"灰色提示符后面粘着旧字"。
#   3. 按 $COLUMNS 算提示符占几行；折行时先 \e[nA 回到首行再重绘。
#   4. 写 stdout（ZLE 正在用的 fd），不和 starship 的重绘抢同一行。
#
# 代价：starship 的 PROMPT 是 `$(starship prompt ...)` 模板，重绘必须
# 再渲染一次，实测每次空回车多 ~18ms（只在空回车时发生）。
#
# 可调：
#   GRAYPROMPT_RGB="56;66;75"   灰色（默认 #38424B）
#   export GRAYPROMPT_OFF=1     临时关掉；unset 即恢复
# ==========================================================

# #38424B
typeset -g GRAYPROMPT_RGB=${GRAYPROMPT_RGB:-"56;66;75"}

_jeasin_gray_repaint() {
  emulate -L zsh
  setopt local_options extended_glob prompt_subst

  # 展开成终端里真正显示的那串：starship 的 PROMPT 是命令替换模板，
  # 需要 (%%) 两次展开（第一次执行 $(...)，第二次消化输出里的 % 转义）。
  local text=${(%%)PROMPT}
  text=${text//$'\e'\[[0-9;?]#[a-zA-Z]/}     # CSI（颜色/光标）
  text=${text//$'\e'[@-_]/}                  # 其余单字节 ESC
  # OSC（ESC ] ... BEL）starship 不用在 PROMPT 里，这里不处理

  local cols=${COLUMNS:-80}
  (( cols > 0 )) || return 0

  local -a lines
  lines=( "${(@f)text}" )
  local line lw rows=0
  for line in "${lines[@]}"; do
    lw=${(m)#line}
    if (( lw > 0 )); then
      rows=$(( rows + (lw + cols - 1) / cols ))
    else
      rows=$(( rows + 1 ))
    fi
  done
  (( rows > 0 )) || return 0

  local up=$(( rows - 1 ))
  print -rn -- $'\r'
  (( up > 0 )) && print -rn -- $'\e['"$up"'A'
  print -rn -- $'\e[38;2;'"$GRAYPROMPT_RGB"'m'"$text"$'\e[0m\e[K'
  return 0
}

_jeasin_gray_line_finish() {
  [[ -n $GRAYPROMPT_OFF ]] && return 0
  # 只在"空行"上动手：有内容或还挂着 ghost text 就不碰
  [[ -z $BUFFER && -z $POSTDISPLAY ]] && _jeasin_gray_repaint
  return 0
}

if [[ -o interactive ]]; then
  if (( $+functions[add-zle-hook-widget] )) || autoload -Uz add-zle-hook-widget 2>/dev/null; then
    add-zle-hook-widget zle-line-finish _jeasin_gray_line_finish 2>/dev/null \
      || zle -N zle-line-finish _jeasin_gray_line_finish 2>/dev/null
  else
    zle -N zle-line-finish _jeasin_gray_line_finish 2>/dev/null
  fi
fi
