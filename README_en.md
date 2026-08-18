# Kristal terminal-cli

[![license](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue)](LICENSE-APACHE) <img src="https://img.shields.io/github/repo-size/Bli-AIk/kristal-terminal-cli.svg"/> <img src="https://img.shields.io/github/last-commit/Bli-AIk/kristal-terminal-cli.svg"/> <img src="https://img.shields.io/github/v/release/Bli-AIk/kristal-terminal-cli.svg"/> <br>
<img src="https://img.shields.io/badge/Deltarune-001225?style=for-the-badge&labelColor=001225&logo=undertale&logoColor=ff0000" /> <img src="https://img.shields.io/badge/Lua-2C2D72?style=for-the-badge&logo=lua&logoColor=white" /> <img src="https://img.shields.io/badge/Kristal-FF6B35?style=for-the-badge&logo=love2d&logoColor=white" />

| English | 简体中文                |
| ------- | ----------------------- |
| English | [简体中文](./README.md) |

## Kristal Version Support

| `kristal`                                                                                                                    | `kristal-terminal-cli` |
| -------------------------------------------------------------------------------------------------------------------------------| ----- |
| [v0.11.0-dev](https://github.com/KristalTeam/Kristal/commit/f62afea63ccab02f468c24ac0d096bd8a2c9aa81) (`f62afea`, 2026-08-16) | 0.2.2 |
| [v0.10.0](https://github.com/KristalTeam/Kristal/commit/752bc0688ba97ca8a256ba9125b7e05a1ca6edbd) (`752bc068`, 2026-06-23)    | 0.1.0 |

An optional Kristal development library designed for **Linux** (and other
POSIX) and **Windows** terminals, which attaches the game's debug console to the
current process stdin/stdout.

## Install

Install it as a submodule (recommended — keeps the library versioned alongside your mod):

```sh
git submodule add https://github.com/Bli-AIk/kristal-terminal-cli.git libraries/terminal-cli
git submodule update --init --recursive
```

Alternatively, download the [release source](https://github.com/Bli-AIk/kristal-terminal-cli/releases), or clone the latest code (rolling updates), and place it in `libraries/terminal-cli`.

## How to Use

Enable it in `mod.json`:

```json
"terminal-cli": {
    "enabled": true,
    "only_dev": true,
    "max_commands_per_frame": 8
}
```

Run the mod from the same terminal with `just run`, or use a project-specific
terminal launcher for a detached console. The library is intended for local
development and should be excluded from release packages when stdin/stdout are
not available.

If a terminal needs the engine to flush stdout immediately, pass Kristal's
optional flag through with `just run -- --disable-stdout-buffer`. It is not
required for normal use.

## Platform Support

This library is designed primarily for **Linux** (and other POSIX) terminals,
and also supports **Windows** (launch with `lovec.exe` or from a terminal,
using Windows Terminal or a Win10+ conhost).

## Line Editing

A split-view terminal console (TUI) is built in: game output scrolls in the
upper region, and the input line stays fixed at the bottom. Arrow keys move
the cursor, Home/End/Delete edit, ↑/↓ browse history, Ctrl+C cancels the
current line, Ctrl+D exits (on an empty line), `clear()` clears the screen,
and Chinese (UTF-8) input works. The input line and commands in the history
are highlighted with basic Lua syntax colors (keywords/strings/comments/
numbers); unrecognized commands and their error output are shown in pale red.
History is persisted to `terminal-cli-history.txt` in the LÖVE save directory.

A real terminal (tty) is required; when stdin is a pipe or redirect, the
library falls back to plain line-by-line input (backspace only).

## License

MIT or Apache-2.0, at your option.
