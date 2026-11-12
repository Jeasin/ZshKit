#!/bin/sh
# ==========================================================
# ZshKit installer —— 一键安装 / 全量同步
#
#   curl -fsSL https://raw.githubusercontent.com/Jeasin/ZshKit/main/install.sh | zsh
#
# 行为：下载 main 分支最新配置 → 全量替换 ~/.config/zsh 与 /etc/zshenv。
# 不做合并、不备份、不迁移历史与缓存。
# ==========================================================
set -Eeuo pipefail

REPO="${ZSHKIT_REPO:-Jeasin/ZshKit}"
REF="${ZSHKIT_REF:-main}"
CONFIG_DIR="$HOME/.config/zsh"
ETC_DIR="${ZSHKIT_ETC_DIR:-/etc}"          # 仅测试用
TARBALL_URL="${ZSHKIT_TARBALL:-https://codeload.github.com/${REPO}/tar.gz/refs/heads/${REF}}"

# 配置正常工作所需的外部命令（对应 Homebrew formula，rg → ripgrep）
# 注意：这里必须写成字面量列表。zsh 默认不做单词切分，不能靠变量展开
# 得到多个词，否则循环只会跑一次。

TMP=""
ETC_TMP=""
SUDO=""

# ----------------------------------------------------------
# 输出
# ----------------------------------------------------------
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

info()  { printf '%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
step()  { printf '%s[%s]%s %s\n' "$C_DIM"    "$1" "$C_RESET" "$2"; }
die()   { printf '%serror%s %s\n' "$C_RED"  "$C_RESET" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------------------------------------
# 清理
# ----------------------------------------------------------
cleanup() {
  if [ -n "${ETC_TMP:-}" ] && [ -e "${ETC_TMP:-/nonexistent}" ]; then
    if [ -n "${SUDO:-}" ]; then $SUDO rm -f "$ETC_TMP" 2>/dev/null || true
    else rm -f "$ETC_TMP" 2>/dev/null || true; fi
  fi
  if [ -n "${TMP:-}" ] && [ -d "${TMP:-/nonexistent}" ]; then
    rm -rf "$TMP" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM HUP

# ----------------------------------------------------------
printf '\n%s ZshKit%s · macOS Zsh 配置一键安装\n\n' "$C_BLUE" "$C_RESET"

warn "即将覆盖以下内容，不会备份、不会合并："
printf '       · %s\n' "$CONFIG_DIR"
printf '       · %s/zshenv\n' "$ETC_DIR"
warn "保留：~/.local/share、~/.local/state（含历史）、~/.cache"
printf '\n'

# ----------------------------------------------------------
# 1. 环境检测
# ----------------------------------------------------------
step 1/9 "检测环境"

[ "$(uname -s)" = "Darwin" ] || die "这是一个 macOS 配置，当前系统：$(uname -s)"
ok "macOS $(sw_vers -productVersion 2>/dev/null || echo unknown)"

have zsh || die "找不到 zsh（macOS 自带 /bin/zsh，请检查 PATH）"
ok "zsh $("$(command -v zsh)" -c 'echo $ZSH_VERSION' 2>/dev/null || echo unknown)"

case "$(uname -m)" in
  arm64)  ARCH_HINT="/opt/homebrew" ;;
  x86_64) ARCH_HINT="/usr/local" ;;
  *)      ARCH_HINT="/opt/homebrew 或 /usr/local" ;;
esac
ok "架构 $(uname -m)（Homebrew 预期在 $ARCH_HINT）"

BREW=""
for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -x "$p" ]; then BREW="$p"; break; fi
done
[ -n "$BREW" ] || die "未找到 Homebrew。先安装：
       /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
       然后重新运行本脚本。"
eval "$("$BREW" shellenv)"
ok "Homebrew $(brew --version | head -1 | cut -d' ' -f2) @ $(brew --prefix)"
export HOMEBREW_NO_AUTO_UPDATE=1

# ----------------------------------------------------------
# 2. 权限
# ----------------------------------------------------------
step 2/9 "检查写入权限"

if [ -w "$ETC_DIR" ]; then
  SUDO=""
  ok "$ETC_DIR 可写，无需 sudo"
else
  have sudo || die "需要 sudo 修改 $ETC_DIR/zshenv，但系统没有 sudo"
  info "修改 $ETC_DIR/zshenv 需要管理员权限"
  sudo -v || die "未能获取 sudo 权限"
  SUDO="sudo"
  ok "sudo 凭据已获取"
fi

# ----------------------------------------------------------
# 3. 临时目录
# ----------------------------------------------------------
step 3/9 "创建临时目录"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/zshkit.XXXXXXXX")" || die "创建临时目录失败"
ok "$TMP"

# ----------------------------------------------------------
# 4. 下载
# ----------------------------------------------------------
step 4/9 "下载 ${REPO}@${REF}"

downloaded=0
for url in "$TARBALL_URL" "https://github.com/${REPO}/archive/refs/heads/${REF}.tar.gz"; do
  case "$url" in
    file://*|/*) info "本地源：$url" ;;
    *)           info "抓取：$url" ;;
  esac
  if curl -fsSL --retry 3 --retry-delay 1 --connect-timeout 20 --max-time 300 \
       -o "$TMP/src.tar.gz" "$url"; then
    downloaded=1
    break
  fi
  warn "这个地址失败，换下一个"
done
[ "$downloaded" = "1" ] || die "下载失败：仓库 ${REPO} 的 ${REF} 分支不可达"

[ -s "$TMP/src.tar.gz" ] || die "下载到的文件为空"
ok "$(wc -c < "$TMP/src.tar.gz" | tr -d ' ') 字节"

# ----------------------------------------------------------
# 5. 解压
# ----------------------------------------------------------
step 5/9 "解压"

tar -xzf "$TMP/src.tar.gz" -C "$TMP" || die "解压失败（文件可能损坏）"

SRC=""
for d in "$TMP"/*/; do SRC="${d%/}"; break; done
[ -n "$SRC" ] || die "解压后找不到源码目录"
[ -f "$SRC/install.sh" ] && [ -d "$SRC/config" ] || die "压缩包结构异常，缺少 config/"

missing=""
for f in .zshenv .zprofile .zshrc aliases.zsh bindings.zsh fzf.zsh plugins.zsh prompt.zsh; do
  [ -f "$SRC/config/$f" ] || missing="$missing $f"
done
[ -z "$missing" ] || die "压缩包缺少配置：$missing"

for p in fast-syntax-highlighting zsh-autosuggestions zsh-history-substring-search; do
  [ -d "$SRC/config/plugins/$p" ] || die "压缩包缺少插件：$p"
done
ok "配置与插件完整"

# ----------------------------------------------------------
# 6. 依赖
# ----------------------------------------------------------
step 6/9 "检查并安装依赖"

installed_now=""
for cmd in starship zoxide fzf fd eza bat rg; do
  if have "$cmd"; then continue; fi
  case "$cmd" in
    rg) formula="ripgrep" ;;
    *)  formula="$cmd" ;;
  esac
  if brew list --formula "$formula" >/dev/null 2>&1; then
    ok "$formula 已安装（只是不在 PATH）"
    continue
  fi
  info "安装 $formula ..."
  brew install "$formula" || die "安装 $formula 失败，请手动执行 brew install $formula"
  installed_now="$installed_now $formula"
done
if [ -n "$installed_now" ]; then
  ok "新装：$installed_now"
else
  ok "依赖齐全"
fi

# ----------------------------------------------------------
# 7. 准备新配置（先在同分区做暂存目录，方便原子替换）
# ----------------------------------------------------------
step 7/9 "准备新配置"

mkdir -p "$HOME/.config"
STAGE="$HOME/.config/.zshkit-new.$$"
rm -rf "$STAGE"
mkdir -p "$STAGE"

cp -R "$SRC/config/." "$STAGE/" || die "复制配置失败"
chmod 755 "$STAGE"
chmod 644 "$STAGE"/*.zsh "$STAGE"/.zshenv "$STAGE"/.zprofile "$STAGE"/.zshrc 2>/dev/null || true
find "$STAGE" -name '.DS_Store' -delete 2>/dev/null || true

# 写入前校验：语法
for f in .zshenv .zprofile .zshrc aliases.zsh bindings.zsh fzf.zsh plugins.zsh prompt.zsh secrets.zsh; do
  zsh -n "$STAGE/$f" || { rm -rf "$STAGE"; die "语法检查失败：$f"; }
done
ok "9 个配置语法通过"

# 写入前校验：不能夹带个人信息
if grep -rq "/Users/jeasinl" "$STAGE" 2>/dev/null; then
  rm -rf "$STAGE"
  die "配置里仍有个人绝对路径 /Users/jeasinl，已中止"
fi
ok "无个人绝对路径"

# 写入前校验：XDG 路径与引导文件一致
grep -q 'ZDOTDIR=' "$SRC/system/zshenv" || die "system/zshenv 缺少 ZDOTDIR 引导"

# ----------------------------------------------------------
# 8. 替换配置 + /etc/zshenv
# ----------------------------------------------------------
step 8/9 "替换配置"

if [ -e "$CONFIG_DIR" ] || [ -L "$CONFIG_DIR" ]; then
  OLD="$HOME/.config/.zshkit-old.$$"
  rm -rf "$OLD"
  mv "$CONFIG_DIR" "$OLD" || { rm -rf "$STAGE"; die "无法移走旧配置"; }
  mv "$STAGE" "$CONFIG_DIR" || { mv "$OLD" "$CONFIG_DIR"; die "新配置落位失败，已回滚"; }
  rm -rf "$OLD"
  ok "已替换 $CONFIG_DIR（旧的已移除）"
else
  mv "$STAGE" "$CONFIG_DIR" || die "新配置落位失败"
  ok "已安装 $CONFIG_DIR"
fi

ETC_TMP="$ETC_DIR/.zshenv.zshkit.$$"
if [ -n "$SUDO" ]; then
  $SUDO install -o root -g wheel -m 644 "$SRC/system/zshenv" "$ETC_TMP" || die "写入 $ETC_TMP 失败"
  $SUDO mv -f "$ETC_TMP" "$ETC_DIR/zshenv" || die "替换 $ETC_DIR/zshenv 失败"
else
  install -m 644 "$SRC/system/zshenv" "$ETC_TMP" || die "写入 $ETC_TMP 失败"
  mv -f "$ETC_TMP" "$ETC_DIR/zshenv" || die "替换 $ETC_DIR/zshenv 失败"
fi
ETC_TMP=""
ok "已替换 $ETC_DIR/zshenv"

# ----------------------------------------------------------
# 9. XDG 目录 + 验收
# ----------------------------------------------------------
step 9/9 "创建 XDG 目录并验收"

for d in "$HOME/.local/bin" "$HOME/.local/share" "$HOME/.local/state/zsh" "$HOME/.cache"; do
  mkdir -p "$d"
done
ok "XDG 目录就绪"

# 引导是否真的生效：干净环境里开一个 zsh，看 ZDOTDIR
got_zdotdir="$(env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TERM=dumb \
  /bin/zsh -c 'printf "%s" "$ZDOTDIR"' 2>/dev/null || true)"
if [ "$got_zdotdir" = "$CONFIG_DIR" ]; then
  ok "ZDOTDIR → $got_zdotdir"
else
  warn "ZDOTDIR 解析为 [${got_zdotdir:-空}]，预期 $CONFIG_DIR"
fi

# 依赖复查
still_missing=""
for cmd in starship zoxide fzf fd eza bat rg; do
  have "$cmd" || still_missing="$still_missing $cmd"
done

# 再用新配置真跑一次交互 shell（不录会话），确认没有启动报错
shell_err="$(ZSH_NO_SESSION_LOG=1 env ZDOTDIR="$CONFIG_DIR" HOME="$HOME" PATH="$PATH" \
  /bin/zsh -i -c 'exit' 2>&1 || true)"
if [ -n "$shell_err" ]; then
  warn "启动时输出了下列内容（可能是提示信息）："
  printf '       %s\n' "$shell_err"
else
  ok "交互式启动无报错"
fi

printf '\n'
if [ -n "$still_missing" ]; then
  warn "以下命令仍不可用：$still_missing"
else
  ok "关键依赖齐全"
fi

printf '\n%s安装完成%s\n\n' "$C_GREEN" "$C_RESET"
printf '  下一步：%s新开一个终端窗口%s（当前窗口仍是旧配置）\n' "$C_YELLOW" "$C_RESET"
printf '  更新：  重新执行同一条 curl 命令即可全量同步\n'
printf '  密钥：  %s 目前是空模板\n' "$CONFIG_DIR/secrets.zsh"
printf '  卸载：  rm -rf %s，并恢复 %s/zshenv\n\n' "$CONFIG_DIR" "$ETC_DIR"
