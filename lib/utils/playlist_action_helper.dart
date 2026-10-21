import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/app_database.dart';
import '../database/custom_playlist_operations.dart';
import '../i18n/strings.g.dart';
import '../media/episode_collection.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../profiles/active_profile_provider.dart';
import '../utils/app_logger.dart';
import '../utils/dialogs.dart';
import '../utils/error_message_utils.dart';
import '../utils/library_refresh_notifier.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../widgets/collection_picker_dialog.dart';

/// Shows the playlist selection dialog and adds [item] to the chosen
/// custom or server playlist (or creates a new playlist).
///
/// If [item] is a container (show, season, album, artist), it expands its
/// playable leaves before adding to the playlist.
Future<void> showAddToPlaylistFlow(
  BuildContext context,
  MediaItem item, {
  MediaServerClient? client,
}) async {
  final resolvedClient = client ?? context.tryGetMediaClientForServer(serverIdOrNull(item.serverId));

  try {
    final result = await showScopedDialog<String>(
      context: context,
      builder: (dialogContext) => PlaylistSelectionDialog(client: resolvedClient, item: item),
    );

    if (result == null || !context.mounted) return;

    List<MediaItem> itemsToAdd = [item];
    if (resolvedClient != null &&
        (item.kind == MediaKind.show ||
            item.kind == MediaKind.season ||
            item.kind == MediaKind.album ||
            item.kind == MediaKind.artist)) {
      try {
        final leaves = <MediaItem>[];
        await collectListLeaves(resolvedClient, [item], unwatchedOnly: false, out: leaves);
        if (leaves.isNotEmpty) {
          itemsToAdd = leaves
              .map((leaf) => leaf.copyWith(
                    serverId: leaf.serverId ?? item.serverId,
                    serverName: leaf.serverName ?? item.serverName,
                  ))
              .toList();
        }
      } catch (e) {
        appLogger.w('Failed to expand container items for playlist: $e');
      }
    }
    if (!context.mounted) return;

    if (result == '_create_custom') {
      final name = await showTextInputDialog(
        context,
        title: t.playlists.createCustomPlaylist,
        labelText: t.playlists.playlistName,
        hintText: t.playlists.enterPlaylistName,
      );

      if (name == null || name.isEmpty || !context.mounted) return;

      final profileId = context.read<ActiveProfileProvider?>()?.activeId ?? '';
      final playlistType = item.kind.isMusic ? 'audio' : 'video';
      final db = context.read<AppDatabase>();
      await db.createCustomPlaylist(
        profileId: profileId,
        title: name,
        playlistType: playlistType,
        initialItems: itemsToAdd,
      );

      if (context.mounted) {
        showSuccessSnackBar(context, t.playlists.created);
        LibraryRefreshNotifier().notifyPlaylistsChanged();
      }
      return;
    }

    if (result.startsWith('custom:')) {
      final playlistId = result.substring('custom:'.length);
      final db = context.read<AppDatabase>();
      await db.addItemsToCustomPlaylist(playlistId: playlistId, items: itemsToAdd);

      if (context.mounted) {
        showSuccessSnackBar(context, t.playlists.itemAdded);
        LibraryRefreshNotifier().notifyPlaylistsChanged();
      }
      return;
    }

    if (resolvedClient == null) {
      showErrorSnackBar(context, t.messages.playbackServerUnavailable);
      return;
    }

    final serverPlaylistResult = (result == '_create_server') ? '_create_new' : result;

    if (serverPlaylistResult == '_create_new') {
      final name = await showTextInputDialog(
        context,
        title: t.playlists.create,
        labelText: t.playlists.playlistName,
        hintText: t.playlists.enterPlaylistName,
      );

      if (name == null || name.isEmpty || !context.mounted) return;

      final created = await resolvedClient.createPlaylist(title: name, items: itemsToAdd);
      if (!context.mounted) return;

      if (created != null) {
        showSuccessSnackBar(context, t.playlists.created);
        LibraryRefreshNotifier().notifyPlaylistsChanged();
      } else {
        showErrorSnackBar(context, t.playlists.errorCreating);
      }
    } else {
      final success = await resolvedClient.addToPlaylist(playlistId: serverPlaylistResult, items: itemsToAdd);
      if (!context.mounted) return;

      if (success) {
        showSuccessSnackBar(context, t.playlists.itemAdded);
        LibraryRefreshNotifier().notifyPlaylistsChanged();
      } else {
        showErrorSnackBar(context, t.playlists.errorAdding);
      }
    }
  } catch (e, stackTrace) {
    appLogger.e('Error in add to playlist flow', error: e, stackTrace: stackTrace);
    if (context.mounted) {
      showErrorSnackBar(context, '${t.playlists.errorLoading}: ${localizedErrorReason(e)}');
    }
  }
}
