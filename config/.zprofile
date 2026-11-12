# ==========================================================
# 登录 Shell 环境
#
# 只在登录 Shell 执行一次：Homebrew 环境 + PATH 装配。
# ==========================================================

export HOMEBREW_NO_AUTO_UPDATE=1

# Homebrew：Apple Silicon 在 /opt/homebrew，Intel 在 /usr/local
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# PATH 装配（typeset -U 自动去重）
typeset -U path
path=(
  ${HOME}/.local/share/uv/python/cpython-3.13.*/bin(N)
  ${HOME}/.local/bin
  ${HOME}/.local/bin/UnixBin
  "$CARGO_HOME/bin"
  $path
)

# 装过才有的目录，缺了就不该进 PATH
if (( $+commands[brew] )); then
  _rustup_prefix="$(brew --prefix rustup 2>/dev/null)" || _rustup_prefix=""
  [[ -d "$_rustup_prefix/bin" ]] && path=( "$_rustup_prefix/bin" $path )
  unset _rustup_prefix
fi
[[ -d "/Library/Input Methods/Fcitx5.app/Contents/bin" ]] &&
  path=( "/Library/Input Methods/Fcitx5.app/Contents/bin" $path )
[[ -d "/Applications/MKVToolNix.app/Contents/MacOS" ]] &&
  path=( "/Applications/MKVToolNix.app/Contents/MacOS" $path )

# 自动任务：禁用坚果云 Finder 扩展（没装坚果云就静默跳过）
if [[ -d /Applications/Nutstore.app || -d "$HOME/Nutstore Files" ]]; then
  pluginkit -e ignore -i net.nutstore.osxapp.FinderSyncExtension >/dev/null 2>&1
fi
