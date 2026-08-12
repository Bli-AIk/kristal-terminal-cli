# Kristal terminal-cli

[![license](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue)](LICENSE-APACHE) <img src="https://img.shields.io/github/repo-size/Bli-AIk/kristal-terminal-cli.svg"/> <img src="https://img.shields.io/github/last-commit/Bli-AIk/kristal-terminal-cli.svg"/> <img src="https://img.shields.io/github/v/release/Bli-AIk/kristal-terminal-cli.svg"/> <br>
<img src="https://img.shields.io/badge/Deltarune-001225?style=for-the-badge&labelColor=001225&logo=undertale&logoColor=ff0000" /> <img src="https://img.shields.io/badge/Lua-2C2D72?style=for-the-badge&logo=lua&logoColor=white" /> <img src="https://img.shields.io/badge/Kristal-FF6B35?style=for-the-badge&logo=love2d&logoColor=white" />

| 简体中文 | English                   |
| -------- | ------------------------- |
| 简体中文 | [English](./README_en.md) |

## Kristal 版本支持

| `kristal`                                                                                                      | `kristal-terminal-cli` |
| -------------------------------------------------------------------------------------------------------------- | ---------------------- |
| [v0.10.0](https://github.com/KristalTeam/Kristal/commit/752bc0688ba97ca8a256ba9125b7e05a1ca6edbd) (`752bc068`) | 0.1.0                  |

一个为 **Linux**（及其他 POSIX）终端设计的可选 Kristal v0.10.0 开发库，把游戏内的调试控制台挂到当前进程的 stdin/stdout 上。

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

## 平台支持

本库主要面向 **Linux**（及其他 POSIX）终端设计。**不支持 Windows**——stdin 读取依赖 POSIX 的 `poll(2)`/`read(2)`，在 Windows 上会以 `unsupported_platform` 退出。

## 行编辑

终端保持默认的 canonical 模式，只支持最基本的退格功能：方向键、历史记录等编辑功能都不可用——按下方向键时，`ESC[A` 这类转义序列会被当成普通字符输进命令行。

想要 readline 式的编辑体验，Linux 下用 [rlwrap](https://github.com/hanslub42/rlwrap) 包一层启动命令即可：

```sh
rlwrap just run
```

这样在 `kristal> ` 提示符下输入命令时，方向键和历史记录就都能用了。注意 rlwrap 仅限 Unix，Windows 上不可用。

## 许可证

MIT 或 Apache-2.0，任选其一。
