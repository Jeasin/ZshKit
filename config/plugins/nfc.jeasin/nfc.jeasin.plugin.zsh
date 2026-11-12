# ==========================================
# nfc.jeasin —— 拖入/粘贴进来的分解形（NFD）文本，归一化为合成形（NFC）
#
# 加载：由 plugins.zsh 末尾统一 source（必须晚于 fast-syntax-highlighting，
#       否则链式包装会反过来被它盖掉）。关闭：export ZSH_NO_NFC_FIX=1
#
# 现象：把文件拖进 Terminal 时，若路径里有分解形韩文
#       （괜 = U+1100 U+116B U+11AB 三个码点），长命令一折行就吞字、
#       内容重复、Ctrl+U 清行留残影。
#
# 原因：zsh 的 ZLE 按码点算列宽，而 macOS 的字体把 L+V+T 合成一个 2 列宽的字。
#       zsh 每来一个 jamo 就退格重画一次合成簇，光标记账越走越偏。
#       一旦偏了，后面所有增量重绘都画在错误的列上——所以「画完再修」没用：
#       改完 $BUFFER 还得整行重画，而重画本身在折行处又是错的。
#
# 做法：在 bracketed-paste（括号粘贴）widget 里，插入完成、还没绘制之前就归一化。
#       Terminal.app 从 10.7 起支持括号粘贴，拖拽文件和 ⌘V 粘贴都走这条路，
#       所以屏幕上一次都不会画出 jamo，光标记账从一开始就是对的。
#
# APFS 对归一化不敏感：NFC 写法可以直接打开磁盘上 NFD 名字的文件，
# 所以磁盘上的文件名一个字节都不动，Navidrome 也不用重扫。
#
# 关闭：export ZSH_NO_NFC_FIX=1
# ==========================================

[[ -n $ZSH_NO_NFC_FIX ]] && return
(( $+commands[iconv] )) || return

# 非 UTF-8 locale 下构造 \uXXXX 会报 "character not in range"，直接跳过
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
  *) return ;;
esac

# 防重复加载：zsh-autosuggestions 会在首个 precmd 把 bracketed-paste 又包一层
# （<...>_bracketed-paste → _zle_nfc_paste）。此处若再复制一次当前 widget，
# 复制到的就是那个包装器，会形成自调用死循环。
(( ${+_JEASIN_NFC_LOADED} )) && return
typeset -g _JEASIN_NFC_LOADED=1

# 分解形特征：韩文字母 jamo + 组合附加符
typeset -g _zle_nfc_pat='*['$'\u1100'$'-\u11ff'$'\u0300'$'-\u036f'$'\u1ab0'$'-\u1aff'$'\u1dc0'$'-\u1dff'$'\u20d0'$'-\u20ff'$'\ufe20'$'-\ufe2f'$'\ua960'$'-\ua97f'$'\ud7b0'$'-\ud7ff'']*'

# 把 $BUFFER 归一化为 NFC，并同步 $CURSOR。返回 0 表示确实改了。
_zle_nfc_normalize() {
  local norm head
  norm=$(print -rn -- "$BUFFER" | iconv -f UTF-8-MAC -t UTF-8 2>/dev/null) || return 1
  [[ $norm == "$BUFFER" ]] && return 1
  if (( CURSOR < ${#BUFFER} )); then
    head=${BUFFER[1,CURSOR]}
    head=$(print -rn -- "$head" | iconv -f UTF-8-MAC -t UTF-8 2>/dev/null)
    BUFFER=$norm
    CURSOR=${#head}
  else
    BUFFER=$norm
  fi
  return 0
}

# fast-syntax-highlighting 会把 bracketed-paste 包一层，在 widget 返回后
# 重算语法高亮（路径存在时画紫色下划线就是它给的）。直接 zle -N 覆盖会把
# 这层顶掉，粘贴后整行退回纯文本色，要再按一个键才恢复。所以先把当前定义
# 存成另一个名字，改成链式调用。
zmodload zsh/zleparameter 2>/dev/null
if (( ! ${+widgets[_zle_nfc_base_paste]} )); then
  zle -A bracketed-paste _zle_nfc_base_paste 2>/dev/null
fi

# 粘贴：先让 zsh 把内容放进缓冲区，再归一化。改动发生在下一次绘制之前，
# 所以终端上永远不会出现 jamo。
_zle_nfc_paste() {
  emulate -L zsh
  if (( ${+widgets[_zle_nfc_base_paste]} )); then
    zle _zle_nfc_base_paste        # 原来的链：粘贴 + 语法高亮
  else
    zle .bracketed-paste
  fi

  [[ $BUFFER == ${~_zle_nfc_pat} ]] || return 0
  _zle_nfc_normalize || return 0

  # 归一化后码点变少，上一轮按旧长度算出的 region_highlight 全部错位：
  # 重算一次，下划线才会落在正确的字上。
  (( $+functions[_zsh_highlight] )) && _zsh_highlight
}
zle -N bracketed-paste _zle_nfc_paste
