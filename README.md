# Kristal terminal-cli

An optional Kristal v0.10.0 development library that attaches the game's debug
console to the current process stdin/stdout.

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

## License

MIT or Apache-2.0, at your option.
