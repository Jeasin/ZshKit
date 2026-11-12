# ==========================================
# Keybindings Configuration
# ==========================================

# ------------------------------------------
# 1. 通用快捷键绑定（原生 Zsh）
# ------------------------------------------
_bind_general_keys() {

  # 基础文本编辑 & 光标移动
  bindkey '^[[1;5C' forward-word                                               # Ctrl + 右箭头 : 向前移动一个单词
  bindkey '^[[1;5D' backward-word                                              # Ctrl + 左箭头 : 向后移动一个单词

  # 历史记录搜索 (zsh-history-substring-search)
  bindkey '^[[A' history-substring-search-up                                   # 上箭头 : 按已输入子串向上搜历史
  bindkey '^[[B' history-substring-search-down                                 # 下箭头 : 按已输入子串向下搜历史

  # 自动建议 (zsh-autosuggestions)
  bindkey '^\' autosuggest-toggle                                              # Ctrl + \ : 开关/隐藏灰字建议

  # fzf 检索工具
  bindkey '^F' _fzf_file_no_hidden                                             # Ctrl + F : 触发 fzf 搜索非隐藏文件

}

# 当前（未安装 zsh-vi-mode 时）直接生效通用快捷键
_bind_general_keys


# ------------------------------------------
# 2. Vim / Vi 模式专属配置 (预留给 zsh-vi-mode)
# ------------------------------------------

# 光标形状与高亮设置 (只有安装了 zsh-vi-mode 才会读取)
ZVM_INSERT_MODE_CURSOR=$ZVM_CURSOR_BEAM
ZVM_NORMAL_MODE_CURSOR=$ZVM_CURSOR_BLOCK
ZVM_VISUAL_MODE_CURSOR=$ZVM_CURSOR_BLOCK

ZVM_VI_HIGHLIGHT_BACKGROUND=none
ZVM_VI_HIGHLIGHT_FOREGROUND=none
ZVM_VI_HIGHLIGHT_EXTRASTYLE=none

# Vi 模式专用 Hook：当 zsh-vi-mode 以后被激活时，强行把上面的通用按键重新接管回来
zvm_after_init() {
  _bind_general_keys
}