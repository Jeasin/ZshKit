# ==========================================================
# 键位绑定
# ==========================================================

# ------------------------------------------
# 1. 通用快捷键（原生 Zsh）
# ------------------------------------------
_bind_general_keys() {

  # 基础文本编辑 & 光标移动
  bindkey '^[[1;5C' forward-word                                               # Ctrl + 右箭头
  bindkey '^[[1;5D' backward-word                                              # Ctrl + 左箭头

  # 历史记录搜索（zsh-history-substring-search）
  # 不同终端发来的方向键序列不一样：Terminal.app 是 ^[[A，xterm 应用模式是 ^[OA，
  # terminfo 里 kcuu1 记的是后者。三套都绑上，谁先来都能命中。
  zmodload zsh/terminfo 2>/dev/null
  local _seq
  for _seq in '^[[A' '^[OA' "${terminfo[kcuu1]:-}"; do
    [[ -n $_seq ]] && bindkey "$_seq" history-substring-search-up
  done
  for _seq in '^[[B' '^[OB' "${terminfo[kcud1]:-}"; do
    [[ -n $_seq ]] && bindkey "$_seq" history-substring-search-down
  done

  # 自动建议（zsh-autosuggestions）
  bindkey '^\' autosuggest-toggle                                              # Ctrl + \

  # fzf 搜索非隐藏文件
  bindkey '^F' _fzf_file_no_hidden                                             # Ctrl + F
}

_bind_general_keys

# ------------------------------------------
# 2. Vi 模式（预留给 zsh-vi-mode，未启用时下面这些变量不生效）
# ------------------------------------------
ZVM_INSERT_MODE_CURSOR=$ZVM_CURSOR_BEAM
ZVM_NORMAL_MODE_CURSOR=$ZVM_CURSOR_BLOCK
ZVM_VISUAL_MODE_CURSOR=$ZVM_CURSOR_BLOCK

ZVM_VI_HIGHLIGHT_BACKGROUND=none
ZVM_VI_HIGHLIGHT_FOREGROUND=none
ZVM_VI_HIGHLIGHT_EXTRASTYLE=none

zvm_after_init() {
  _bind_general_keys
}
