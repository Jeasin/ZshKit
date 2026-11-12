# XDG 基础目录
export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_CACHE_HOME="${HOME}/.cache"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"

# XDG RUST 目录
export CARGO_HOME="$XDG_DATA_HOME/cargo"
export RUSTUP_HOME="$XDG_DATA_HOME/rustup"

# 默认编辑器
export EDITOR="nano"
export VISUAL="nano"

# Pager
if command -v bat >/dev/null 2>&1; then
  export MANPAGER="bat -l man -p"
elif command -v batcat >/dev/null 2>&1; then
  export MANPAGER="batcat -l man -p"
fi

# Starship
export STARSHIP_CONFIG="$ZDOTDIR/starship.toml"


# ==========================================
# 用 XDG 哲学规范第三方 app 数据位置
# ==========================================

# export COPILOT_HOME="$XDG_CONFIG_HOME/copilot"
# export HOMEBREW_CACHE="$XDG_CACHE_HOME/Homebrew"
export TECTONIC_CACHE_DIR="$HOME/.cache/tectonic"