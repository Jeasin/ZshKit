# ==========================================================
# sessionlog.jeasin —— 终端会话录制（自写插件）
#
# 替代原来 plugins.zsh 里那句 `exec script -Fq ...`。
# 原因：macOS 自带的 /usr/bin/script 不把 SIGWINCH 转发给内层 pty，
#       窗口一变尺寸，shell 的 COLUMNS 就和真实宽度脱钩，
#       ZLE 按旧列数排版 → 换行错位、吞字、光标乱飘。
#
# 实现：src/zslog.c 编成独立可执行文件（缓存在 $XDG_CACHE_HOME/zsh/bin）。
#       它每次收到 SIGWINCH 都把真实窗口尺寸 ioctl 进内层 pty，列宽永远对。
#       用 C 而不是 python：启动 1ms 而不是 80ms；而且 Terminal.app 的标题
#       取前台进程名，独立可执行文件只显示 "zslog"，不会把一整串 python
#       命令行顶到窗口标题上。
#
# 每条会话出两个文件：
#
#   20261104-163931_which-brew-ls.log   人读版
#       屏幕上最后剩下的内容，纯文本，没有转义序列。
#       任何编辑器 / cat / grep / 发微信都能直接看：
#       进度条只剩最后状态，ZLE 的逐键重绘已经合成一行，clear 之前的历史
#       也留着（日志不该因为一条 clear 就少一半）。开头几行 # 是索引。
#
#   20261104-163931_which-brew-ls.rec   原始字节流
#       终端收到的每一个字节，含颜色、光标移动、清屏。不给人看，
#       是 zslog-cat 还原现场用的底片。删了不影响 .log。
#
# 两个顺手的处理：
#   · 长行不硬切：终端窄的时候，一行文字会被自动折到下一行，那不是真的
#     换行。.log 会把折出来的续行接回去，整行还是一整行 —— 把日志拖到更宽
#     的窗口看，右边不会毫无理由地断掉。只有真正回车才算换行。
#   · CPR 应答只捡没人要的：终端对 ESC[6n（查光标位置）的应答有时晚到，
#     落在没人读它的时候就会被当成键盘输入，命令行上冒出一串 "1R 7R"，甚至
#     被当命令执行。但 fzf / vim 这类程序是真的在等这个应答，吞了它们就得
#     超时降级（fzf 变慢、还会去问 DECRQM，在 Terminal.app 上冒出个 p）。
#     所以按"配对"处理：程序发过一次 ESC[6n，就放行一次应答；没人认领的才
#     丢掉。ZSLOG_KEEP_CPR=1 可以完全关掉这层过滤。
#
# 用法：
#   zslog-ls            列出录制文件
#   zslog-cat [FILE]    在终端里还原当时的样子（带颜色），默认本窗口那条
#                       --plain  只要文字，不要颜色（管道/复制用）
#   zslog-now           当前窗口正在写哪个文件
#
# 文件命名：$ZSH_SESSIONLOG_DIR/20261104-163931_which-brew-ls.log
#   后缀在退出时补上（会话中先叫 20261104-163931），
#   默认取 首个命令-最频繁命令-最后命令，相邻相同的段合并，
#   没那么多命令就只写一两段，不硬凑。
#
# 窗口标题：<时间戳> · <同一个后缀>，与文件名一一对应，不显示进程和路径。
#
# 开关：
#   ZSH_NO_SESSION_LOG=1        本次不录
#   ZSH_SESSIONLOG_KEEP_DAYS=N  保留天数，默认 14，0 = 不自动清理
#   ZSH_SESSIONLOG_NAME_RULE=   后缀规则：
#                               mix(默认，首个-最频繁-最后)
#                               top(只写最频繁) / last(只写最后) / first(只写首个) / none
#
# 本文件必须由 .zshrc 早于其余初始化 source：
# 这样被 exec 掉的只是空壳，内层 shell 才做完整初始化（不会跑两遍）。
# ==========================================================

typeset -g ZSH_SESSIONLOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zsh/logs"
typeset -g ZSH_SESSIONLOG_BIN="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/bin/zslog"
typeset -g ZSH_SESSIONLOG_SRC="${0:A:h}/src/zslog.c"

typeset -gA _zslog_count _zslog_last _zslog_first
typeset -gi _zslog_seq=0

# ---- 编译（源码比二进制新才重编，失败就跳过录制） ----------------
_zslog_build() {
  [[ -f $ZSH_SESSIONLOG_SRC ]] || return 1
  [[ -x $ZSH_SESSIONLOG_BIN && $ZSH_SESSIONLOG_BIN -nt $ZSH_SESSIONLOG_SRC ]] && return 0
  (( $+commands[cc] )) || return 1
  mkdir -p "${ZSH_SESSIONLOG_BIN:h}" || return 1
  local tmp="$ZSH_SESSIONLOG_BIN.$$.tmp"
  if cc -O2 -o "$tmp" "$ZSH_SESSIONLOG_SRC" 2>/dev/null; then
    mv -f "$tmp" "$ZSH_SESSIONLOG_BIN" && return 0
  fi
  rm -f "$tmp"
  return 1
}

# ---- 查看工具 -------------------------------------------------
zslog-now() {
  local log=$ZSH_SESSIONLOG_CURRENT rec=$ZSH_SESSIONLOG_REC
  if [[ -n $rec && -f $rec && ! -f $log ]]; then
    print -r -- "$rec"
    print -r -- "（正在录制；退出后写成 ${log:t}）"
    return 0
  fi
  print -r -- "${log:-（当前窗口没有在录制）}"
}

# 一个会话算一条：有 .log 报 .log；只有 .rec（异常退出没渲染）也列出来
_zslog_files() {
  setopt local_options null_glob
  local f
  for f in "$ZSH_SESSIONLOG_DIR"/*(.om); do
    case $f in
      *.log) print -r -- "$f" ;;
      *.rec) [[ -f ${f%.rec}.log ]] || print -r -- "$f" ;;
    esac
  done
}

zslog-ls() {
  [[ -d $ZSH_SESSIONLOG_DIR ]] || { print -r -- "还没有录制文件（$ZSH_SESSIONLOG_DIR）"; return 1 }
  local -a files=( ${(f)"$(_zslog_files)"} )
  (( $#files )) || { print -r -- "还没有录制文件"; return 1 }
  local f note
  for f in $files; do
    note=''
    [[ $f == *.rec ]] && note='  ← 没渲染（异常退出），可直接 zslog-cat'
    printf '%s  %7s  %s%s\n' "$(date -r $f '+%Y-%m-%d %H:%M')" "$(du -h "$f" | cut -f1)" "${f:t}" "$note"
  done
}

zslog-cat() {
  local file='' arg when=auto
  local -a extra
  for arg in "$@"; do
    case $arg in
      --plain|--no-color) when=off ;;
      --color) when=on ;;
      *) if [[ -f $arg ]]; then file=$arg; else extra+=( "$arg" ); fi ;;
    esac
  done

  if [[ -z $file ]]; then
    if [[ -n $ZSH_SESSIONLOG_REC && -f $ZSH_SESSIONLOG_REC ]]; then
      file=$ZSH_SESSIONLOG_REC                 # 本窗口正在录，就看这一条
    else
      local -a files=( ${(f)"$(_zslog_files)"} )
      (( $#files )) || { print -ru2 -- "没有录制文件"; return 1 }
      file=$files[1]
    fi
  fi

  # 有同名 .rec 就用原始流：颜色、底色、TUI 都能还原；
  # 只有 .log 时它本身就是干净文本，clean 一遍等于原样输出（对旧日志也成立）。
  local src=$file
  if [[ $file == *.log && -f ${file%.log}.rec ]]; then
    src=${file%.log}.rec
  fi

  if ! _zslog_build; then
    print -ru2 -- "没有可用的 zslog 二进制，退化为原样输出"
    cat -v -- "$src" | less
    return 0
  fi

  local -a opts=( clean "$src" --cols "${COLUMNS:-120}" )
  case $when in
    off) opts+=( --plain ) ;;
    on)  opts+=( --color ) ;;
    *)   [[ -t 1 ]] && opts+=( --color ) ;;
  esac

  if [[ -t 1 ]]; then
    # less 668 起把 Private Use Area 当成"不可打印"，starship 的 Apple 图标、
    # Nerd Font 图标会被显示成 <U+F179>。告诉 less 那是正常字符（宽度 1）。
    local def='E000-F8FF:p,F0000-FFFFD:p,100000-10FFFD:p'
    "$ZSH_SESSIONLOG_BIN" "${opts[@]}" \
      | LESSUTFCHARDEF=${LESSUTFCHARDEF:-$def} less -R
  else
    "$ZSH_SESSIONLOG_BIN" "${opts[@]}"
  fi
}

# ---- 自动清理 -------------------------------------------------
_zslog_prune() {
  local keep=${ZSH_SESSIONLOG_KEEP_DAYS:-14}
  [[ $keep == <-> ]] || keep=14
  (( keep > 0 )) || return 0
  [[ -d $ZSH_SESSIONLOG_DIR ]] || return 0
  find "$ZSH_SESSIONLOG_DIR" -maxdepth 1 -type f \
    \( -name '*.log' -o -name '*.rec' -o -name '*.rec.meta' \) \
    -mtime +"$keep" -delete 2>/dev/null
}

# ---- 录制中（内层 shell）才挂的钩子 ----------------------------
_zslog_preexec() {
  local -a words
  local w
  words=( ${=1} )
  for w in $words; do
    [[ $w == *=* ]] && continue
    break
  done
  [[ -n $w && $w != [-*]* ]] || return 0
  w=${w:t}
  # 这些不算"这个窗口在干什么"，别让它们抢走文件名的后缀
  case $w in
    exit|logout|clear|reset|history|cd|pwd) return 0 ;;
  esac
  (( _zslog_seq++ ))
  (( _zslog_count[$w]++ ))
  _zslog_last[$w]=$_zslog_seq
  (( ${+_zslog_first[$w]} )) || _zslog_first[$w]=$_zslog_seq
  return 0
}

# 单个规则取一个命令名：first / top / last
_zslog_pick_one() {
  local rule=$1 k best=''
  (( $#_zslog_count )) || return 1
  case $rule in
    last)
      for k in ${(k)_zslog_last}; do
        [[ -z $best || ${_zslog_last[$k]} -gt ${_zslog_last[$best]} ]] && best=$k
      done ;;
    first)
      for k in ${(k)_zslog_first}; do
        [[ -z $best || ${_zslog_first[$k]} -lt ${_zslog_first[$best]} ]] && best=$k
      done ;;
    *)
      for k in ${(k)_zslog_count}; do
        if [[ -z $best ]] \
          || (( ${_zslog_count[$k]} > ${_zslog_count[$best]} )) \
          || { (( ${_zslog_count[$k]} == ${_zslog_count[$best]} )) \
               && (( ${_zslog_last[$k]} > ${_zslog_last[$best]} )); }; then
          best=$k
        fi
      done ;;
  esac
  [[ -n $best ]] || return 1
  print -r -- "$best"
}

# 文件名后缀。默认 mix = 首个-最频繁-最后，最多三段：
#   which brew brew ls  →  which-brew-ls
#   只有一条命令        →  一段，不硬凑
#   相邻相同的段合并    →  不会出现 brew-brew 这种看着像 bug 的名字
_zslog_pick_suffix() {
  local rule=${ZSH_SESSIONLOG_NAME_RULE:-mix} p out
  [[ $rule == none ]] && return 1
  (( $#_zslog_count )) || return 1

  local -a raw
  if [[ $rule == mix ]]; then
    raw=( "$(_zslog_pick_one first)" "$(_zslog_pick_one top)" "$(_zslog_pick_one last)" )
  else
    raw=( "$(_zslog_pick_one $rule)" )
  fi

  local prev=''
  for p in $raw; do
    [[ -n $p ]] || continue
    p=${p//[^A-Za-z0-9._-]/_}
    [[ $p == $prev ]] && continue
    prev=$p
    out=${out:+$out-}$p
  done
  [[ -n $out ]] || return 1
  print -r -- "${out[1,40]}"
}

# 命令清单，写进 .log 开头那几行 # 里
_zslog_cmd_summary() {
  (( $#_zslog_count )) || return 1
  local -a rest=( ${(k)_zslog_count} )
  local best b out='' total=0
  local -i i
  for (( i = 0; i < 3 && $#rest; i++ )); do
    best=''
    for b in $rest; do
      [[ -z $best || ${_zslog_count[$b]} -gt ${_zslog_count[$best]} ]] && best=$b
    done
    [[ -n $best ]] || break
    out=${out:+$out, }"$best ×${_zslog_count[$best]}"
    rest=( ${rest:#$best} )
  done
  for b in ${(k)_zslog_count}; do (( total += ${_zslog_count[$b]} )); done
  (( $#_zslog_count > 3 )) && out="$out …（共 $#_zslog_count 种命令）"
  print -r -- "$out"
}

# 退出前给 zslog 留话：第一行是文件名后缀，其余行是 .log 的题头。
# 真正的渲染在 zslog 里做 —— 那会儿录制流才收齐（最后一个提示符、
# 退出时的输出都在）。这里只写"意图"，不碰内容。
_zslog_zshexit() {
  local rec=$ZSH_SESSIONLOG_REC meta summary
  [[ -n $rec ]] || return 0
  # 只有真正被录制的那一层 shell 才写；窗口里再套一层 zsh 不算
  [[ -n $ZSLOG_SHELL_PID && $ZSLOG_SHELL_PID == $$ ]] || return 0
  meta="$rec.meta"
  summary=$(_zslog_cmd_summary)
  {
    _zslog_pick_suffix || print -r -- ''
    print -r -- "# zslog ${ZSH_SESSIONLOG_TIME:-} · ${COLUMNS:-?}×${LINES:-?}"
    print -r -- "# 目录  ${PWD/#$HOME/~}"
    [[ -n $summary ]] && print -r -- "# 命令  $summary"
  } >| "$meta" 2>/dev/null
  return 0
}

# 标题只留"哪一条日志"：时间戳 + 命令名，和文件名对齐
_zslog_title() {
  local tag=${ZSH_SESSIONLOG_STAMP} cli
  [[ -n $tag ]] || return 0
  cli=$(_zslog_pick_suffix 2>/dev/null)
  if [[ -n $cli ]]; then
    print -Pn -- $'\e]0;'"$tag · $cli"$'\a'
  else
    print -Pn -- $'\e]0;'"$tag"$'\a'
  fi
}

autoload -Uz add-zsh-hook 2>/dev/null

if [[ -n $ZSH_SESSIONLOG_ACTIVE ]]; then
  # 已经是内层（被录制的）shell：只挂钩子，不要再启动一层
  add-zsh-hook preexec _zslog_preexec
  add-zsh-hook zshexit _zslog_zshexit
  add-zsh-hook precmd  _zslog_title
  return 0
fi

# ---- 启动 -----------------------------------------------------
if [[ -o interactive ]] && [[ -t 0 && -t 1 ]] \
   && [[ -z $ZSH_NO_SESSION_LOG ]] && [[ -n $TERM && $TERM != dumb ]]; then

  if _zslog_build; then
    [[ -d $ZSH_SESSIONLOG_DIR ]] || mkdir -p "$ZSH_SESSIONLOG_DIR"
    _zslog_prune

    # 20261104-160627 这种时间戳；同一秒内又开一个窗口才会加 -2
    typeset -g _zslog_stamp="$(date '+%Y%m%d-%H%M%S')"
    typeset -g _zslog_base="$ZSH_SESSIONLOG_DIR/$_zslog_stamp"
    typeset -g _zslog_cur="$_zslog_base.log"
    typeset -gi _zslog_n=1
    while [[ -e $_zslog_cur || -e "${_zslog_cur%.log}.rec" ]]; do
      (( _zslog_n++ ))
      _zslog_cur="$_zslog_base-$_zslog_n.log"
    done

    export ZSH_SESSIONLOG_ACTIVE=1
    export ZSH_SESSIONLOG_STAMP="$_zslog_stamp"
    export ZSH_SESSIONLOG_TIME="$(date '+%Y-%m-%d %H:%M')"
    export ZSH_SESSIONLOG_CURRENT="$_zslog_cur"
    export ZSH_SESSIONLOG_REC="${_zslog_cur%.log}.rec"
    export ZSLOG_LOG="$_zslog_cur"

    # argv 只有 "zslog"：日志路径走环境变量，这样 ps / 窗口标题里
    # 不会出现 --log /Users/... 那串
    exec -a zslog "$ZSH_SESSIONLOG_BIN"
    # exec 成功就不会走到这里；失败则继续用无录制的 shell，别把人卡死
    print -ru2 -- "sessionlog: 启动录制失败，已退化为普通 shell"
    unset ZSH_SESSIONLOG_ACTIVE ZSH_SESSIONLOG_CURRENT ZSH_SESSIONLOG_STAMP \
          ZSH_SESSIONLOG_REC ZSH_SESSIONLOG_TIME ZSLOG_LOG
  else
    print -ru2 -- "sessionlog: 编译失败（需要 Xcode Command Line Tools），录制已跳过"
  fi
fi
