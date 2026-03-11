import 'package:flutter/material.dart';

/// テーマ選択ダイアログ
class ThemeDialog extends StatelessWidget {
  final bool isDarkMode;

  const ThemeDialog({
    super.key,
    required this.isDarkMode,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Theme'),
      content: RadioGroup<bool>(
        groupValue: isDarkMode,
        onChanged: (value) {
          if (value != null) {
            Navigator.pop(context, value);
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<bool>(
              title: const Text('Dark'),
              value: true,
            ),
            RadioListTile<bool>(
              title: const Text('Light'),
              value: false,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
