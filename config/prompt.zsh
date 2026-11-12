# 提示符：starship
if (( $+commands[starship] )); then
  eval "$(starship init zsh)"
fi

# ------------------------------------------
# 空回车后把上一行提示符刷灰
# 实现见 plugins/grayprompt.jeasin（GRAYPROMPT_OFF=1 可临时关掉）
# ------------------------------------------
