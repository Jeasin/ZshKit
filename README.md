# ZshKit

一套走 XDG 布局的 macOS Zsh 配置：XDG 化、无插件管理器、不依赖 oh-my-zsh。
插件源码随仓库一起分发，安装时不需要 Git。

```bash
curl -fsSL https://raw.githubusercontent.com/Jeasin/ZshKit/main/install.sh | zsh
```

## 安装

**要求**：macOS（Apple Silicon 或 Intel）、系统自带 zsh、已安装 Homebrew。

Homebrew 没装的话先装：

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

然后执行上面那条安装命令。全过程约 1 分钟，其中安装依赖占大头。

安装脚本会：检测系统与架构（`/opt/homebrew`、`/usr/local` 都支持）→ 按需安装缺失依赖
→ 下载 main 分支最新 tarball → 校验语法 → 原子替换配置 → 替换 `/etc/zshenv`
→ 创建 XDG 目录 → 退出时清理所有临时文件。

安装完成后**新开一个终端窗口**才会生效（当前窗口仍是旧配置）。

## 更新

同样的命令再执行一次，即全量同步到 main 分支最新状态：

```bash
curl -fsSL https://raw.githubusercontent.com/Jeasin/ZshKit/main/install.sh | zsh
```

## 覆盖说明

每次安装都是**全量替换，不备份、不合并**：

| 路径 | 处理 |
| --- | --- |
| `~/.config/zsh` | 整个目录替换。里面的自定义修改、`secrets.zsh`、`.zsh_sessions` 都会消失 |
| `/etc/zshenv` | 整个文件替换（这是 ZDOTDIR 引导，必须的） |
| `~/.local/share` | 保留 |
| `~/.local/state` | 保留（命令历史在 `~/.local/state/zsh/history`） |
| `~/.cache` | 保留 |
| `~/.zshrc`、`~/.zprofile`、`~/.zshenv` | 不创建。全部配置都在 `~/.config/zsh` 内 |

想保留自己的东西，别直接改仓库里的文件——新建一个不被覆盖的文件，并在 `~/.config/zsh/.zshrc`
末尾加一行 source（下次更新时这一行需要重新加，或者直接维护自己的 fork）。

## 依赖

安装脚本会自动补装缺失的部分（`brew list` 已有的跳过）：

| 命令 | formula | 用途 |
| --- | --- | --- |
| `starship` | starship | 提示符 |
| `zoxide` | zoxide | `cd` 智能跳转 |
| `fzf` | fzf | 模糊查找、Ctrl-T / Ctrl-R |
| `fd` | fd | fzf 的文件源 |
| `eza` | eza | `ls` 系列别名 |
| `bat` | bat | 预览、`man` 着色 |
| `rg` | ripgrep | 搜索 |

配置里对缺失的命令都做了守卫（没有也能启动，只是对应功能不生效）。
可选、按需自己装：`nvim`（`vim` 别名指向它）、`ffmpeg`/`flac`（`ffprobe`/`flac-min` 别名）、
`imagemagick`（`imev`）、`mosh`、`spek`。

## 结构

```text
ZshKit/
├── config/                 → 安装到 ~/.config/zsh
│   ├── .zshenv             XDG 变量、CARGO_HOME、EDITOR、MANPAGER
│   ├── .zprofile           Homebrew 环境、PATH 装配
│   ├── .zshrc              历史、补全、zoxide、fzf、加载其余文件
│   ├── aliases.zsh         别名与函数
│   ├── bindings.zsh        键位
│   ├── fzf.zsh             fzf UI / 预览 / 自定义 widget
│   ├── plugins.zsh         插件加载与自更新
│   ├── prompt.zsh          starship 初始化
│   ├── secrets.zsh         空模板（个人密钥放这里）
│   ├── starship.toml       提示符样式
│   └── plugins/            插件源码，随仓库分发
├── system/
│   └── zshenv              → 安装到 /etc/zshenv
└── install.sh
```

## 几个要知道的点

**为什么必须改 `/etc/zshenv`**
配置全在 `~/.config/zsh`，zsh 需要先被告知 `ZDOTDIR` 才会去那里读 `.zshrc`。
`/etc/zshenv` 是所有 zsh 实例启动时最先读的文件，是唯一干净的介入点。
家目录不留下任何 `.zshrc` / `.zprofile` / `.zshenv`。代价：macOS 大版本升级可能重置
`/etc/zshenv`，届时重跑一次安装即可（或 `echo $ZDOTDIR` 自查）。

**字体**
`starship.toml` 里用了 Nerd Font 私有区字符（Apple 图标、git 分支符号），
没装 Nerd Font 会显示成方块：

```bash
brew install --cask font-jetbrains-mono-nerd-font
```

**GPG**
`GPG_TTY` 在 `.zshrc` 里设置（仅交互 shell），非交互脚本不会被写入 `not a tty`。
Git 签名无需额外配置。

**会话录制**
`plugins/sessionlog.jeasin` 会把每个窗口的终端输出录到 `~/.local/state/zsh/logs`
（默认保留 14 天，`ZSH_NO_SESSION_LOG=1` 可关）。首次启动会用 Xcode Command Line
Tools 的 `cc` 编译一个小程序；没有 CLT 时会跳过录制，不影响使用。

**历史记录**
在 `~/.local/state/zsh/history`，不在配置目录里，所以更新配置不会丢历史。

## 卸载

```bash
rm -rf ~/.config/zsh
sudo rm -f /etc/zshenv          # 或恢复系统原版
```

清干净后新开窗口即为系统默认 zsh。
