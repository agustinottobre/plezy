import 'package:flutter/material.dart';

import '../focus/focusable_text_field.dart';
import '../i18n/strings.g.dart';
import '../mixins/controller_disposer_mixin.dart';
import '../utils/dialogs.dart';
import 'dialog_action_button.dart';

/// Shows a dialog to rename an existing custom playlist.
Future<String?> showRenameCustomPlaylistDialog(
  BuildContext context, {
  required String currentTitle,
}) {
  return showScopedDialog<String>(
    context: context,
    builder: (context) => _RenameCustomPlaylistDialog(currentTitle: currentTitle),
  );
}

class _RenameCustomPlaylistDialog extends StatefulWidget {
  final String currentTitle;

  const _RenameCustomPlaylistDialog({required this.currentTitle});

  @override
  State<_RenameCustomPlaylistDialog> createState() => _RenameCustomPlaylistDialogState();
}

class _RenameCustomPlaylistDialogState extends State<_RenameCustomPlaylistDialog> with ControllerDisposerMixin {
  late final TextEditingController _controller;
  final _fieldFocusNode = FocusNode(debugLabel: 'RenamePlaylistField');
  final _cancelFocusNode = FocusNode(debugLabel: 'RenamePlaylistCancel');
  final _saveFocusNode = FocusNode(debugLabel: 'RenamePlaylistSave');
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = createTextEditingController(text: widget.currentTitle);
    _controller.selection = TextSelection(baseOffset: 0, extentOffset: widget.currentTitle.length);
  }

  @override
  void dispose() {
    _fieldFocusNode.dispose();
    _cancelFocusNode.dispose();
    _saveFocusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _errorText = t.addServer.required);
      return;
    }
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.playlists.rename),
      content: SizedBox(
        width: 400,
        child: FocusableTextField(
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
          onNavigateDown: _saveFocusNode.requestFocus,
        ),
      ),
      actions: [
        DialogActionButton(
          focusNode: _cancelFocusNode,
          onPressed: () => Navigator.pop(context),
          label: t.common.cancel,
          onNavigateRight: _saveFocusNode.requestFocus,
        ),
        DialogActionButton(
          focusNode: _saveFocusNode,
          onPressed: _submit,
          label: t.common.save,
          isPrimary: true,
          onNavigateLeft: _cancelFocusNode.requestFocus,
          onNavigateUp: _fieldFocusNode.requestFocus,
        ),
      ],
    );
  }
}
