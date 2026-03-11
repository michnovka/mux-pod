import 'package:flutter/material.dart';

/// 最小フォントサイズ選択ダイアログ
///
/// ターミナル自動フィット時の最小フォントサイズを選択する。
/// この値を下回る場合は水平スクロールが有効になる。
class MinFontSizeDialog extends StatelessWidget {
  final double currentSize;

  // 最小フォントサイズの選択肢（6〜12pt）
  static const List<double> _minFontSizes = [6, 7, 8, 9, 10, 11, 12];

  const MinFontSizeDialog({
    super.key,
    required this.currentSize,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Minimum Font Size'),
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
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8.0),
                child: Text(
                  'Font size will not go below this value. Horizontal scroll is enabled for wider panes.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              ..._minFontSizes.map((size) {
                return RadioListTile<double>(
                  title: Text('${size.toInt()} pt'),
                  value: size,
                );
              }),
            ],
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
