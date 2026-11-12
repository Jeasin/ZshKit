# 初始化 Starship 主题
eval "$(starship init zsh)"

# ------------------------------------------
# 【已移出】empty-line-gray-prompt
# ------------------------------------------
# 「空回车后把上一行提示符刷灰」这个效果没有取消，而是重做后搬到了
# plugins/grayprompt.jeasin/。原来那版的问题（重打到 stderr、不清行尾、
# 不按 $COLUMNS 算折行、和 starship 抢同一行）在新实现里都处理了。
#
# 想临时关掉：GRAYPROMPT_OFF=1 zsh 或 export GRAYPROMPT_OFF=1
# 想改灰色：GRAYPROMPT_RGB="120;120;120"（默认 56;66;75 = #38424B）

# 提示符前留白（可选）：add_newline 已在 starship.toml 里设为 false，
# 这里不再额外输出空行，保持与之前观感一致。
