# ==========================================================
# XDG 基础目录
#
# 这个文件由 /etc/zshenv 引导后才生效（见 system/zshenv）：
# /etc/zshenv 设好 ZDOTDIR，zsh 才会来这里读 .zshenv。
# ==========================================================

export XDG_CONFIG_HOME="${HOME}/.config"
export XDG_CACHE_HOME="${HOME}/.cache"
export XDG_DATA_HOME="${HOME}/.local/share"
export XDG_STATE_HOME="${HOME}/.local/state"

# XDG RUST 目录
export CARGO_HOME="$XDG_DATA_HOME/cargo"
export RUSTUP_HOME="$XDG_DATA_HOME/rustup"

# 默认编辑器（已有环境变量时不覆盖）
export EDITOR="${EDITOR:-nano}"
export VISUAL="${VISUAL:-$EDITOR}"

# Pager
if command -v bat >/dev/null 2>&1; then
  export MANPAGER="bat -l man -p"
elif command -v batcat >/dev/null 2>&1; then
  export MANPAGER="batcat -l man -p"
fi

# Starship
export STARSHIP_CONFIG="${ZDOTDIR:-$XDG_CONFIG_HOME/zsh}/starship.toml"

# ==========================================
# 用 XDG 哲学规范第三方 app 数据位置
# ==========================================

# export COPILOT_HOME="$XDG_CONFIG_HOME/copilot"
# export HOMEBREW_CACHE="$XDG_CACHE_HOME/Homebrew"
export TECTONIC_CACHE_DIR="$XDG_CACHE_HOME/tectonic"
