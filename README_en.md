# Kristal terminal-cli

[![license](https://img.shields.io/badge/license-MIT%2FApache--2.0-blue)](LICENSE-APACHE)

| English | 简体中文                |
| ------- | ----------------------- |
| English | [简体中文](./README.md) |

An optional Kristal v0.10.0 development library designed for **Linux** (and
other POSIX) terminals, which attaches the game's debug console to the current
process stdin/stdout.

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

## Platform Support

This library is designed primarily for **Linux** (and other POSIX) terminals.
**Windows is not supported** — the stdin reader relies on POSIX `poll(2)`/`read(2)`
and exits with `unsupported_platform` on Windows.

## Line Editing

The terminal stays in canonical mode: only basic backspace is available, and
arrow keys / history are not handled — arrow keys arrive as raw escape
sequences and get typed into the command line.

For a readline-style experience on Linux, wrap the launch command with
[rlwrap](https://github.com/hanslub42/rlwrap):

```sh
rlwrap just run
```

This gives you arrow keys and history at the `kristal> ` prompt. Note that
rlwrap is Unix-only and not available on Windows.

## License

MIT or Apache-2.0, at your option.
