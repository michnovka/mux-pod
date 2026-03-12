# MuxPod — Design Document v2

## 1. System Overview

### 1.1 Project Name
**MuxPod**

### 1.2 Purpose
Browse and control tmux sessions, windows, and panes running on PCs or servers from an Android smartphone via direct SSH connection.

### 1.3 Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Android Device                           │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                   Flutter (Dart)                          │  │
│  │                                                           │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐   │  │
│  │  │ Connections │  │ Session/    │  │ Terminal        │   │  │
│  │  │    List     │  │ Window/Pane │  │   View (xterm)  │   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘   │  │
│  │                         │                                 │  │
│  │  ┌─────────────────────┴────────────────────────────┐    │  │
│  │  │          State Management (flutter_riverpod)     │    │  │
│  │  └─────────────────────┬────────────────────────────┘    │  │
│  │                        │                                  │  │
│  │  ┌─────────────────────┴────────────────────────────┐    │  │
│  │  │              SSH Client (dartssh2)                │    │  │
│  │  └─────────────────────┬────────────────────────────┘    │  │
│  │                        │                                  │  │
│  │  ┌─────────────────────┴────────────────────────────┐    │  │
│  │  │         Key Store (flutter_secure_storage)       │    │  │
│  │  └──────────────────────────────────────────────────┘    │  │
│  └───────────────────────────────────────────────────────────┘  │
└───────────────────────────│─────────────────────────────────────┘
                            │ SSH (Port 22 or custom)
                            │
┌───────────────────────────│─────────────────────────────────────┐
│                   Remote Server (Linux)                         │
│                           │                                     │
│                   ┌───────┴───────┐                             │
│                   │    sshd       │                             │
│                   └───────┬───────┘                             │
│                           │                                     │
│                   ┌───────┴───────┐                             │
│                   │     tmux      │                             │
│                   └───────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
```

### 1.4 Changes from v1

| Item | v1 (old) | v2 (current) |
|------|----------|--------------|
| Connection method | WebSocket + Bun server | Direct SSH |
| Server-side requirement | Bun server daemon | sshd only (no extra setup) |
| Notifications | Server push | In-app only (tmux window flag monitoring) |
| Authentication | Token | SSH key / password |
| Framework | Expo (React Native) | Flutter |
| State management | Zustand | flutter_riverpod |
| Terminal rendering | Custom RichText | xterm package |
| Terminal transport | capture-pane polling | tmux control mode streaming |

## 2. Data Models

### 2.1 Connection

```dart
class Connection {
  final String id;          // UUID
  final String name;        // Display name (e.g., "Production AWS")
  final String host;        // Hostname or IP
  final int port;           // SSH port (default: 22)
  final String username;    // SSH username
  final String authMethod;  // 'password' or 'key'
  final String? keyId;      // SSH key ID (for key auth)
  final String? tmuxPath;   // Custom tmux binary path
  final DateTime? lastConnectedAt;
}
```

### 2.2 tmux Structure

```dart
class TmuxSession {
  final String name;
  final bool attached;
  final int windowCount;
  final List<TmuxWindow> windows;
}

class TmuxWindow {
  final int index;
  final String name;
  final bool active;
  final String? flags;         // tmux window flags (*, -, #, !, ~, Z, M)
  final List<TmuxPane> panes;
}

class TmuxPane {
  final int index;
  final String id;             // %0, %1, etc.
  final bool active;
  final int width;
  final int height;
  final int cursorX;
  final int cursorY;
}
```

### 2.3 SSH Key

```dart
class SshKeyInfo {
  final String id;             // UUID
  final String name;           // Display name
  final String type;           // 'ed25519' or 'rsa'
  final int? bits;             // RSA: 2048, 3072, 4096
  final String fingerprint;    // SHA256 fingerprint
  final String publicKey;      // Public key for display/export
  final bool hasPassphrase;    // Whether passphrase-protected
}
```

## 3. Terminal Transport

### 3.1 tmux Control Mode (Primary)

The active terminal uses tmux control mode (`tmux -C attach-session`) as the primary streaming transport:

- A dedicated SSH shell session runs `tmux -C attach-session -f ignore-size -t <session>`
- `TmuxControlClient` parses the control-mode protocol:
  - `%output <pane-id> <data>` — pane output (octal-escaped)
  - `%extended-output <pane-id> <metadata>: <data>` — extended pane output
  - `%begin`/`%end`/`%error` — command response framing
  - `%session-changed`, `%window-add`, etc. — async notifications
- Decoded output is fed directly into the xterm `Terminal` widget
- User input is sent via `tmux send-keys` through a separate persistent shell (input shell)

### 3.2 SSH Shell Channels

Three independent shell channels prevent contention:

1. **Control shell** — tmux metadata queries, pane list, session management
2. **Input shell** — user keystrokes routed through `tmux send-keys`
3. **Streaming shell** — long-lived tmux control-mode session for terminal output

## 4. Screen Flow

```
           ┌──────────────┐
           │  Dashboard   │ ← App start (center tab)
           │  (Sessions)  │
           └──────┬───────┘
                  │ Tap session / connect from Servers
                  ▼
           ┌──────────────┐
           │   Terminal   │ ← Full-screen, pushed on nav stack
           │   Screen     │
           └──────────────┘

Bottom Navigation:
┌──────────┬──────┬────────────┬────────┬──────────┐
│ Servers  │ Keys │ Dashboard  │ Notify │ Settings │
└──────────┴──────┴────────────┴────────┴──────────┘
```

## 5. Security

| Concern | Approach |
|---------|----------|
| SSH key storage | flutter_secure_storage (Android Keystore backed) |
| Password storage | flutter_secure_storage (encrypted) |
| Communication | SSH encryption (standard) |
| Screen lock | Optional lock on background |
| Biometric auth | Optional fingerprint/face unlock via local_auth |
| tmux command injection | Shell escaping via TmuxCommands helper |

## 6. Reconnection

- Unlimited auto-reconnect with exponential backoff (1s–60s with jitter)
- Network-aware: pauses reconnect when offline, resumes immediately when connectivity returns
- Generation counter prevents stale reconnect attempts from interfering
- On successful reconnect: recreates control/input shells, restarts tmux control-mode session, resyncs terminal state
