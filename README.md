# Kristal terminal-cli

[![license](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue)](LICENSE-APACHE) <img src="https://img.shields.io/github/repo-size/Bli-AIk/kristal-terminal-cli.svg"/> <img src="https://img.shields.io/github/last-commit/Bli-AIk/kristal-terminal-cli.svg"/> <img src="https://img.shields.io/github/v/release/Bli-AIk/kristal-terminal-cli.svg"/> <br>
<img src="https://img.shields.io/badge/Deltarune-001225?style=for-the-badge&labelColor=001225&logo=undertale&logoColor=ff0000" /> <img src="https://img.shields.io/badge/Lua-2C2D72?style=for-the-badge&logo=lua&logoColor=white" /> <img src="https://img.shields.io/badge/Kristal-FF6B35?style=for-the-badge&logo=love2d&logoColor=white" />

| 简体中文 | English                   |
| -------- | ------------------------- |
| 简体中文 | [English](./README_en.md) |

## Kristal 版本支持

| `kristal`                                                                                                                          | `kristal-terminal-cli` |
| ---------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| [v0.11.0-dev](https://github.com/KristalTeam/Kristal/commit/f62afea63ccab02f468c24ac0d096bd8a2c9aa81) (`f62afea`, 2026-08-16) | 0.2.1                  |

一个为 **Linux**（及其他 POSIX）终端设计的可选 Kristal v0.11.0-dev 开发库，把游戏内的调试控制台挂到当前进程的 stdin/stdout 上。

## 安装

以子模块方式安装（建议，便于跟随版本更新）：

```sh
git submodule add https://github.com/Bli-AIk/kristal-terminal-cli.git libraries/terminal-cli
git submodule update --init --recursive
```

也可以直接下载 [Release 源码](https://github.com/Bli-AIk/kristal-terminal-cli/releases)，或克隆仓库最新代码（滚动更新）后放入 `libraries/terminal-cli`。

## 使用方法

在 `mod.json` 中启用：

```json
"terminal-cli": {
    "enabled": true,
    "only_dev": true,
    "max_commands_per_frame": 8
}
```

在同一个终端里用 `just run` 运行 mod，或用项目自带的终端启动脚本开启独立控制台。本库面向本地开发，打包发布时应排除（没有 stdin/stdout 的环境下不可用）。

若某个终端需要引擎立即刷新 stdout，可选地把 Kristal 参数透传过去：`just run -- --disable-stdout-buffer`。这不是本库的必需启动参数，通常无需添加。

## 平台支持

本库主要面向 **Linux**（及其他 POSIX）终端设计，同时支持 **Windows**（用 `lovec.exe` 或从终端启动，需 Windows Terminal 或 Win10+ conhost）。

## 行编辑

内置分栏式终端控制台（TUI）：游戏输出显示在上方滚动区，输入行固定在底部，互不干扰。支持方向键移动光标、Home/End/Delete、↑↓ 历史记录、Ctrl+C 取消当前行、Ctrl+D 退出（空行时）、`clear()` 清屏、中文（UTF-8）输入。输入行和历史记录中的命令带基础 Lua 语法高亮（关键字/字符串/注释/数字）；命令无法识别时，命令和错误输出以淡红色显示。历史保存在 LÖVE 存档目录的 `terminal-cli-history.txt`。

需要从真实终端（tty）启动；stdin 为管道/重定向时自动降级为逐行输入（仅退格）。

## 许可证

MIT 或 Apache-2.0，任选其一。
