import 'package:flutter/material.dart';

/// Font size selection dialog
class FontSizeDialog extends StatelessWidget {
  final double currentSize;

  static const List<double> _fontSizes = [10, 12, 14, 16, 18, 20];

  const FontSizeDialog({
    super.key,
    required this.currentSize,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Font Size'),
      content: SingleChildScrollView(
        child: RadioGroup<double>(
          groupValue: currentSize,
          onChanged: (value) {
            if (value != null) {
              Navigator.pop(context, value);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _fontSizes.map((size) {
              return RadioListTile<double>(
                title: Text(size.toInt().toString()),
                value: size,
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
