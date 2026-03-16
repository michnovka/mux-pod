import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/terminal/terminal_search_state.dart';
import '../../../theme/design_colors.dart';

/// Search bar overlay displayed at the top of the terminal during search mode.
class TerminalSearchBar extends StatefulWidget {
  final TerminalSearchState searchState;
  final FocusNode focusNode;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onNextMatch;
  final VoidCallback onPreviousMatch;
  final VoidCallback onClose;
  final VoidCallback onToggleCaseSensitive;
  final VoidCallback onToggleRegex;

  const TerminalSearchBar({
    super.key,
    required this.searchState,
    required this.focusNode,
    required this.onQueryChanged,
    required this.onNextMatch,
    required this.onPreviousMatch,
    required this.onClose,
    required this.onToggleCaseSensitive,
    required this.onToggleRegex,
  });

  @override
  State<TerminalSearchBar> createState() => _TerminalSearchBarState();
}

class _TerminalSearchBarState extends State<TerminalSearchBar> {
  late final TextEditingController _textController;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.searchState.query);
  }

  @override
  void didUpdateWidget(covariant TerminalSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync text controller if query changed externally (e.g. cleared on close).
    if (widget.searchState.query != _textController.text) {
      _textController.text = widget.searchState.query;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.searchState;
    final hasError = state.regexError != null;
    final hasMatches = state.matches.isNotEmpty;

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: DesignColors.footerBackground,
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outline,
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 8),
          // Search text field
          Expanded(
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: _textController,
                focusNode: widget.focusNode,
                onChanged: widget.onQueryChanged,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 12,
                  color: DesignColors.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: 'Search...',
                  hintStyle: GoogleFonts.jetBrainsMono(
                    fontSize: 12,
                    color: DesignColors.textPrimary.withValues(alpha: 0.4),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 0,
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: DesignColors.keyBackground,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(
                      color: DesignColors.primary.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Match count label
          SizedBox(
            width: 64,
            child: Text(
              state.matchLabel,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.jetBrainsMono(
                fontSize: 10,
                color: hasError
                    ? DesignColors.error
                    : hasMatches
                        ? DesignColors.textPrimary.withValues(alpha: 0.7)
                        : DesignColors.textPrimary.withValues(alpha: 0.4),
              ),
            ),
          ),
          // Case sensitive toggle
          _buildToggleButton(
            icon: const Text(
              'Aa',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            isActive: state.caseSensitive,
            onPressed: widget.onToggleCaseSensitive,
            tooltip: 'Case sensitive',
          ),
          // Regex toggle
          _buildToggleButton(
            icon: const Text(
              '.*',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            isActive: state.regexEnabled,
            onPressed: widget.onToggleRegex,
            tooltip: 'Regex',
          ),
          // Previous match
          _buildIconButton(
            icon: Icons.keyboard_arrow_up,
            onPressed: hasMatches ? widget.onPreviousMatch : null,
            tooltip: 'Previous match',
          ),
          // Next match
          _buildIconButton(
            icon: Icons.keyboard_arrow_down,
            onPressed: hasMatches ? widget.onNextMatch : null,
            tooltip: 'Next match',
          ),
          // Close
          _buildIconButton(
            icon: Icons.close,
            onPressed: widget.onClose,
            tooltip: 'Close search',
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildToggleButton({
    required Widget icon,
    required bool isActive,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          icon: DefaultTextStyle(
            style: TextStyle(
              color: isActive
                  ? DesignColors.primary
                  : DesignColors.textPrimary.withValues(alpha: 0.5),
            ),
            child: icon,
          ),
          style: isActive
              ? IconButton.styleFrom(
                  backgroundColor:
                      DesignColors.primary.withValues(alpha: 0.15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4),
                  ),
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildIconButton({
    required IconData icon,
    required VoidCallback? onPressed,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 28,
        height: 28,
        child: IconButton(
          onPressed: onPressed,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          icon: Icon(
            icon,
            size: 18,
            color: onPressed != null
                ? DesignColors.textPrimary.withValues(alpha: 0.7)
                : DesignColors.textPrimary.withValues(alpha: 0.2),
          ),
        ),
      ),
    );
  }
}
