# MuxPod Coding Conventions

## Naming

| Target | Convention | Example |
|--------|-----------|---------|
| Classes / Widgets | PascalCase | `TerminalScreen`, `SshClient` |
| Files | snake_case | `ssh_client.dart`, `tmux_parser.dart` |
| Providers | camelCase + `Provider` suffix | `sshProvider`, `tmuxProvider` |
| Services | PascalCase class | `SecureStorageService` |
| Type definitions | PascalCase | `TmuxSession`, `SshState` |
| Constants | camelCase or SCREAMING_SNAKE for top-level | `defaultPort` |
| Private members | leading underscore | `_client`, `_handleData` |

## State Management

### Riverpod Providers

- All providers live in `lib/providers/`
- Use `Notifier` + `NotifierProvider` for stateful providers
- State classes are immutable with `copyWith()` methods (no freezed/code-gen)
- Use `ref.watch()` in build methods, `ref.read()` in callbacks
- SharedPreferences is bootstrapped in `main.dart` and injected via `sharedPreferencesProvider.overrideWithValue()`

```dart
// Example: lib/providers/ssh_provider.dart
class SshNotifier extends Notifier<SshState> {
  @override
  SshState build() {
    ref.onDispose(() { /* cleanup */ });
    return const SshState();
  }
}

final sshProvider = NotifierProvider<SshNotifier, SshState>(() {
  return SshNotifier();
});
```

## SSH / tmux Operations

### SSH Client

- Use `SshClient` from `lib/services/ssh/ssh_client.dart`
- Connection management is coordinated through `sshProvider`
- Three shell channels are maintained: control shell, input shell, and streaming shell

### tmux Commands

- Use `TmuxCommands` from `lib/services/tmux/tmux_commands.dart` for building commands
- Shell escaping must always go through the escape methods (injection prevention)
- tmux binary path is auto-detected at connect time and resolved automatically

```dart
// Correct: use TmuxCommands to build escaped commands
final cmd = TmuxCommands.sendKeys(sessionName, windowIndex, paneId, keys);
await sshClient.execPersistentInput(cmd);

// Wrong: never construct raw tmux command strings
await sshClient.exec('tmux send-keys -t $sessionName $keys');
```

## Terminal Display

- Terminal rendering: `xterm` package with `Terminal` widget
- Terminal output transport: tmux control mode via `TmuxControlClient`
- Input adapter: `XtermInputAdapter` translates mobile input to escape sequences
- Font calculation: `FontCalculator` in `lib/services/terminal/font_calculator.dart`

## Widget Structure

### File Organization

```dart
// 1. imports
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// 2. widget class
class MyScreen extends ConsumerStatefulWidget {
  const MyScreen({super.key});

  @override
  ConsumerState<MyScreen> createState() => _MyScreenState();
}

class _MyScreenState extends ConsumerState<MyScreen> {
  // private state
  // lifecycle methods
  // build method
  // helper methods (prefixed with _build for UI, _ for logic)
}
```

### Screen Layout Pattern

- Screens use `ConsumerStatefulWidget` or `ConsumerWidget`
- App bar titles use `GoogleFonts.spaceGrotesk` with weight 700
- Monospace text uses `GoogleFonts.jetBrainsMono`
- Theme-aware colors check `Theme.of(context).brightness` and select from `DesignColors`

## Testing

- Tests mirror the `lib/` structure under `test/`
- Provider tests use `ProviderContainer` with overrides
- SSH tests mock `SshClient` via `sshClientFactoryProvider` override
- Widget tests use `pumpWidget` with `ProviderScope`
