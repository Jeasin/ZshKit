# ~/.config/zsh/plugins.zsh

# 1. 插件根目录
ZPLUGINDIR="${ZDOTDIR:-$HOME/.config/zsh}/plugins"

# 2. 缺失即下载，然后加载
_zplugin_load() {
  local plugin_path="${ZPLUGINDIR}/${2}"
  if [[ ! -d "$plugin_path" ]]; then
    if (( ! $+commands[git] )); then
      print -u2 "zshkit: 缺插件 ${2}，但 PATH 里没有 git，无法自动下载"
      return 0
    fi
    mkdir -p "$ZPLUGINDIR"
    print "Installing ${2} ..."
    if ! git clone --depth=1 "https://github.com/${1}/${2}" "$plugin_path"; then
      print -u2 "zshkit: ${2} 下载失败，跳过（重开窗口会再试一次）"
      rm -rf "$plugin_path"
      return 0
    fi
  fi
  source "${plugin_path}/${2}.plugin.zsh"
}

# 3. 一键更新（只动有 .git 的第三方插件）
zplugin-update() {
  local dir
  for dir in "${ZPLUGINDIR}"/*(/N); do
    if [[ -d "$dir/.git" ]]; then
      print "Updating ${dir:t}..."
      git -C "$dir" pull --ff-only
    else
      print "Skipping ${dir:t}（自写插件，无 git 仓库）"
    fi
  done
}

# 4. 加载的插件（顺序有讲究，别随意调整）
_zplugin_load zdharma-continuum fast-syntax-highlighting             # 语法高亮
_zplugin_load zsh-users zsh-autosuggestions                          # 自动补全
_zplugin_load zsh-users zsh-history-substring-search                 # 历史搜索
# _zplugin_load jeffreytse zsh-vi-mode                               # nvim 模式使用 zsh



# ==========================================
# 自建插件（*.jeasin = 自己写的，随仓库一起安装）
# ==========================================
# 约定：$ZPLUGINDIR/<名字>.jeasin/<名字>.jeasin.plugin.zsh
# 放在这里统一 source，.zshrc 里不再逐个引用；新增自写插件只要建目录即可。
#
# 顺序很关键：必须晚于上面三个第三方插件。f-sy-h 和
# zsh-history-substring-search 都会包装 zle widget（bracketed-paste、
# zle-line-finish），后加载的才能正确链上去，否则会被它们的包装盖掉。
for _jeasin_p in "$ZPLUGINDIR"/*.jeasin/*.jeasin.plugin.zsh(N); do
  # sessionlog 是唯一例外：它要 exec 一层 pty 中继，必须放在 .zshrc 最顶部，
  # 否则被 exec 掉的那层会把本文件之后的内容（fzf / bindings / starship）
  # 再加载一遍。入口只有 .zshrc 顶部那一处。
  [[ $_jeasin_p == "$ZPLUGINDIR"/sessionlog.jeasin/* ]] && continue
  source "$_jeasin_p"
done
unset _jeasin_p

# 原 Terminal Logger（`exec script -Fq ...`）已移除：
# macOS 的 BSD script 不转发 SIGWINCH，内层 pty 尺寸和真实窗口脱钩后
# ZLE 会按旧列数排版 → 换行错位、吞字、光标乱飘。
# 录制能力由 plugins/sessionlog.jeasin 接管。
