# MuxPod

A Flutter app for browsing and controlling tmux sessions, windows, and panes on remote servers via SSH from Android smartphones.

## Key Features

- Direct SSH connection (only requires sshd on the server side)
- tmux session/window/pane navigation
- ANSI color-enabled terminal display
- Special key input (ESC/CTRL/ALT, etc.)
- Notification rules (pattern-match based notifications)
- SSH key management (flutter_secure_storage support)
- Foldable device support

## Tech Stack

- Flutter 3.24+ / Dart 3.x
- flutter_riverpod (state management)
- dartssh2 (SSH connection)
- xterm (terminal display)
- flutter_secure_storage (secure storage)
- shared_preferences (settings persistence)

## Development Commands

```bash
flutter run             # Development run
flutter run -d android  # Android device/emulator
flutter analyze         # Static analysis
flutter test            # Run tests
flutter build apk       # Build APK
```

## Documentation

- @/docs/tmux-mobile-design-v2.md - Detailed design document
- @/docs/coding-conventions.md - Coding conventions
- @/docs/ui-guidelines.md - UI/UX guidelines
- @/docs/screens/ - Screen designs
- @/docs/logo/logo.svg - Logo

## Directory Structure

```
muxpod/
├── lib/
│   ├── main.dart           # Entry point
│   ├── providers/          # Riverpod providers
│   ├── screens/            # Screens
│   │   ├── connections/    # Connection management
│   │   ├── terminal/       # Terminal
│   │   ├── keys/           # SSH key management
│   │   ├── notifications/  # Notification rules
│   │   └── settings/       # Settings
│   ├── services/           # Business logic
│   │   ├── ssh/            # SSH connection
│   │   ├── tmux/           # tmux operations
│   │   ├── terminal/       # Terminal control
│   │   ├── keychain/       # Key management
│   │   └── notification/   # Notification engine
│   ├── theme/              # Theme & design
│   └── widgets/            # Shared widgets
├── android/                # Android native configuration
├── ios/                    # iOS native configuration
└── test/                   # Tests
```

## Key Types

```dart
class Connection {
  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;
}

class TmuxSession {
  final String name;
  final List<TmuxWindow> windows;
}

class TmuxWindow {
  final int index;
  final String name;
  final List<TmuxPane> panes;
}

class TmuxPane {
  final int index;
  final String id;
  final bool active;
}
```

## Security

- SSH keys: flutter_secure_storage (encrypted)
- Passwords: flutter_secure_storage (encrypted)
- Biometric authentication support (local_auth)

## Active Technologies
- Dart 3.10+ / Flutter 3.24+ + dartssh2 (SSH), xterm (terminal display), flutter_riverpod (state management)
- flutter_secure_storage (SSH keys/passwords), shared_preferences (connection settings)
- cryptography, pointycastle (SSH key generation)
- flutter_local_notifications, url_launcher (settings/notifications)
- Dart 3.x / Flutter 3.24+ + flutter_riverpod (state management), xterm (terminal display), dartssh2 (SSH connection) (001-terminal-width-resize)

## Recent Changes
- 001-ssh-terminal-integration: SSH connection, tmux attach, and key input implementation
- 003-ssh-key-management: Ed25519/RSA key generation, import, and management features
- 001-settings-notifications: Settings screen, notification rule CRUD, and theme switching
