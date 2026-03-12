# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MuxPod is a Flutter app for browsing and controlling tmux sessions on remote servers via SSH from Android phones. It connects over SSH (dartssh2), uses tmux control mode (`tmux -C`) for real-time pane streaming, and renders terminal output with the xterm package.

## Development Commands

```bash
make run            # Debug run (injects GIT_REF via --dart-define)
make build-apk      # Release APK build
make analyze        # Static analysis (flutter analyze)
make test           # Run all tests (flutter test)

# Run a single test file
flutter test test/services/tmux/tmux_parser_test.dart

# Run on a specific device
flutter run -d android --dart-define=GIT_REF=$(git rev-parse --abbrev-ref HEAD)@$(git rev-parse --short HEAD)
```

## Architecture

### State Management (flutter_riverpod)

All state flows through Riverpod providers in `lib/providers/`. Key providers:

- **`sshProvider`** (`SshNotifier`) — manages SSH connection lifecycle, auto-reconnect with exponential backoff, network-aware pause/resume
- **`tmuxProvider`** (`TmuxNotifier`) — tracks tmux session tree and active session/window/pane selection
- **`connectionProvider`** — persists server connection configs (shared_preferences)
- **`settingsProvider`** — app settings (theme, font, etc.)
- **`activeSessionProvider`** — coordinates the terminal screen session lifecycle

SharedPreferences is bootstrapped in `main.dart` and injected via `sharedPreferencesProvider.overrideWithValue()`.

### SSH Layer (`lib/services/ssh/`)

`SshClient` wraps dartssh2 and maintains three separate shell channels:
1. **Control shell** (`_controlShell: PersistentShell`) — serialized tmux polling/control commands via `execPersistent()`
2. **Input shell** (`_inputShell: PersistentShell`) — dedicated channel for terminal input to avoid contention with polling
3. **Streaming shell** — long-lived shell for tmux control mode (`tmux -C attach-session`)

`PersistentShell` uses marker-delimited exec to avoid channel open/close overhead (1 RTT per command). Tmux binary path is auto-detected at connect time via `command -v tmux` with fallback to known paths.

### tmux Integration (`lib/services/tmux/`)

- **`TmuxControlClient`** — parses tmux control mode protocol (`%output`, `%begin`/`%end`, `%extended-output`, notifications). This is the primary data transport for terminal streaming.
- **`TmuxCommands`** — builds shell-escaped tmux commands
- **`TmuxParser`** — parses `list-sessions`/`list-windows`/`list-panes` output into `TmuxSession`/`TmuxWindow`/`TmuxPane` model objects

### Terminal Rendering (`lib/services/terminal/`)

- **`TerminalSnapshot`** / **`BoundedTextBuffer`** — buffered terminal content management
- **`TerminalOutputNormalizer`** — normalizes tmux control-mode output for xterm display
- **`XtermInputAdapter`** — translates mobile input (special keys bar, gestures) into terminal escape sequences
- **`PaneTerminalView`** — the core widget connecting xterm `Terminal` to tmux pane output

### Screen Navigation

5-tab bottom navigation: Dashboard, Servers (connections), Alerts (notification panes), Keys, Settings. Terminal screen is pushed on top when a pane is selected.

## Key Patterns

- **Immutable state with `copyWith()`** — all provider states use immutable classes with copyWith patterns. No freezed/code-gen.
- **tmux commands use shell escaping** — always go through `TmuxCommands` for building tmux commands; never construct raw tmux command strings.
- **Dual persistent shells** — control vs input shells are separated to prevent polling from blocking user input.
- **Reconnection** — `SshNotifier` handles unlimited auto-reconnect with exponential backoff (1s–60s), network-aware pause, and generation counters to prevent stale reconnect attempts.

## Documentation

- `docs/tmux-mobile-design-v2.md` — design document (architecture, data models, screen flow)
- `docs/ui-guidelines.md` — color palette, spacing, typography, screen layout
- `docs/coding-conventions.md` — naming, state management patterns, widget structure
- `docs/terminal-performance-redesign-plan.md` — architectural decision record for the terminal pipeline redesign (implemented)
