import 'package:flutter/material.dart';

import '../../services/terminal/terminal_font_styles.dart';

/// フォントファミリー選択ダイアログ
class FontFamilyDialog extends StatelessWidget {
  final String currentFamily;

  const FontFamilyDialog({
    super.key,
    required this.currentFamily,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Font Family'),
      content: SingleChildScrollView(
        child: RadioGroup<String>(
          groupValue: currentFamily,
          onChanged: (value) {
            if (value != null) {
              Navigator.pop(context, value);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: TerminalFontStyles.supportedFontFamilies.map((family) {
              return RadioListTile<String>(
                title: Text(
                  family,
                  style: TerminalFontStyles.getTextStyle(
                    family,
                    fontSize: 14,
                    color: Theme.of(context).textTheme.bodyLarge?.color,
                  ),
                ),
                subtitle: Text(
                  'AaBbCc 012',
                  style: TerminalFontStyles.getTextStyle(
                    family,
                    fontSize: 12,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
                value: family,
              );
            }).toList(),
          ),
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
