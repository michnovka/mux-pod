import 'package:xterm/xterm.dart';

/// Bridges the app's existing tmux-style key labels to xterm input events.
///
/// The terminal surface remains the source of truth for escape-sequence
/// encoding, so the rest of the app can keep using labels such as `Enter`,
/// `C-c`, or `S-Enter` without sending tmux-format commands directly.
class XtermInputAdapter {
  static final Map<String, TerminalKey> _namedKeys = {
    'Enter': TerminalKey.enter,
    'Escape': TerminalKey.escape,
    'BSpace': TerminalKey.backspace,
    'Tab': TerminalKey.tab,
    'Up': TerminalKey.arrowUp,
    'Down': TerminalKey.arrowDown,
    'Left': TerminalKey.arrowLeft,
    'Right': TerminalKey.arrowRight,
    'Home': TerminalKey.home,
    'End': TerminalKey.end,
    'PPage': TerminalKey.pageUp,
    'NPage': TerminalKey.pageDown,
    'DC': TerminalKey.delete,
    'IC': TerminalKey.insert,
    'Space': TerminalKey.space,
    'F1': TerminalKey.f1,
    'F2': TerminalKey.f2,
    'F3': TerminalKey.f3,
    'F4': TerminalKey.f4,
    'F5': TerminalKey.f5,
    'F6': TerminalKey.f6,
    'F7': TerminalKey.f7,
    'F8': TerminalKey.f8,
    'F9': TerminalKey.f9,
    'F10': TerminalKey.f10,
    'F11': TerminalKey.f11,
    'F12': TerminalKey.f12,
  };

  static final Map<String, TerminalKey> _characterKeys = {
    ' ': TerminalKey.space,
    '-': TerminalKey.minus,
    '=': TerminalKey.equal,
    '[': TerminalKey.bracketLeft,
    ']': TerminalKey.bracketRight,
    '\\': TerminalKey.backslash,
    ';': TerminalKey.semicolon,
    '\'': TerminalKey.quote,
    '`': TerminalKey.backquote,
    ',': TerminalKey.comma,
    '.': TerminalKey.period,
    '/': TerminalKey.slash,
    '0': TerminalKey.digit0,
    '1': TerminalKey.digit1,
    '2': TerminalKey.digit2,
    '3': TerminalKey.digit3,
    '4': TerminalKey.digit4,
    '5': TerminalKey.digit5,
    '6': TerminalKey.digit6,
    '7': TerminalKey.digit7,
    '8': TerminalKey.digit8,
    '9': TerminalKey.digit9,
    'a': TerminalKey.keyA,
    'b': TerminalKey.keyB,
    'c': TerminalKey.keyC,
    'd': TerminalKey.keyD,
    'e': TerminalKey.keyE,
    'f': TerminalKey.keyF,
    'g': TerminalKey.keyG,
    'h': TerminalKey.keyH,
    'i': TerminalKey.keyI,
    'j': TerminalKey.keyJ,
    'k': TerminalKey.keyK,
    'l': TerminalKey.keyL,
    'm': TerminalKey.keyM,
    'n': TerminalKey.keyN,
    'o': TerminalKey.keyO,
    'p': TerminalKey.keyP,
    'q': TerminalKey.keyQ,
    'r': TerminalKey.keyR,
    's': TerminalKey.keyS,
    't': TerminalKey.keyT,
    'u': TerminalKey.keyU,
    'v': TerminalKey.keyV,
    'w': TerminalKey.keyW,
    'x': TerminalKey.keyX,
    'y': TerminalKey.keyY,
    'z': TerminalKey.keyZ,
  };

  static bool sendText(Terminal terminal, String text) {
    if (text.isEmpty) {
      return false;
    }
    terminal.textInput(text);
    return true;
  }

  static String applyModifiersToTmuxKey(
    String baseKey, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    final modifiers = <String>[];
    if (shift) {
      modifiers.add('S');
    }
    if (ctrl) {
      modifiers.add('C');
    }
    if (alt) {
      modifiers.add('M');
    }
    if (modifiers.isEmpty) {
      return baseKey;
    }
    return '${modifiers.join('-')}-$baseKey';
  }

  static String? encodeTmuxKey(String tmuxKey) {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);
    final handled = sendTmuxKey(terminal, tmuxKey);
    if (!handled) {
      return null;
    }
    return output.join();
  }

  static String? encodeOutputWithModifiers(
    String output, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    if (output.isEmpty || (!shift && !alt && !ctrl)) {
      return output;
    }

    final specialKey = _tmuxKeyForOutput(output);
    if (specialKey != null) {
      return encodeTmuxKey(
        applyModifiersToTmuxKey(specialKey, shift: shift, alt: alt, ctrl: ctrl),
      );
    }

    if (output.runes.length == 1) {
      return encodeTmuxKey(
        applyModifiersToTmuxKey(output, shift: shift, alt: alt, ctrl: ctrl),
      );
    }

    if (alt && !shift && !ctrl) {
      return '\x1b$output';
    }

    return null;
  }

  static bool sendPaste(Terminal terminal, String text) {
    if (text.isEmpty) {
      return false;
    }
    terminal.paste(text);
    return true;
  }

  static bool sendTmuxKey(Terminal terminal, String tmuxKey) {
    if (tmuxKey.isEmpty) {
      return false;
    }

    if (tmuxKey == 'BTab') {
      terminal.onOutput?.call('\x1b[Z');
      return true;
    }

    final parsed = _parseTmuxKey(tmuxKey);
    if (parsed == null) {
      return false;
    }

    final namedKey = _namedKeys[parsed.baseKey];
    if (namedKey != null) {
      final handled = terminal.keyInput(
        namedKey,
        shift: parsed.shift,
        alt: parsed.alt,
        ctrl: parsed.ctrl,
      );
      if (handled) {
        return true;
      }

      if (parsed.baseKey == 'Tab' && parsed.shift) {
        terminal.onOutput?.call('\x1b[Z');
        return true;
      }

      return false;
    }

    if (parsed.baseKey.length == 1) {
      return _sendCharacterKey(terminal, parsed);
    }

    return false;
  }

  static bool _sendCharacterKey(Terminal terminal, _ParsedTmuxKey parsed) {
    final baseKey = parsed.baseKey;
    final key = _characterKeys[baseKey.toLowerCase()];

    if (key != null && (parsed.shift || parsed.alt || parsed.ctrl)) {
      final handled = terminal.keyInput(
        key,
        shift: parsed.shift,
        alt: parsed.alt,
        ctrl: parsed.ctrl,
      );
      if (handled) {
        return true;
      }
    }

    final shiftedChar = parsed.shift ? _applyShiftModifier(baseKey) : baseKey;

    if (shiftedChar == null) {
      return false;
    }

    if (parsed.ctrl || parsed.alt) {
      final handled = terminal.charInput(
        shiftedChar.codeUnitAt(0),
        alt: parsed.alt,
        ctrl: parsed.ctrl,
      );
      if (handled) {
        return true;
      }

      var text = shiftedChar;
      if (parsed.alt) {
        text = '\x1b$text';
      }
      terminal.textInput(text);
      return true;
    }

    terminal.textInput(shiftedChar);
    return true;
  }

  static String? _applyShiftModifier(String baseKey) {
    if (baseKey.isEmpty) {
      return null;
    }

    const shiftedPunctuation = {
      '1': '!',
      '2': '@',
      '3': '#',
      '4': r'$',
      '5': '%',
      '6': '^',
      '7': '&',
      '8': '*',
      '9': '(',
      '0': ')',
      '-': '_',
      '=': '+',
      '[': '{',
      ']': '}',
      '\\': '|',
      ';': ':',
      '\'': '"',
      '`': '~',
      ',': '<',
      '.': '>',
      '/': '?',
    };

    if (RegExp(r'^[a-zA-Z]$').hasMatch(baseKey)) {
      return baseKey.toUpperCase();
    }

    return shiftedPunctuation[baseKey] ?? baseKey;
  }

  static String? _tmuxKeyForOutput(String output) {
    switch (output) {
      case '\r':
      case '\n':
        return 'Enter';
      case '\t':
        return 'Tab';
      case '\x1b':
        return 'Escape';
      case '\b':
      case '\x7f':
        return 'BSpace';
      default:
        return null;
    }
  }

  static _ParsedTmuxKey? _parseTmuxKey(String tmuxKey) {
    bool shift = false;
    bool alt = false;
    bool ctrl = false;
    final baseParts = <String>[];

    for (final part in tmuxKey.split('-')) {
      switch (part) {
        case 'S':
          shift = true;
          continue;
        case 'M':
          alt = true;
          continue;
        case 'C':
          ctrl = true;
          continue;
        default:
          baseParts.add(part);
      }
    }

    if (baseParts.isEmpty) {
      return null;
    }

    return _ParsedTmuxKey(
      baseKey: baseParts.join('-'),
      shift: shift,
      alt: alt,
      ctrl: ctrl,
    );
  }
}

class _ParsedTmuxKey {
  final String baseKey;
  final bool shift;
  final bool alt;
  final bool ctrl;

  const _ParsedTmuxKey({
    required this.baseKey,
    required this.shift,
    required this.alt,
    required this.ctrl,
  });
}
