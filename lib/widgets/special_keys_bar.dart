import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/design_colors.dart';

class SpecialKeysBar extends StatelessWidget {
  final ValueChanged<String> onLiteralKeyPressed;
  final ValueChanged<String> onSpecialKeyPressed;
  final VoidCallback onCtrlToggle;
  final VoidCallback onAltToggle;
  final bool ctrlPressed;
  final bool altPressed;
  final bool hapticFeedback;

  const SpecialKeysBar({
    super.key,
    required this.onLiteralKeyPressed,
    required this.onSpecialKeyPressed,
    required this.onCtrlToggle,
    required this.onAltToggle,
    required this.ctrlPressed,
    required this.altPressed,
    this.hapticFeedback = true,
  });

  static const List<_ExtraKeySpec> _topRowKeys = [
    _ExtraKeySpec.special(label: 'ESC', value: 'Escape'),
    _ExtraKeySpec.literal(label: '/', value: '/'),
    _ExtraKeySpec.literal(label: '-', value: '-'),
    _ExtraKeySpec.special(label: 'HOME', value: 'Home'),
    _ExtraKeySpec.special(label: '↑', value: 'Up'),
    _ExtraKeySpec.special(label: 'END', value: 'End'),
    _ExtraKeySpec.special(label: 'PGUP', value: 'PPage'),
  ];

  static const List<_ExtraKeySpec> _bottomRowKeys = [
    _ExtraKeySpec.special(label: 'TAB', value: 'Tab'),
    _ExtraKeySpec.modifier(label: 'CTRL'),
    _ExtraKeySpec.modifier(label: 'ALT'),
    _ExtraKeySpec.special(label: '←', value: 'Left'),
    _ExtraKeySpec.special(label: '↓', value: 'Down'),
    _ExtraKeySpec.special(label: '→', value: 'Right'),
    _ExtraKeySpec.special(label: 'PGDN', value: 'NPage'),
  ];

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: DesignColors.footerBackground,
        border: Border(top: BorderSide(color: colorScheme.outline, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildKeyRow(context, _topRowKeys),
              const SizedBox(height: 8),
              _buildKeyRow(context, _bottomRowKeys),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKeyRow(BuildContext context, List<_ExtraKeySpec> keys) {
    return Row(
      children: [
        for (var index = 0; index < keys.length; index += 1) ...[
          Expanded(child: _buildKeyButton(context, keys[index])),
          if (index != keys.length - 1) const SizedBox(width: 6),
        ],
      ],
    );
  }

  Widget _buildKeyButton(BuildContext context, _ExtraKeySpec key) {
    final isModifier = key.kind == _ExtraKeyKind.modifier;
    final isActive = switch (key.label) {
      'CTRL' => ctrlPressed,
      'ALT' => altPressed,
      _ => false,
    };

    final backgroundColor = isModifier && isActive
        ? DesignColors.primary.withValues(alpha: 0.22)
        : DesignColors.keyBackground;
    final borderColor = isModifier && isActive
        ? DesignColors.primary
        : Colors.white.withValues(alpha: 0.08);
    final textColor = isModifier && isActive
        ? DesignColors.primary
        : DesignColors.textPrimary.withValues(alpha: 0.92);

    final VoidCallback? onTap = switch (key.kind) {
      _ExtraKeyKind.literal => () => onLiteralKeyPressed(key.value!),
      _ExtraKeyKind.special => () => onSpecialKeyPressed(key.value!),
      _ExtraKeyKind.modifier => switch (key.label) {
        'CTRL' => onCtrlToggle,
        'ALT' => onAltToggle,
        _ => null,
      },
    };

    return Semantics(
      button: true,
      selected: isModifier && isActive,
      label: key.label,
      child: GestureDetector(
        onTapDown: (_) {
          if (hapticFeedback) {
            HapticFeedback.lightImpact();
          }
        },
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 34,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            key.label,
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: textColor,
              letterSpacing: key.label.length > 3 ? 0 : 0.2,
            ),
          ),
        ),
      ),
    );
  }
}

enum _ExtraKeyKind { literal, special, modifier }

class _ExtraKeySpec {
  final String label;
  final String? value;
  final _ExtraKeyKind kind;

  const _ExtraKeySpec.literal({required this.label, required this.value})
    : kind = _ExtraKeyKind.literal;

  const _ExtraKeySpec.special({required this.label, required this.value})
    : kind = _ExtraKeyKind.special;

  const _ExtraKeySpec.modifier({required this.label})
    : kind = _ExtraKeyKind.modifier,
      value = null;
}
