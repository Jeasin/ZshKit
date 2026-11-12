# =========================================================
# fzf 核心配置
# =========================================================

# 1. UI
export FZF_DEFAULT_OPTS='
--height=60%
--layout=reverse
--border=rounded
--prompt="  "
--pointer="  "
--preview-window=right:65%:wrap:border-left
'

# 2. 动态预览命令 (有 bat 用 bat，无 bat 用 cat)
if command -v bat >/dev/null 2>&1; then
  export _FZF_PREVIEW_CMD='bat --color=always --style=plain,numbers --line-range=:500 {}'
else
  export _FZF_PREVIEW_CMD='cat {}'
fi
export FZF_CTRL_T_OPTS="--preview '$_FZF_PREVIEW_CMD'"


# 3. 改 fd 为搜索引擎 (Ubuntu 则兼容为 fdfind)
if command -v fd >/dev/null 2>&1; then
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --strip-cwd-prefix'
elif command -v fdfind >/dev/null 2>&1; then
  export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --strip-cwd-prefix'
fi


# 4. fzf 默认 Ctrl-T 搜索 但改用 fd
export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"


# 5. fzf 自定 Ctrl+F 搜索 不包括隐藏文件 [Widget]
_fzf_file_no_hidden() {
  local cmd result
  cmd="${FZF_DEFAULT_COMMAND/--hidden /}"
  result=$(eval "${cmd:-find . -type f}" | fzf --preview "$_FZF_PREVIEW_CMD")
  if [[ -n "$result" ]]; then
    LBUFFER+="$result"
  fi
  zle reset-prompt
}

zle -N _fzf_file_no_hidden


# 6. 自定义 fzf 补全动作 (例如输入 cd **<TAB> 时触发)
export _fzf_compgen_dir() {
  fd --max-depth 1 --hidden --exclude ".git" . "$1"                            # 列表只生成当前目录第 1 层的文件夹/文件
}

_fzf_comprun() {
  local command=$1
  shift

  case "$command" in
    cd)
      if command -v eza >/dev/null 2>&1; then
        fzf --preview 'eza --tree --color=always --level=2 {}' "$@"            # 预览框用 tree 输出当前选中的层级
      elif command -v tree >/dev/null 2>&1; then
        fzf --preview 'tree -C -L 2 {}' "$@"
      else
        fzf --preview 'ls -la {}' "$@"
      fi
      ;;
    *)
      fzf --preview "$_FZF_PREVIEW_CMD" "$@"
      ;;
  esac
}

# 默认采用精确搜索（追加，不要覆盖上面的 UI 配置）
export FZF_DEFAULT_OPTS="$FZF_DEFAULT_OPTS --exact"