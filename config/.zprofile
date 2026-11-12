# Homebrew 环境
export HOMEBREW_NO_AUTO_UPDATE=1
eval "$(/opt/homebrew/bin/brew shellenv)"

# PATH 路径配置
typeset -U path
path=(
    ${HOME}/.local/share/uv/python/cpython-3.13.*/bin(N)
    ${HOME}/.local/bin
    ${HOME}/.local/bin/UnixBin
    "/Library/Input Methods/Fcitx5.app/Contents/bin"
    "/Applications/MKVToolNix.app/Contents/MacOS"
    "$CARGO_HOME/bin"
    "$(brew --prefix rustup)/bin"
    $path
)


# 自动任务
# 禁用坚果云 Finder 扩展
pluginkit -e ignore -i net.nutstore.osxapp.FinderSyncExtension >/dev/null 2>&1
