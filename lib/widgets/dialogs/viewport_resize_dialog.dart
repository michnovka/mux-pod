import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/terminal/font_calculator.dart';
import '../../theme/design_colors.dart';

/// Result of the viewport resize dialog.
class ViewportResizeResult {
  /// The selected column width.
  final int columns;

  /// The selected row height, or null to leave height unchanged.
  final int? rows;

  const ViewportResizeResult({required this.columns, this.rows});
}

/// Dialog for resizing the terminal viewport (tmux pane/window dimensions).
///
/// Shows the current pane dimensions, preset width options, a "Fit to Screen"
/// auto-calculation, and a custom width input. Returns a [ViewportResizeResult]
/// on confirmation, or null on cancel.
class ViewportResizeDialog extends StatefulWidget {
  /// Current pane width in columns.
  final int currentColumns;

  /// Current pane height in rows.
  final int currentRows;

  /// Available screen width in pixels (for auto-fit calculation).
  final double availableWidth;

  /// Current font size.
  final double fontSize;

  /// Current font family.
  final String fontFamily;

  const ViewportResizeDialog({
    super.key,
    required this.currentColumns,
    required this.currentRows,
    required this.availableWidth,
    required this.fontSize,
    required this.fontFamily,
  });

  @override
  State<ViewportResizeDialog> createState() => _ViewportResizeDialogState();
}

class _ViewportResizeDialogState extends State<ViewportResizeDialog> {
  static const List<int> _presetWidths = [80, 120, 132, 160, 200];

  late int _selectedColumns;
  late final TextEditingController _customColumnsController;
  late final TextEditingController _rowsController;
  bool _useCustomColumns = false;

  int get _fitColumns => FontCalculator.calculateFitColumns(
        availableWidth: widget.availableWidth,
        fontSize: widget.fontSize,
        fontFamily: widget.fontFamily,
      );

  @override
  void initState() {
    super.initState();
    _selectedColumns = widget.currentColumns;
    _customColumnsController =
        TextEditingController(text: widget.currentColumns.toString());
    _rowsController = TextEditingController(text: widget.currentRows.toString());
  }

  @override
  void dispose() {
    _customColumnsController.dispose();
    _rowsController.dispose();
    super.dispose();
  }

  void _selectPreset(int columns) {
    setState(() {
      _selectedColumns = columns;
      _useCustomColumns = false;
      _customColumnsController.text = columns.toString();
    });
  }

  void _selectFitToScreen() {
    final fitCols = _fitColumns;
    setState(() {
      _selectedColumns = fitCols;
      _useCustomColumns = false;
      _customColumnsController.text = fitCols.toString();
    });
  }

  void _submit() {
    int columns = _selectedColumns;
    if (_useCustomColumns) {
      final parsed = int.tryParse(_customColumnsController.text);
      if (parsed == null || parsed < 20 || parsed > 500) return;
      columns = parsed;
    }

    final rows = int.tryParse(_rowsController.text);

    Navigator.pop(
      context,
      ViewportResizeResult(
        columns: columns,
        rows: rows != null && rows != widget.currentRows ? rows : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final fitCols = _fitColumns;

    return AlertDialog(
      title: Text(
        'Resize Viewport',
        style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Current dimensions
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark ? DesignColors.inputDark : DesignColors.inputLight,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Current: ${widget.currentColumns} x ${widget.currentRows}',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 14,
                  color: isDark
                      ? DesignColors.textSecondary
                      : DesignColors.textSecondaryLight,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 16),

            // Fit to Screen button
            FilledButton.icon(
              onPressed: _selectFitToScreen,
              icon: const Icon(Icons.fit_screen),
              label: Text('Fit to Screen ($fitCols cols)'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
            const SizedBox(height: 16),

            // Preset widths
            Text(
              'Preset Widths',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _presetWidths.map((width) {
                final isSelected = !_useCustomColumns &&
                    _selectedColumns == width;
                return ChoiceChip(
                  label: Text('$width'),
                  selected: isSelected,
                  onSelected: (_) => _selectPreset(width),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // Custom width input
            Text(
              'Custom Width',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _customColumnsController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Columns (20-500)',
                suffixText: 'cols',
                filled: true,
                fillColor:
                    isDark ? DesignColors.inputDark : DesignColors.inputLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colorScheme.primary),
                ),
              ),
              style: GoogleFonts.jetBrainsMono(fontSize: 14),
              onTap: () {
                setState(() {
                  _useCustomColumns = true;
                });
              },
              onChanged: (value) {
                setState(() {
                  _useCustomColumns = true;
                  final parsed = int.tryParse(value);
                  if (parsed != null) {
                    _selectedColumns = parsed;
                  }
                });
              },
            ),
            const SizedBox(height: 16),

            // Height input
            Text(
              'Height (optional)',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _rowsController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Rows',
                suffixText: 'rows',
                filled: true,
                fillColor:
                    isDark ? DesignColors.inputDark : DesignColors.inputLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colorScheme.primary),
                ),
              ),
              style: GoogleFonts.jetBrainsMono(fontSize: 14),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Resize'),
        ),
      ],
    );
  }
}
