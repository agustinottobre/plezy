import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../focus/focusable_text_field.dart';
import '../i18n/strings.g.dart';
import '../mixins/controller_disposer_mixin.dart';
import '../theme/mono_tokens.dart';
import '../utils/dialogs.dart';
import 'app_icon.dart';
import 'dialog_action_button.dart';

/// Shows a dialog to create a custom playlist.
///
/// When [allowTypeSelection] is true (e.g. on the top-level Playlists screen),
/// the user can choose between Video and Audio. When false (e.g. inside a specific
/// library that only hosts one type), the dialog only prompts for the name and
/// uses [initialType].
Future<({String name, String type})?> showCreateCustomPlaylistDialog(
  BuildContext context, {
  String initialType = 'video',
  bool allowTypeSelection = true,
}) {
  return showScopedDialog<({String name, String type})>(
    context: context,
    builder: (context) => _CreateCustomPlaylistDialog(
      initialType: initialType,
      allowTypeSelection: allowTypeSelection,
    ),
  );
}

class _CreateCustomPlaylistDialog extends StatefulWidget {
  final String initialType;
  final bool allowTypeSelection;

  const _CreateCustomPlaylistDialog({
    this.initialType = 'video',
    this.allowTypeSelection = true,
  });

  @override
  State<_CreateCustomPlaylistDialog> createState() => _CreateCustomPlaylistDialogState();
}

class _CreateCustomPlaylistDialogState extends State<_CreateCustomPlaylistDialog> with ControllerDisposerMixin {
  late final TextEditingController _controller;
  final _fieldFocusNode = FocusNode(debugLabel: 'CreatePlaylistField');
  final _cancelFocusNode = FocusNode(debugLabel: 'CreatePlaylistCancel');
  final _saveFocusNode = FocusNode(debugLabel: 'CreatePlaylistSave');
  final _videoFocusNode = FocusNode(debugLabel: 'CreatePlaylistVideo');
  final _audioFocusNode = FocusNode(debugLabel: 'CreatePlaylistAudio');
  late String _selectedType;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = createTextEditingController();
    _selectedType = widget.initialType;
  }

  @override
  void dispose() {
    _fieldFocusNode.dispose();
    _cancelFocusNode.dispose();
    _saveFocusNode.dispose();
    _videoFocusNode.dispose();
    _audioFocusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _errorText = t.addServer.required);
      return;
    }
    Navigator.pop(context, (name: text, type: _selectedType));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.playlists.createCustomPlaylist),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FocusableTextField(
              controller: _controller,
              focusNode: _fieldFocusNode,
              autofocus: true,
              decoration: InputDecoration(
                labelText: t.playlists.playlistName,
                hintText: t.playlists.enterPlaylistName,
                errorText: _errorText,
              ),
              onChanged: (val) {
                if (_errorText != null && val.trim().isNotEmpty) {
                  setState(() => _errorText = null);
                }
              },
              onSubmitted: (_) => _submit(),
            ),
            if (widget.allowTypeSelection) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _TypeSelectOption(
                      icon: Symbols.movie_rounded,
                      label: t.fileInfo.video,
                      selected: _selectedType == 'video',
                      focusNode: _videoFocusNode,
                      onTap: () => setState(() => _selectedType = 'video'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _TypeSelectOption(
                      icon: Symbols.music_note_rounded,
                      label: t.fileInfo.audio,
                      selected: _selectedType == 'audio',
                      focusNode: _audioFocusNode,
                      onTap: () => setState(() => _selectedType = 'audio'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        DialogActionButton(
          focusNode: _cancelFocusNode,
          onPressed: () => Navigator.pop(context),
          onNavigateRight: _saveFocusNode.requestFocus,
          label: t.common.cancel,
        ),
        DialogActionButton(
          onPressed: _submit,
          isPrimary: true,
          label: t.playlists.create,
          focusNode: _saveFocusNode,
          onNavigateLeft: _cancelFocusNode.requestFocus,
        ),
      ],
    );
  }
}

class _TypeSelectOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _TypeSelectOption({
    required this.icon,
    required this.label,
    required this.selected,
    this.focusNode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final t = tokens(context);

    final borderColor = selected ? colorScheme.primary : t.text.withValues(alpha: 0.15);
    final backgroundColor = selected
        ? colorScheme.primary.withValues(alpha: 0.12)
        : t.text.withValues(alpha: 0.04);
    final foregroundColor = selected ? colorScheme.primary : t.text.withValues(alpha: 0.7);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        focusNode: focusNode,
        onTap: onTap,
        borderRadius: BorderRadius.circular(t.radiusMd),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(t.radiusMd),
            border: Border.all(
              color: borderColor,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(
                icon,
                size: 20,
                color: foregroundColor,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: foregroundColor,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
