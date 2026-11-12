/*
 * zslog —— pty 中继式终端会话录制
 *
 * 为什么不用 /usr/bin/script：
 *   macOS 自带的 BSD script 创建内层 pty 后，不把窗口尺寸变化（SIGWINCH）
 *   转发下去。内层 shell 的 COLUMNS 会永久冻结在窗口初始宽度，之后 ZLE
 *   仍按旧列数排版，真实终端却按新列数折行 —— 换行错位、吞字、光标乱飘。
 *   本程序每收到一次 SIGWINCH，就把真实窗口尺寸 ioctl 进内层 pty，
 *   内核会自动给内层前台进程组补发 SIGWINCH，shell 始终知道真实列宽。
 *
 * 为什么用 C 而不是 python：
 *   python 冷启动 ≈ 80ms，且依赖解释器存在；这个二进制启动 ≈ 1ms。
 *   另外 Terminal.app 的标题取的是前台进程名 —— 解释型脚本会显示成
 *   "python3 /很长/的/路径/zslog --log ..."，编译成独立可执行文件后
 *   只会显示 "zslog"。
 *
 * 用法：
 *   zslog run [--log FILE] [--] [CMD ARGS...]  中继并录制
 *       日志文件优先取 --log，其次取环境变量 ZSLOG_LOG；
 *       不给 CMD 时默认 /bin/zsh -i。
 *   zslog clean FILE [--cols N] [--rows N]
 *       把录制回放成"屏幕上看到的样子"：按显示列建字符网格，
 *       处理 CR / CSI 光标移动 / 擦除 / 折行，所以 ZLE 的逐键重绘
 *       会被合并成最终那一行，不会出现重复和残字。
 *       列宽优先取日志里记录的窗口尺寸，没有记录时才用 --cols。
 *
 * 日志里会写入一行私用序列 ESC [ ? 9990 ; COLS ; ROWS h 记录窗口尺寸，
 * 只写日志不写终端；终端会忽略未知的私用模式，所以日志仍可原样回放。
 *
 * 关于窗口标题：Terminal.app 会把前台进程的完整 argv（ps 看到的那串）
 * 拼进标题栏，所以 `zslog run --log /很长的路径 -- /bin/zsh -i` 会整段
 * 出现在标题上。这里在 fork 之后把父进程的 argv 字符串就地抹掉，
 * 并把自己的 argv[0] 覆盖成 "zslog"，ps 就只剩五个字母。
 * （子进程是 fork 后的独立副本，不受影响，execvp 照常拿到参数。）
 */

#define _DARWIN_C_SOURCE 1

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <locale.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static volatile pid_t g_child = 0;
static volatile int g_master = -1;
static struct termios g_saved_tio;
static volatile int g_have_tio = 0;
static int g_argc = 0;
static char **g_argv = NULL;

static void die(const char *msg)
{
    fprintf(stderr, "zslog: %s\n", msg);
    exit(1);
}

static int write_all(int fd, const char *buf, size_t len)
{
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            if (errno == EIO || errno == EPIPE || errno == EBADF)
                return 0;
            return 0;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 1;
}

static void sync_size(void)
{
    struct winsize ws;
    int master = g_master;
    if (master < 0)
        return;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0)
        ioctl(master, TIOCSWINSZ, &ws);
}

static void on_winch(int sig)
{
    (void)sig;
    sync_size();
}

static void on_forward(int sig)
{
    pid_t pid = g_child;
    if (pid > 0)
        kill(pid, sig);
}

static void restore_tty(void)
{
    if (g_have_tio) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_saved_tio);
        g_have_tio = 0;
    }
}

/*
 * 让 ps（以及据此拼窗口标题的 Terminal.app）只看到 "zslog"。
 * 参数已在本进程解析完，子进程也已 fork 出独立副本，此时抹掉父进程的
 * argv 字符串区是安全的；ps 遇到空参数即停止枚举。
 */
static void tidy_process_title(int argc, char **argv)
{
    int i;

    if (argc > 0 && argv[0] != NULL && strlen(argv[0]) >= 5)
        memcpy(argv[0], "zslog", 6); /* 含结尾 \0，长度一定够 */

    for (i = 1; i < argc; i++) {
        if (argv[i] != NULL && argv[i][0] != '\0')
            memset(argv[i], 0, strlen(argv[i]));
    }
}

/* ---------------- 路径与 meta（给 shell 留话） ---------------- */

/* 拆成 目录 / 去掉扩展名的主干 */
static void split_path(const char *path, char *dir, size_t dcap,
                       char *stem, size_t scap)
{
    const char *slash = strrchr(path, '/');
    const char *base = slash ? slash + 1 : path;
    char *dot;

    if (slash != NULL) {
        size_t n = (size_t)(slash - path);
        if (n >= dcap)
            n = dcap - 1;
        memcpy(dir, path, n);
        dir[n] = '\0';
    } else {
        strcpy(dir, ".");
    }
    snprintf(stem, scap, "%s", base);
    dot = strrchr(stem, '.');
    if (dot != NULL && dot != stem)
        *dot = '\0';
}

/* 同一目录下的兄弟文件：a/b.log + "rec" → a/b.rec */
static void sibling_path(const char *path, const char *ext, char *out, size_t cap)
{
    char dir[PATH_MAX], stem[PATH_MAX];

    split_path(path, dir, sizeof dir, stem, sizeof stem);
    snprintf(out, cap, "%s/%s.%s", dir, stem, ext);
}

/*
 * meta 文件是 zsh 在退出前写的：第一行是文件名后缀，其余行是给 .log
 * 开头的说明。这里只取第一行，并洗掉不能进文件名的字符。
 */
static int read_meta_suffix(const char *meta, char *out, size_t cap)
{
    FILE *f = fopen(meta, "r");
    size_t i, j = 0;
    int c;

    out[0] = '\0';
    if (f == NULL)
        return 0;
    while ((c = fgetc(f)) != EOF && c != '\n') {
        if (j + 1 < cap && c != '\r')
            out[j++] = (char)c;
    }
    out[j] = '\0';
    fclose(f);

    for (i = 0, j = 0; i < strlen(out); i++) {
        char ch = out[i];
        if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') ||
            (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' || ch == '-')
            out[j++] = ch;
    }
    out[j] = '\0';
    if (j > 40)
        out[40] = '\0';
    return (int)strlen(out);
}

/* 跳过第一行（后缀），其余原样抄进 .log 开头 */
static void copy_meta_header(const char *meta, FILE *out)
{
    FILE *f = fopen(meta, "r");
    int c;

    if (f == NULL)
        return;
    while ((c = fgetc(f)) != EOF && c != '\n')
        ;
    if (c == EOF) {
        fclose(f);
        return;
    }
    {
        char buf[4096];
        size_t n;

        while ((n = fread(buf, 1, sizeof buf, f)) > 0)
            fwrite(buf, 1, n, out);
    }
    fclose(f);
}

static void log_mark_size(int fd, const struct winsize *ws)
{
    char buf[64];
    int n;

    if (fd < 0 || ws == NULL || ws->ws_col <= 0 || ws->ws_row <= 0)
        return;
    n = snprintf(buf, sizeof buf, "\x1b[?9990;%d;%dh", ws->ws_col, ws->ws_row);
    if (n > 0)
        write_all(fd, buf, (size_t)n);
}

static void render_on_exit(const char *log_path);

/*
 * 终端对 ESC[6n（查询光标位置）的应答 ESC[<row>;<col>R 是异步回来的，
 * 经常落在 shell 已经不再读它的时候。留在 tty 输入队列里就会被当成键盘
 * 输入：命令行上多出一串 "1R"、"7R"，运气不好还会被执行成命令。
 *
 * 只处理这一种形状 —— "ESC [ 数字/分号... R"，而且要看有没有人认领
 * （见 cpr_expected：程序发过 ESC[6n 才放行，没人要的才丢）。方向键、
 * 功能键、bracketed paste 的结尾字节都不是 R，原样转发；只有"ESC [ 后面
 * 全是数字、还没等到结尾"时才暂留（最多 20 字节），等下一块数据补完再判。
 */
static unsigned char g_cpr_tail[20];
static size_t g_cpr_ntail;
static int g_cpr_off;           /* 环境变量关掉时置 1 */

/*
 * "有人要过应答"的记账。
 *
 * 光按形状吞 CPR 会误伤：fzf 一启动就发 ESC[6n 量光标位置，等着这个应答，
 * 吞了它 fzf 就得超时降级 —— 窗口出得慢，还会去问 DECRQM，在 Terminal.app
 * 上冒出一个孤零零的 p。
 *
 * 所以改成配对：输出流里出现一次 ESC[6n，就记一笔"欠一个应答"；应答来时
 * 有账就放行、销账，没账的（上一个会话遗留、没人认领的）才吞掉。
 * 账目 3 秒过期，免得程序发了不读、把后来的孤儿应答也当成合法的。
 */
static int g_cpr_expect;
static double g_expect_ts;
static unsigned char g_mtail[4];      /* 跨块扫描 ESC[6n 用的残留 */
static size_t g_mtn;

static double now_ms(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1e6;
}

/* 看输出流里有没有人在查光标位置 */
static void note_cpr_queries(const unsigned char *b, size_t n)
{
    static unsigned char tmp[8 + 65536];
    size_t total = 0, i;

    if (g_mtn > 0) {
        memcpy(tmp, g_mtail, g_mtn);
        total = g_mtn;
        g_mtn = 0;
    }
    if (n > sizeof tmp - total)
        n = sizeof tmp - total;
    memcpy(tmp + total, b, n);
    total += n;

    for (i = 0; i + 3 < total; i++) {
        if (tmp[i] == 0x1b && tmp[i + 1] == '[' && tmp[i + 2] == '6' && tmp[i + 3] == 'n') {
            if (g_cpr_expect < 16)
                g_cpr_expect++;
            g_expect_ts = now_ms();
            i += 3;
        }
    }
    /* 末尾可能是半个 ESC[6n，留到下一块再看 */
    g_mtn = total < 4 ? total : 3;
    memcpy(g_mtail, tmp + total - g_mtn, g_mtn);
}

/* 这笔账还算数吗 */
static int cpr_expected(void)
{
    if (g_cpr_expect <= 0)
        return 0;
    if (now_ms() - g_expect_ts > 3000.0) {   /* 太久了，当没人要 */
        g_cpr_expect = 0;
        return 0;
    }
    return 1;
}

static size_t strip_cpr(const unsigned char *in, size_t n,
                        unsigned char *out, size_t cap)
{
    unsigned char work[20 + 65536];
    size_t total, i = 0, o = 0, keep = 0;

    if (g_cpr_off) {
        if (n > cap)
            n = cap;
        memcpy(out, in, n);
        return n;
    }

    total = 0;
    if (g_cpr_ntail > 0) {
        memcpy(work, g_cpr_tail, g_cpr_ntail);
        total = g_cpr_ntail;
        g_cpr_ntail = 0;
    }
    if (n > sizeof work - total)
        n = sizeof work - total;
    memcpy(work + total, in, n);
    total += n;

    while (i < total) {
        size_t j;

        if (work[i] == 0x1b && i + 1 < total && work[i + 1] == '[') {
            j = i + 2;
            while (j < total && ((work[j] >= '0' && work[j] <= '9') || work[j] == ';'))
                j++;
            if (j >= total) {
                /* 序列还没结束：留着等下一块，别提前转发半个应答 */
                if (total - i <= sizeof g_cpr_tail) {
                    keep = total - i;
                    break;
                }
            } else if (work[j] == 'R' && j > i + 2) {
                if (cpr_expected()) {
                    size_t t;

                    g_cpr_expect--;
                    for (t = i; t <= j && o < cap; t++)
                        out[o++] = work[t];   /* 有人在等，原样给过去 */
                }
                i = j + 1;
                continue;
            }
        }
        if (o < cap)
            out[o++] = work[i];
        i++;
    }

    if (keep > 0) {
        memcpy(g_cpr_tail, work + total - keep, keep);
        g_cpr_ntail = keep;
    }
    return o;
}

static int relay(const char *log_path, char **argv)
{
    char rec_path[PATH_MAX];
    char log_copy[PATH_MAX];
    struct winsize ws;
    int have_ws = ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0;
    int master = -1, slave = -1, log_fd = -1;
    struct winsize last_ws;
    pid_t pid;

    /* 下面 tidy_process_title 会把 argv 抹成空格，log_path 就在 argv 里，
       先拷一份，否则退出时拿到的是空字符串 */
    snprintf(log_copy, sizeof log_copy, "%s", log_path);

    if (openpty(&master, &slave, NULL, NULL, have_ws ? &ws : NULL) < 0) {
        perror("zslog: openpty");
        return 1;
    }

    sibling_path(log_path, "rec", rec_path, sizeof rec_path);

    /* 原始字节流写 .rec；.log 是退出时由它渲染出的人读版 */
    log_fd = open(rec_path, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (log_fd < 0)
        fprintf(stderr, "zslog: 无法写入录制文件 %s: %s（继续录制但不出文件）\n",
                rec_path, strerror(errno));

    /*
     * 把起始窗口尺寸写进日志（只写日志，不写终端）。回放时 zslog clean
     * 据此决定按多少列折行；终端会忽略未知的私用模式，日志照样能原样重放。
     */
    memset(&last_ws, 0, sizeof last_ws);
    if (have_ws && ws.ws_col > 0) {
        last_ws = ws;
        log_mark_size(log_fd, &ws);
    }

    if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &g_saved_tio) == 0) {
        struct termios raw = g_saved_tio;
        g_have_tio = 1;
        cfmakeraw(&raw);
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    }

    pid = fork();
    if (pid < 0) {
        perror("zslog: fork");
        restore_tty();
        return 1;
    }

    if (pid == 0) {
        close(master);
        if (log_fd >= 0)
            close(log_fd);
        setsid();
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO)
            close(slave);

        signal(SIGWINCH, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);

        {
            char pidbuf[24];
            snprintf(pidbuf, sizeof pidbuf, "%ld", (long)getpid());
            setenv("ZSLOG_SHELL_PID", pidbuf, 1);
        }

        execvp(argv[0], argv);
        fprintf(stderr, "zslog: 无法执行 %s: %s\n", argv[0], strerror(errno));
        _exit(127);
    }

    g_child = pid;
    g_master = master;
    close(slave);

    /* 子进程已拿到独立副本，这里把父进程的命令行缩短成 "zslog" */
    tidy_process_title(g_argc, g_argv);

    sync_size();
    signal(SIGWINCH, on_winch);
    signal(SIGTERM, on_forward);
    signal(SIGHUP, on_forward);
    signal(SIGINT, on_forward);
    signal(SIGQUIT, on_forward);

    {
        char buf[65536];
        char fbuf[65536];
        int stdin_open = 1;

        g_cpr_off = getenv("ZSLOG_KEEP_CPR") != NULL;

        for (;;) {
            struct winsize cur;
            fd_set rfds;
            int maxfd = master;
            int rc;

            /* 窗口尺寸变了就补一个标记，回放时才知道从哪一行开始按新宽度折行 */
            if (ioctl(STDIN_FILENO, TIOCGWINSZ, &cur) == 0 && cur.ws_col > 0 &&
                (cur.ws_col != last_ws.ws_col || cur.ws_row != last_ws.ws_row)) {
                last_ws = cur;
                log_mark_size(log_fd, &cur);
            }

            FD_ZERO(&rfds);
            FD_SET(master, &rfds);
            if (stdin_open) {
                FD_SET(STDIN_FILENO, &rfds);
                if (STDIN_FILENO > maxfd)
                    maxfd = STDIN_FILENO;
            }

            rc = select(maxfd + 1, &rfds, NULL, NULL, NULL);
            if (rc < 0) {
                if (errno == EINTR)
                    continue;
                break;
            }

            if (stdin_open && FD_ISSET(STDIN_FILENO, &rfds)) {
                ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
                if (n <= 0) {
                    stdin_open = 0;
                } else {
                    size_t m = strip_cpr((const unsigned char *)buf, (size_t)n,
                                         (unsigned char *)fbuf, sizeof fbuf);
                    if (m > 0 && !write_all(master, fbuf, m))
                        break;
                }
            }

            if (FD_ISSET(master, &rfds)) {
                ssize_t n = read(master, buf, sizeof buf);
                if (n <= 0)
                    break;
                write_all(STDOUT_FILENO, buf, (size_t)n);
                note_cpr_queries((const unsigned char *)buf, (size_t)n);
                if (log_fd >= 0)
                    write_all(log_fd, buf, (size_t)n);
            }
        }
    }

    restore_tty();
    if (log_fd >= 0)
        close(log_fd);
    close(master);
    g_master = -1;

    /* 子 shell 已退出、原始流也收齐了，现在把它渲染成人读的 .log */
    render_on_exit(log_copy);

    {
        int status = 0;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
            continue;
        if (WIFEXITED(status))
            return WEXITSTATUS(status);
        if (WIFSIGNALED(status))
            return 128 + WTERMSIG(status);
    }
    return 0;
}

/* ---------------- clean：把录制回放成屏幕文本 ---------------- */

/*
 * 录制下来的是终端原始字节流。ZLE 每敲一个键都会原地重绘
 * （CR + CSI C/D/G/K），所以同一行在流里出现很多遍 —— 那是录制方式
 * 决定的，不是 bug。但直接 cat，或者按字节逐个覆盖，得到的都是乱的：
 *
 *   1. 字节数 ≠ 显示列数。一个 CJK 字符 3 字节占 2 列，Apple 图标 3 字节
 *      占 1 列；ZLE 的 CSI C/D 按"列"走，按字节记账必然错位 —— 路径里有
 *      日文时就会串成 "mutagen-inspect ~mutagen-inspect /Users/jea..."。
 *   2. ZLE 折行、补全菜单用 CSI A/B 上下移动，单行缓冲表达不了。
 *
 * 所以这里做一个最小终端模拟：按显示列维护字符网格，回放完整条流，
 * 最后按行打印。得到的才是当时屏幕上真正显示的内容。
 */

#define CLEAN_MAX_COLS 512
#define CLEAN_DEF_COLS 120
#define CLEAN_DEF_ROWS 24

/* 网格里的一个显示单元。w=1 占一列，w=2 占两列，w=0 是宽字符的第二列 */
typedef struct {
    char b[5];
    unsigned char w;
    unsigned short st;   /* 样式表下标，0 = 默认（没有任何 SGR） */
} Cell;

/*
 * 样式表。颜色/加粗这些不影响"文字在哪一格"，但影响"看起来是什么样"：
 * 日志正文给人读，不需要颜色；回放（zslog-cat）要还原现场，就必须带上。
 * 同一份网格两种输出，靠 g_color 开关。
 */
#define ST_MAX 512

typedef struct {
    char fg[24];   /* SGR 里的前景参数，如 "38;5;108" / "31"，空 = 默认 */
    char bg[24];   /* 同上，背景 */
    unsigned char flags; /* 1 粗 2 淡 4 斜 8 下划线 16 闪 32 反显 64 隐 128 删除线 */
} Style;

static Style g_styles[ST_MAX];
static int g_nstyles = 1;
static Style g_cur;
static unsigned short g_cur_id = 0;
static int g_color = 0;

static Cell **g_grid;
static int *g_rowlen;   /* 每行实际用到的列数（窗口变窄后仍按当时的宽度输出） */
/*
 * g_wrapr[r] = 1 表示第 r 行是第 r-1 行写满后终端自动折下来的续行。
 *
 * 终端里那是"软换行"：同一段文字，只是因为窗口窄。日志若照着网格逐行
 * 硬回车输出，就等于把一行长文本切成了好几行 —— 换个更宽的窗口看，右边
 * 就永远接不回去了。所以这里记下血缘，输出时把续行拼回上一行。
 */
static unsigned char *g_wrapr;
static int g_grid_rows;
static int g_grid_cap;
static int g_cols = CLEAN_DEF_COLS;
static int g_scr_rows = CLEAN_DEF_ROWS;
/*
 * 当前"这一屏"的第一行落在网格的第几行。
 *
 * 真实终端只有一屏，滚出去的内容进 scrollback；日志要把 scrollback 也留住，
 * 所以网格只增不减。于是 CSI H（光标回家）不能再当成"网格第 0 行" ——
 * 那会把整段历史从头盖掉（clear + H 之后前面的内容就没了）。凡是绝对定位，
 * 都相对这一屏的顶端算；内容写满一屏，顶端跟着下移。
 */
static int g_scr_base = 0;
static int g_cy;
static int g_cx;
static int g_save_cy;
static int g_save_cx;

/*
 * 显示宽度。PUA（Apple 图标 U+F179 等）wcwidth 返回 -1，zsh 和
 * Terminal.app 都按 1 列算，这里统一取 1。
 */
static int cp_width(long cp)
{
    int w;

    if (cp <= 0 || cp > 0x10FFFF)
        return 1;
    if (cp < 0x20 || (cp >= 0x7f && cp < 0xa0))
        return 0;
    w = wcwidth((wchar_t)cp);
    return w >= 0 ? w : 1;
}

/* 把样式登记进表里，返回下标；相同的样式复用同一个下标 */
static int style_intern(const Style *s)
{
    int i;

    if (s->fg[0] == '\0' && s->bg[0] == '\0' && s->flags == 0)
        return 0;
    for (i = 1; i < g_nstyles; i++)
        if (g_styles[i].flags == s->flags &&
            strcmp(g_styles[i].fg, s->fg) == 0 &&
            strcmp(g_styles[i].bg, s->bg) == 0)
            return i;
    if (g_nstyles >= ST_MAX)
        return 0;
    g_styles[g_nstyles] = *s;
    return g_nstyles++;
}

/*
 * 擦除（CSI K / J）留下的空格按当前背景色填充，和真实终端一致。
 * 只留背景：空格没有前景可谈，这样纯前景色的空格仍算"空"，行尾还能剪掉。
 */
static unsigned short blank_style(void)
{
    Style s;

    memset(&s, 0, sizeof s);
    if (g_cur.flags & 32)               /* 反显：空格显示出来的是当前前景色 */
        snprintf(s.bg, sizeof s.bg, "%s", g_cur.fg);
    else
        snprintf(s.bg, sizeof s.bg, "%s", g_cur.bg);
    if (s.bg[0] == '\0')
        return 0;
    return (unsigned short)style_intern(&s);
}

static void sgr_reset(void)
{
    memset(&g_cur, 0, sizeof g_cur);
    g_cur_id = 0;
}

/* 处理 CSI ... m：把参数累积到 g_cur，再换算出样式下标 */
static void sgr_apply(const int *p, int np)
{
    int i;

    if (np == 0) {
        sgr_reset();
        return;
    }
    for (i = 0; i < np; i++) {
        int v = p[i];

        switch (v) {
        case 0:  sgr_reset(); break;
        case 1:  g_cur.flags |= 1; break;
        case 2:  g_cur.flags |= 2; break;
        case 3:  g_cur.flags |= 4; break;
        case 4:  g_cur.flags |= 8; break;
        case 5:  g_cur.flags |= 16; break;
        case 7:  g_cur.flags |= 32; break;
        case 8:  g_cur.flags |= 64; break;
        case 9:  g_cur.flags |= 128; break;
        case 21:
        case 22: g_cur.flags &= (unsigned char)~(1 | 2); break;
        case 23: g_cur.flags &= (unsigned char)~4; break;
        case 24: g_cur.flags &= (unsigned char)~8; break;
        case 25: g_cur.flags &= (unsigned char)~16; break;
        case 27: g_cur.flags &= (unsigned char)~32; break;
        case 28: g_cur.flags &= (unsigned char)~64; break;
        case 29: g_cur.flags &= (unsigned char)~128; break;
        case 39: g_cur.fg[0] = '\0'; break;
        case 49: g_cur.bg[0] = '\0'; break;

        case 38:
        case 48: {
            char *dst = (v == 38) ? g_cur.fg : g_cur.bg;
            size_t cap = (v == 38) ? sizeof g_cur.fg : sizeof g_cur.bg;

            if (i + 2 < np && p[i + 1] == 5) {
                snprintf(dst, cap, "%d;5;%d", v, p[i + 2]);
                i += 2;
            } else if (i + 4 < np && p[i + 1] == 2) {
                snprintf(dst, cap, "%d;2;%d;%d;%d", v, p[i + 2], p[i + 3], p[i + 4]);
                i += 4;
            } else {
                dst[0] = '\0';
                i = np;         /* 认不出的扩展色，忽略掉后面 */
            }
            break;
        }

        default:
            if ((v >= 30 && v <= 37) || (v >= 90 && v <= 97))
                snprintf(g_cur.fg, sizeof g_cur.fg, "%d", v);
            else if ((v >= 40 && v <= 47) || (v >= 100 && v <= 107))
                snprintf(g_cur.bg, sizeof g_cur.bg, "%d", v);
            break;              /* 其余（10-19 字体、53 上划线…）忽略 */
        }
    }
    g_cur_id = (unsigned short)style_intern(&g_cur);
}

/* 写出一段把样式设成 id 的 SGR；总是先 reset，免得继承上一格的属性 */
static void style_emit(unsigned short id, FILE *out)
{
    const Style *s = &g_styles[id];
    char buf[128];

    if (id == 0) {
        fputs("\x1b[0m", out);
        return;
    }
    strcpy(buf, "\x1b[0");
    if (s->flags & 1)   strcat(buf, ";1");
    if (s->flags & 2)   strcat(buf, ";2");
    if (s->flags & 4)   strcat(buf, ";3");
    if (s->flags & 8)   strcat(buf, ";4");
    if (s->flags & 16)  strcat(buf, ";5");
    if (s->flags & 32)  strcat(buf, ";7");
    if (s->flags & 64)  strcat(buf, ";8");
    if (s->flags & 128) strcat(buf, ";9");
    if (s->fg[0] != '\0') { strcat(buf, ";"); strcat(buf, s->fg); }
    if (s->bg[0] != '\0') { strcat(buf, ";"); strcat(buf, s->bg); }
    strcat(buf, "m");
    fputs(buf, out);
}

static void grid_ensure(int row)
{
    if (row < 0)
        return;
    while (g_grid_rows <= row) {
        Cell *r;
        int i;

        if (g_grid_rows == g_grid_cap) {
            int nc = g_grid_cap ? g_grid_cap * 2 : 256;
            Cell **np = realloc(g_grid, (size_t)nc * sizeof *np);
            int *nl;
            unsigned char *nw;
            if (np == NULL)
                die("内存不足");
            g_grid = np;
            nl = realloc(g_rowlen, (size_t)nc * sizeof *nl);
            if (nl == NULL)
                die("内存不足");
            g_rowlen = nl;
            nw = realloc(g_wrapr, (size_t)nc * sizeof *nw);
            if (nw == NULL)
                die("内存不足");
            g_wrapr = nw;
            g_grid_cap = nc;
        }
        r = malloc((size_t)CLEAN_MAX_COLS * sizeof *r);
        if (r == NULL)
            die("内存不足");
        memset(r, 0, (size_t)CLEAN_MAX_COLS * sizeof *r);
        for (i = 0; i < CLEAN_MAX_COLS; i++) {
            r[i].b[0] = ' ';
            r[i].w = 1;
        }
        g_rowlen[g_grid_rows] = 0;
        g_wrapr[g_grid_rows] = 0;
        g_grid[g_grid_rows++] = r;
    }
}

/* 重算某行实际用到的列数（擦除后行尾可能变短） */
static void row_recalc(int row)
{
    int i = g_rowlen[row];

    while (i > 0) {
        Cell *c = &g_grid[row][i - 1];
        if (c->w == 0) { /* 宽字符第二列，跟着前一个格一起算 */
            i--;
            continue;
        }
        if (c->b[0] == ' ' && c->b[1] == '\0') {
            i--;
            continue;
        }
        break;
    }
    g_rowlen[row] = i;
}

static void grid_blank(int row, int from, int to)
{
    int i;
    unsigned short bs;

    if (row < 0 || row >= g_grid_rows)
        return;
    if (from < 0)
        from = 0;
    if (to > CLEAN_MAX_COLS)
        to = CLEAN_MAX_COLS;
    if (from >= to)
        return;
    bs = blank_style();
    for (i = from; i < to; i++) {
        memset(g_grid[row][i].b, 0, sizeof g_grid[row][i].b);
        g_grid[row][i].b[0] = ' ';
        g_grid[row][i].w = 1;
        g_grid[row][i].st = bs;
    }
    row_recalc(row);
}

/* 这一行是"真换行"开始的，不再是上一行的续行 */
static void row_hard(int row)
{
    if (row >= 0 && row < g_grid_rows)
        g_wrapr[row] = 0;
}

/* 行元数据跟着行走：CSI L/M 会把整行搬上搬下 */
static void row_swap(int a, int b)
{
    Cell *t = g_grid[a];
    int tl = g_rowlen[a];
    unsigned char tw = g_wrapr[a];

    g_grid[a] = g_grid[b];
    g_rowlen[a] = g_rowlen[b];
    g_wrapr[a] = g_wrapr[b];
    g_grid[b] = t;
    g_rowlen[b] = tl;
    g_wrapr[b] = tw;
}

static int clamp_col(int c)
{
    if (c < 0)
        return 0;
    if (c >= g_cols)
        return g_cols - 1;
    return c;
}

static int screen_top(void)
{
    return g_scr_base;
}

/* 光标跑到屏幕底下一行，就当成滚了一行（真实终端的行为） */
static void normalize_scroll(void)
{
    if (g_scr_rows <= 0)
        return;
    if (g_cy - g_scr_base >= g_scr_rows) {
        g_scr_base = g_cy - g_scr_rows + 1;
        if (g_scr_base < 0)
            g_scr_base = 0;
    }
}

static void grid_put(long cp)
{
    int row = g_cy, col = g_cx, w = cp_width(cp);
    char buf[5];
    int n = 0;

    if (w <= 0)
        return;

    if (col >= g_cols) { /* 上一格已写到行尾，折行 */
        row++;
        col = 0;
        g_cy = row;
        g_cx = 0;
        normalize_scroll();
        row = g_cy;
        grid_ensure(row);
        g_wrapr[row] = 1;       /* 软换行：和上一行是同一段文字 */
    }
    if (w == 2 && col == g_cols - 1) { /* 宽字符放不进最后一列 */
        grid_ensure(row);
        grid_blank(row, col, col + 1);
        row++;
        col = 0;
        grid_ensure(row);
        g_wrapr[row] = 1;
    }
    grid_ensure(row);

    if (cp < 0x80) {
        buf[n++] = (char)cp;
    } else if (cp < 0x800) {
        buf[n++] = (char)(0xc0 | (cp >> 6));
        buf[n++] = (char)(0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
        buf[n++] = (char)(0xe0 | (cp >> 12));
        buf[n++] = (char)(0x80 | ((cp >> 6) & 0x3f));
        buf[n++] = (char)(0x80 | (cp & 0x3f));
    } else {
        buf[n++] = (char)(0xf0 | (cp >> 18));
        buf[n++] = (char)(0x80 | ((cp >> 12) & 0x3f));
        buf[n++] = (char)(0x80 | ((cp >> 6) & 0x3f));
        buf[n++] = (char)(0x80 | (cp & 0x3f));
    }
    buf[n] = '\0';

    memset(g_grid[row][col].b, 0, sizeof g_grid[row][col].b);
    memcpy(g_grid[row][col].b, buf, (size_t)n + 1);
    g_grid[row][col].w = (unsigned char)w;
    g_grid[row][col].st = g_cur_id;
    if (w == 2 && col + 1 < g_cols) {
        memset(g_grid[row][col + 1].b, 0, sizeof g_grid[row][col + 1].b);
        g_grid[row][col + 1].w = 0;
        g_grid[row][col + 1].st = g_cur_id;
    }

    g_cy = row;
    g_cx = col + w;
    if (g_cx > g_rowlen[row])
        g_rowlen[row] = g_cx;
}

static void grid_shift(int row, int from, int delta)
{
    Cell *r = g_grid[row];

    if (delta == 0)
        return;
    if (delta > 0) { /* 右移：腾出 left 个空位 */
        if (g_cols - delta - from > 0)
            memmove(r + from + delta, r + from,
                    (size_t)(g_cols - delta - from) * sizeof *r);
    } else { /* 左移 */
        int d = -delta;
        if (g_cols - from - d > 0)
            memmove(r + from, r + from + d,
                    (size_t)(g_cols - from - d) * sizeof *r);
    }
}

static void clean_csi(int f, int *p, int np)
{
    int n, r, top;

    switch (f) {
    case 'K':
        row_hard(g_cy);     /* 擦掉这一行 = 这一行要重写，不再是续行 */
        if (np == 0 || p[0] == 0)
            grid_blank(g_cy, clamp_col(g_cx), CLEAN_MAX_COLS);
        else if (p[0] == 1)
            grid_blank(g_cy, 0, clamp_col(g_cx) + 1);
        else
            grid_blank(g_cy, 0, CLEAN_MAX_COLS);
        break;

    case 'J':
        if (np == 0 || p[0] == 0) {
            grid_blank(g_cy, clamp_col(g_cx), CLEAN_MAX_COLS);
            for (r = g_cy + 1; r < g_grid_rows; r++)
                grid_blank(r, 0, CLEAN_MAX_COLS);
        } else if (p[0] == 1) {
            for (r = 0; r < g_cy; r++)
                grid_blank(r, 0, CLEAN_MAX_COLS);
            grid_blank(g_cy, 0, clamp_col(g_cx) + 1);
        } else {
            /*
             * CSI 2J / 3J：清屏（macOS 的 clear 为了清滚动区还会带 3J）。
             * 这里是日志不是终端 —— 清屏前的内容已经发生过，不该从记录里
             * 消失。所以保留已有行，空一行，从新的一行继续往下写。
             * 如果整屏本来就是空的（刚启动就 H+2J），则回到原点，不留空行。
             */
            int lastnz = -1;

            for (r = 0; r < g_grid_rows; r++)
                if (g_rowlen[r] > 0)
                    lastnz = r;
            g_cx = 0;
            if (lastnz < 0) { /* 还没写过任何东西 */
                g_cy = 0;
                g_grid_rows = 1;
                g_scr_base = 0;
                grid_ensure(0);
            } else {
                /* 光标落在"最后一行内容 + 2"上，正好隔一个空行；
                   新的一屏从这里开始算，后面的绝对定位才不会倒回去盖历史 */
                g_cy = lastnz + 2;
                g_scr_base = g_cy;
                grid_ensure(g_cy);
                row_hard(g_cy);
            }
        }
        break;

    case 'C':
        g_cx = clamp_col(g_cx + ((np && p[0]) ? p[0] : 1));
        break;
    case 'D':
        g_cx = clamp_col(g_cx - ((np && p[0]) ? p[0] : 1));
        break;
    case 'G':
        g_cx = clamp_col((np && p[0] > 0) ? p[0] - 1 : 0);
        break;
    case 'H':
    case 'f':
        top = screen_top();
        g_cy = top + ((np && p[0] > 0) ? p[0] - 1 : 0);
        if (g_cy > top + g_scr_rows - 1)
            g_cy = top + g_scr_rows - 1;
        g_cx = clamp_col((np >= 2 && p[1] > 0) ? p[1] - 1 : 0);
        grid_ensure(g_cy);
        row_hard(g_cy);
        break;
    case 'd':
        top = screen_top();
        g_cy = top + ((np && p[0] > 0) ? p[0] - 1 : 0);
        if (g_cy > top + g_scr_rows - 1)
            g_cy = top + g_scr_rows - 1;
        grid_ensure(g_cy);
        row_hard(g_cy);
        break;
    case 'A':
        g_cy -= (np && p[0]) ? p[0] : 1;
        if (g_cy < g_scr_base)
            g_cy = g_scr_base;      /* 到顶就停，不翻 scrollback */
        break;
    case 'B':
        g_cy += (np && p[0]) ? p[0] : 1;
        if (g_cy > g_scr_base + g_scr_rows - 1)
            g_cy = g_scr_base + g_scr_rows - 1;
        grid_ensure(g_cy);
        row_hard(g_cy);
        break;

    case 'P': /* 删掉光标处 n 个字符 */
        n = (np && p[0]) ? p[0] : 1;
        grid_shift(g_cy, clamp_col(g_cx), -n);
        grid_blank(g_cy, g_cols - n, g_cols);
        break;
    case '@': /* 插入 n 个空白 */
        n = (np && p[0]) ? p[0] : 1;
        grid_shift(g_cy, clamp_col(g_cx), n);
        grid_blank(g_cy, clamp_col(g_cx), clamp_col(g_cx) + n);
        break;
    case 'X':
        n = (np && p[0]) ? p[0] : 1;
        grid_blank(g_cy, clamp_col(g_cx), clamp_col(g_cx) + n);
        break;

    case 'L': /* 光标处插入 n 行，屏内下移 */
        n = (np && p[0]) ? p[0] : 1;
        top = screen_top();
        grid_ensure(g_grid_rows + n);
        for (r = g_grid_rows - 1; r >= g_cy + n; r--)
            row_swap(r, r - n);
        for (r = g_cy; r < g_cy + n && r < g_grid_rows; r++) {
            grid_blank(r, 0, g_cols);
            g_wrapr[r] = 0;
        }
        (void)top;
        break;
    case 'M': /* 删掉光标处 n 行，屏内上移 */
        n = (np && p[0]) ? p[0] : 1;
        if (g_cy + n < g_grid_rows) {
            for (r = g_cy; r + n < g_grid_rows; r++) {
                row_swap(r, r + n);
            }
        }
        for (r = g_grid_rows - n; r < g_grid_rows; r++)
            if (r >= 0)
                grid_blank(r, 0, g_cols);
        break;

    case 'm': /* 颜色/属性：只影响回放时的外观，不影响格子里放什么 */
        sgr_apply(p, np);
        break;

    default:
        break; /* h / l / r / s / u / q / t … 与文本无关 */
    }
}

/*
 * 一行里最后一个"看得见"的格子。
 *   空格 + 默认背景 = 看不见，可以剪掉（否则每行都拖一长串尾随空格）；
 *   空格 + 有背景色 = 看得见（TUI 的色块、反显条），必须留着。
 */
static int cell_visible(const Cell *c)
{
    if (c->w == 0 || c->b[0] != ' ' || c->b[1] != '\0')
        return 1;
    return g_styles[c->st].bg[0] != '\0';
}

static void grid_dump(FILE *out)
{
    int r, i, last, nrows;
    unsigned short cur;
    char *emit;

    /* 末尾全空的行不输出（光标停在空行上的情况很常见） */
    nrows = g_grid_rows;
    while (nrows > 0 && g_rowlen[nrows - 1] == 0)
        nrows--;
    if (nrows <= 0)
        return;

    emit = malloc((size_t)nrows);
    if (emit == NULL)
        die("内存不足");

    /* 每行最后一个可见格；同时把"看得见"的行标出来 */
    for (r = 0; r < nrows; r++) {
        Cell *row = g_grid[r];
        int cont = (r + 1 < nrows) && g_wrapr[r + 1];

        last = 0;
        for (i = 0; i < g_rowlen[r]; i++)
            if (cell_visible(&row[i]))
                last = i + 1;
        /*
         * 下一行是本行的续行时不能截行尾空白：那些空格占着列位置，
         * 截掉会让后半段文字整体左移。
         */
        if (!cont)
            g_rowlen[r] = last;
        emit[r] = last > 0;
    }

    /*
     * 连续空白行最多留两行。全屏程序（curses/rich 的 Live）退出时常常
     * 留下一整屏空格，逐字保留只会让日志中间空掉二十几行 —— 空白里没有
     * 信息，压掉不影响内容，不影响任何一行的字符。
     */
    for (r = 0; r < nrows; ) {
        int s;

        if (emit[r]) {
            r++;
            continue;
        }
        s = r;
        while (r < nrows && !emit[r])
            r++;
        if (r - s > 2)
            for (i = s + 2; i < r; i++)
                emit[i] = -1;       /* -1 = 被压掉的空行 */
    }

    for (r = 0; r < nrows; r++) {
        Cell *row = g_grid[r];

        if (emit[r] < 0)
            continue;           /* 被压掉的空行：不输出，也不占行 */
        cur = 0;
        for (i = 0; i < g_rowlen[r]; i++) {
            Cell *c = &row[i];

            if (c->w == 0 || c->b[0] == '\0')
                continue;
            if (g_color && c->st != cur) {
                style_emit(c->st, out);
                cur = c->st;
            }
            fwrite(c->b, 1, strlen(c->b), out);
        }
        if (g_color && cur != 0)
            fputs("\x1b[0m", out);
        /* 下一行是自动折行的续行，就接在这儿，不硬回车 */
        if (!(r + 1 < nrows && g_wrapr[r + 1] && emit[r + 1] > 0))
            fputc('\n', out);
    }
    free(emit);
}

/* 读一个 UTF-8 码点。c 是已经读到的首字节 */
static long read_cp(FILE *in, int c)
{
    int need, i;
    long cp;

    if (c < 0x80)
        return c;
    if (c >= 0xc2 && c <= 0xdf) {
        need = 1;
        cp = c & 0x1f;
    } else if (c >= 0xe0 && c <= 0xef) {
        need = 2;
        cp = c & 0x0f;
    } else if (c >= 0xf0 && c <= 0xf4) {
        need = 3;
        cp = c & 0x07;
    } else {
        return 0xfffd;
    }
    for (i = 0; i < need; i++) {
        int d = fgetc(in);
        if (d == EOF)
            return cp;
        if ((d & 0xc0) != 0x80)
            return 0xfffd;
        cp = (cp << 6) | (d & 0x3f);
    }
    return cp;
}

/* 把一个字符按终端的语义落到网格上（c 是已经读到的首字节） */
static void feed_char(int c, FILE *in)
{
    /*
     * 先剥掉 "^[[12;1R" 这种 CPR 回显。
     *
     * 终端对 ESC[6n（查光标位置）的应答是异步回来的，落在 shell 不再读它
     * 的时候，就被 tty 的 ECHOCTL 回显成可见字符 —— "^[" 是 ESC 的 caret
     * 写法。它既不是画面的一部分，也不是用户敲的东西，回放时清掉；
     * 形状不符就照原样画回去。
     */
    while (c == '^') {
        int d = fgetc(in);

        if (d == '[') {
            int e = fgetc(in);

            if (e == '[') {
                char num[24];
                int k = 0, semi = 0, f2, t;

                for (;;) {
                    f2 = fgetc(in);
                    if ((f2 >= '0' && f2 <= '9') || (f2 == ';' && !semi)) {
                        if (f2 == ';')
                            semi = 1;
                        if (k < (int)sizeof num - 1)
                            num[k++] = (char)f2;
                    } else {
                        break;
                    }
                }
                if (f2 == 'R' && semi)
                    return;         /* 整段就是应答，丢掉 */
                grid_put('^');
                grid_put('[');
                grid_put('[');
                for (t = 0; t < k; t++)
                    grid_put((unsigned char)num[t]);
                c = f2;
            } else {
                grid_put('^');
                grid_put('[');
                c = e;
            }
        } else {
            grid_put('^');
            c = d;
        }
        if (c == EOF)
            return;
    }

    if (c == '\n') {
        g_cy++;
        grid_ensure(g_cy);
        row_hard(g_cy);
        normalize_scroll();
    } else if (c == '\r') {
        g_cx = 0;
    } else if (c == '\b') {
        if (g_cx > 0)
            g_cx--;
    } else if (c == '\t') {
        g_cx = clamp_col((g_cx / 8 + 1) * 8);
    } else if (c == 0x07 || c == 0x0f || c == 0x0e || c == 0x00) {
        return;
    } else if (c < 0x20) {
        return;
    } else {
        grid_put(read_cp(in, c));
    }
}

static int clean_stream(FILE *in, FILE *out)
{
    int c;

    g_cy = g_cx = 0;
    sgr_reset();

    for (;;) {
        c = fgetc(in);
        if (c == EOF)
            break;

        if (c == 0x1b) {
            int c2 = fgetc(in);

            if (c2 == '[') {
                int params[16] = {0};
                int np = 0, cur = 0, has = 0, f, priv = 0;

                f = fgetc(in);
                while (f == '?' || f == '<' || f == '=' || f == '>' || f == '!') {
                    if (f == '?')
                        priv = 1;
                    f = fgetc(in);
                }
                for (;;) {
                    if (f == EOF) {
                        grid_dump(out);
                        return 0;
                    }
                    if (f >= '0' && f <= '9') {
                        cur = cur * 10 + (f - '0');
                        has = 1;
                    } else if (f == ';') {
                        if (np < 16)
                            params[np++] = has ? cur : 0;
                        cur = 0;
                        has = 0;
                    } else {
                        break;
                    }
                    f = fgetc(in);
                }
                if (has && np < 16)
                    params[np++] = cur;

                /*
                 * 参数后面还可能跟"中间字节"（0x20-0x2F：空格、"!"、"$" 等），
                 * 然后是 0x40-0x7E 的结束字节。DECRQM 就是 CSI ? 2004 $ p ——
                 * 不认这个 $ 的话，p 会被当成普通字符画到屏幕/日志上
                 * （fzf 启动时命令行会冒出个孤零零的 p）。
                 */
                while (f >= 0x20 && f <= 0x2f)
                    f = fgetc(in);

                if (priv) {
                    /*
                     * 私用模式：只认录制器写进日志的尺寸标记
                     * ESC [ ? 9990 ; COLS ; ROWS h
                     * 真实终端会忽略未知模式，所以日志仍可原样回放。
                     */
                    if ((f == 'h' || f == 'l') && np >= 1 && params[0] == 9990) {
                        /*
                         * 只改"从现在起按多少列折行"，不回改已有行。
                         * 真实终端变窄时会重排（把右边的内容折下去），这里
                         * 不做重排；但也绝不能把已经显示过的行尾截掉 ——
                         * 那样日志会随窗口宽度丢内容。已有行各自记住自己的
                         * 宽度，后续的擦除会连行尾一起清干净。
                         */
                        if (np >= 2 && params[1] > 0)
                            g_cols = params[1] > CLEAN_MAX_COLS ? CLEAN_MAX_COLS : params[1];
                        if (np >= 3 && params[2] > 0)
                            g_scr_rows = params[2];
                    }
                    continue;
                }
                clean_csi(f, params, np);
            } else if (c2 == ']') {
                for (;;) { /* OSC ... BEL 或 ESC \ */
                    int f = fgetc(in);
                    if (f == EOF) {
                        grid_dump(out);
                        return 0;
                    }
                    if (f == 0x07)
                        break;
                    if (f == 0x1b) {
                        int g = fgetc(in);
                        if (g == '\\' || g == EOF)
                            break;
                    }
                }
            } else if (c2 == '7') {
                g_save_cy = g_cy;
                g_save_cx = g_cx;
            } else if (c2 == '8') {
                g_cy = g_save_cy;
                g_cx = clamp_col(g_save_cx);
                grid_ensure(g_cy);
            } else if (c2 == 'M') { /* 反向索引 */
                if (g_cy > 0)
                    g_cy--;
                row_hard(g_cy);
            } else if (c2 == 'D') {
                g_cy++;
                grid_ensure(g_cy);
                row_hard(g_cy);
            } else if (c2 == 'E') {
                g_cy++;
                g_cx = 0;
                grid_ensure(g_cy);
                row_hard(g_cy);
            } else if (c2 == '(' || c2 == ')' || c2 == '*' || c2 == '+') {
                fgetc(in); /* 字符集选择，吞掉一个字节 */
            } else if (c2 == EOF) {
                break;
            }
            continue;
        }

        feed_char(c, in);
    }

    grid_dump(out);
    return 0;
}

/*
 * 退出前把 .rec 渲染成 .log。
 *
 * 为什么不是边录边写 .log：文本文件里没法"原地改写"（ZLE 每敲一个键
 * 都会重画同一行，长度还在变）。只能等录完，用字符网格重放一遍，
 * 屏幕上剩下的才是最终结果 —— 中间的重绘、进度条、退格全部自动收敛。
 *
 * 文件名后缀由 zsh 在 zshexit 里写进 <rec>.meta 第一行；拿不到就用时间戳。
 */
static void render_on_exit(const char *log_path)
{
    char rec[PATH_MAX], meta[PATH_MAX], dir[PATH_MAX], stem[PATH_MAX];
    char suffix[64], final[PATH_MAX];
    FILE *in, *out;
    int n;

    if (log_path == NULL || log_path[0] == '\0')
        return;
    sibling_path(log_path, "rec", rec, sizeof rec);
    in = fopen(rec, "rb");
    if (in == NULL)
        return;

    snprintf(meta, sizeof meta, "%s.meta", rec);
    n = read_meta_suffix(meta, suffix, sizeof suffix);
    split_path(rec, dir, sizeof dir, stem, sizeof stem);

    {
        int k = 1;

        if (n > 0)
            snprintf(final, sizeof final, "%s/%s_%s.log", dir, stem, suffix);
        else
            snprintf(final, sizeof final, "%s/%s.log", dir, stem);
        while (access(final, F_OK) == 0 && k < 100) {
            k++;
            if (n > 0)
                snprintf(final, sizeof final, "%s/%s_%s-%d.log", dir, stem, suffix, k);
            else
                snprintf(final, sizeof final, "%s/%s-%d.log", dir, stem, k);
        }
    }

    out = fopen(final, "wb");
    if (out == NULL) {
        fclose(in);
        return;
    }
    copy_meta_header(meta, out);   /* 没命令也有时间/目录可留 */

    g_color = 0;                 /* .log 给人读，不要转义序列 */
    g_cols = CLEAN_DEF_COLS;
    g_scr_rows = CLEAN_DEF_ROWS;
    clean_stream(in, out);
    fclose(out);
    fclose(in);
    chmod(final, 0600);   /* 录制内容是私人东西，别落成 0644 */

    {
        char fdir[PATH_MAX], fstem[PATH_MAX], newrec[PATH_MAX];

        split_path(final, fdir, sizeof fdir, fstem, sizeof fstem);
        snprintf(newrec, sizeof newrec, "%s/%s.rec", fdir, fstem);
        if (strcmp(newrec, rec) != 0)
            rename(rec, newrec);  /* 不改名的话 zslog-cat 按文件名找不到原始流 */
    }
    unlink(meta);
}

int main(int argc, char **argv)
{
    static char *default_cmd[] = { "/bin/zsh", "-i", NULL };

    g_argc = argc;
    g_argv = argv;

    /*
     * wcwidth 依赖 locale。日志里的中日文要按 2 列算，所以必须先
     * 切到 UTF-8 locale；切不到就退回 1 列（会略窄，但不至于崩）。
     */
    if (setlocale(LC_CTYPE, "") == NULL || MB_CUR_MAX == 1) {
        if (setlocale(LC_CTYPE, "en_US.UTF-8") == NULL)
            setlocale(LC_CTYPE, "C.UTF-8");
    }

    if (argc >= 2 && strcmp(argv[1], "clean") == 0) {
        FILE *in, *out = stdout;
        const char *path = NULL, *meta = NULL, *out_path = NULL;
        int i;

        for (i = 2; i < argc; i++) {
            if (strcmp(argv[i], "--cols") == 0 && i + 1 < argc)
                g_cols = atoi(argv[++i]);
            else if (strcmp(argv[i], "--rows") == 0 && i + 1 < argc)
                g_scr_rows = atoi(argv[++i]);
            else if (strcmp(argv[i], "--color") == 0)
                g_color = 1;
            else if (strcmp(argv[i], "--plain") == 0)
                g_color = 0;
            else if (strcmp(argv[i], "--meta") == 0 && i + 1 < argc)
                meta = argv[++i];
            else if (strcmp(argv[i], "--out") == 0 && i + 1 < argc)
                out_path = argv[++i];
            else if (path == NULL)
                path = argv[i];
        }
        if (path == NULL)
            die("用法: zslog clean FILE [--cols N] [--rows N] "
                "[--color|--plain] [--meta FILE] [--out FILE]");
        if (g_cols <= 0)
            g_cols = CLEAN_DEF_COLS;
        if (g_cols > CLEAN_MAX_COLS)
            g_cols = CLEAN_MAX_COLS;
        if (g_scr_rows <= 0)
            g_scr_rows = CLEAN_DEF_ROWS;

        in = fopen(path, "rb");
        if (in == NULL)
            die("无法打开文件");
        if (out_path != NULL) {
            out = fopen(out_path, "wb");
            if (out == NULL)
                die("无法写入输出文件");
        }
        if (meta != NULL)
            copy_meta_header(meta, out);
        clean_stream(in, out);
        fclose(in);
        if (out != stdout)
            fclose(out);
        return 0;
    }

    /* 不带子命令也当作 run：插件里 exec 的就是不带参数的 zslog，
       这样 ps / 窗口标题里只会出现 "zslog"。 */
    if (argc < 2 || strcmp(argv[1], "run") == 0) {
        const char *log_path = NULL;
        int i = (argc >= 2 && strcmp(argv[1], "run") == 0) ? 2 : 1;

        if (i < argc && strcmp(argv[i], "--log") == 0) {
            if (i + 1 >= argc)
                die("run 缺少 --log 的文件名");
            log_path = argv[i + 1];
            i += 2;
        }
        if (log_path == NULL)
            log_path = getenv("ZSLOG_LOG");
        if (i < argc && strcmp(argv[i], "--") == 0)
            i++;
        if (log_path == NULL || log_path[0] == '\0')
            die("run 缺少日志文件名（--log 或 $ZSLOG_LOG）");

        return relay(log_path, i < argc ? argv + i : default_cmd);
    }

    die("未知子命令");
    return 1;
}
