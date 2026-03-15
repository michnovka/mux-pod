import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../theme/design_colors.dart';

/// Dialog for renaming a tmux session or window.
///
/// Returns the new name via [Navigator.pop], or null on cancel.
class TmuxRenameDialog extends StatefulWidget {
  final String currentName;
  final String itemType; // "Session" or "Window"
  final List<String>? existingNames; // For uniqueness validation (sessions)

  const TmuxRenameDialog({
    super.key,
    required this.currentName,
    required this.itemType,
    this.existingNames,
  });

  @override
  State<TmuxRenameDialog> createState() => _TmuxRenameDialogState();
}

class _TmuxRenameDialogState extends State<TmuxRenameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentName);
    _nameController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.currentName.length,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String? _validate(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter a name';
    }
    if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(value)) {
      return 'Only letters, numbers, - _ . allowed';
    }
    if (value == widget.currentName) {
      return 'Name is unchanged';
    }
    if (widget.existingNames != null && widget.existingNames!.contains(value)) {
      return '${widget.itemType} "$value" already exists';
    }
    return null;
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, _nameController.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        'Rename ${widget.itemType}',
        style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
      ),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _nameController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '${widget.itemType} Name',
            hintText: widget.currentName,
            hintStyle: GoogleFonts.jetBrainsMono(
              fontSize: 14,
              color: isDark ? DesignColors.textMuted : DesignColors.textMutedLight,
            ),
            filled: true,
            fillColor: isDark ? DesignColors.inputDark : DesignColors.inputLight,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colorScheme.primary),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: DesignColors.error),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: DesignColors.error),
            ),
          ),
          style: GoogleFonts.jetBrainsMono(fontSize: 14),
          validator: _validate,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// Dialog for creating a new tmux session or window.
///
/// Returns the new name via [Navigator.pop], or null on cancel.
class TmuxNewItemDialog extends StatefulWidget {
  final String itemType; // "Session" or "Window"
  final List<String> existingNames;

  const TmuxNewItemDialog({
    super.key,
    required this.itemType,
    required this.existingNames,
  });

  @override
  State<TmuxNewItemDialog> createState() => _TmuxNewItemDialogState();
}

class _TmuxNewItemDialogState extends State<TmuxNewItemDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: _generateDefaultName());
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String _generateDefaultName() {
    final prefix = widget.itemType.toLowerCase();
    int index = 1;
    while (widget.existingNames.contains('$prefix-$index')) {
      index++;
    }
    return '$prefix-$index';
  }

  String? _validate(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter a name';
    }
    if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(value)) {
      return 'Only letters, numbers, - _ . allowed';
    }
    if (widget.existingNames.contains(value)) {
      return '${widget.itemType} "$value" already exists';
    }
    return null;
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, _nameController.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        'New ${widget.itemType}',
        style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
      ),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _nameController,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '${widget.itemType} Name',
            hintText: _generateDefaultName(),
            hintStyle: GoogleFonts.jetBrainsMono(
              fontSize: 14,
              color: isDark ? DesignColors.textMuted : DesignColors.textMutedLight,
            ),
            filled: true,
            fillColor: isDark ? DesignColors.inputDark : DesignColors.inputLight,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colorScheme.primary),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: DesignColors.error),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: DesignColors.error),
            ),
          ),
          style: GoogleFonts.jetBrainsMono(fontSize: 14),
          validator: _validate,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// Confirmation dialog for deleting a tmux session, window, or pane.
///
/// Returns `true` via [Navigator.pop] on confirm, `false` or null on cancel.
class TmuxConfirmDeleteDialog extends StatelessWidget {
  final String itemType; // "Session", "Window", or "Pane"
  final String itemName;

  const TmuxConfirmDeleteDialog({
    super.key,
    required this.itemType,
    required this.itemName,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Delete $itemType?',
        style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
      ),
      content: Text('Are you sure you want to delete "$itemName"?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: DesignColors.error),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
