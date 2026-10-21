import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/app_database.dart';
import '../database/custom_playlist_operations.dart';
import '../i18n/strings.g.dart';
import '../media/episode_collection.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_library.dart';
import '../media/media_playlist.dart';
import '../media/play_queue.dart';
import '../providers/multi_server_provider.dart';
import '../providers/playback_state_provider.dart';
import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart';
import '../utils/music_navigation.dart';
import 'media_list_playback_launcher.dart';
import 'music/music_playback_service.dart';

/// Launcher for client-side custom playlists.
/// Loads mixed cross-server items from local SQLite and publishes
/// them through [LocalPlayQueue] and [PlaybackStateProvider.setPlaybackFromLocalQueue].
class CustomPlaylistLauncher extends MediaListPlaybackLauncher {
  final BuildContext context;
  final Future<void> Function(MediaItem item)? navigateForTesting;

  CustomPlaylistLauncher({required this.context, this.navigateForTesting});

  @override
  Future<PlayQueueResult> launchFromCollectionOrPlaylist({
    required Object item,
    required bool shuffle,
    MediaItem? startItem,
    bool showLoadingIndicator = true,
  }) async {
    if (item is! MediaPlaylist || !item.isCustom) {
      return PlayQueueError(ArgumentError('Expected custom MediaPlaylist, got: ${item.runtimeType}'));
    }

    final abort = AbortController();

    return executeWithLoading(
      context: context,
      showLoading: showLoadingIndicator && navigateForTesting == null,
      actionLabel: shuffle ? t.common.shuffle : t.common.play,
      abort: abort,
      execute: (dismissLoading) async {
        final db = context.read<AppDatabase>();
        final playbackState = context.read<PlaybackStateProvider>();
        final multiServer = context.read<MultiServerProvider?>();

        var items = await db.getCustomPlaylistItems(item.id);
        abort.throwIfAborted();
        if (items.isEmpty) return const PlayQueueEmpty();
        if (!context.mounted && navigateForTesting == null) return const PlayQueueCancelled();

        final expanded = <MediaItem>[];
        for (final it in items) {
          abort.throwIfAborted();
          if ((it.kind == MediaKind.show ||
                  it.kind == MediaKind.season ||
                  it.kind == MediaKind.album ||
                  it.kind == MediaKind.artist) &&
              multiServer != null) {
            final serverId = serverIdOrNull(it.serverId);
            final client = serverId != null ? multiServer.serverManager.getClient(serverId) : null;
            if (client != null) {
              try {
                final leaves = <MediaItem>[];
                await collectListLeaves(client, [it], unwatchedOnly: false, out: leaves);
                if (leaves.isNotEmpty) {
                  expanded.addAll(leaves.map((leaf) => leaf.copyWith(
                        serverId: leaf.serverId ?? it.serverId,
                        serverName: leaf.serverName ?? it.serverName,
                      )));
                  continue;
                }
              } catch (e) {
                appLogger.w('Failed to expand container $it in custom playlist launcher: $e');
              }
            }
          }
          expanded.add(it);
        }
        items = expanded;
        abort.throwIfAborted();
        if (!context.mounted && navigateForTesting == null) return const PlayQueueCancelled();

        if (item.playlistType == 'audio' || items.every((it) => it.kind.isMusic)) {
          final playableTracks = items.where((it) => it.kind == MediaKind.track).toList();
          final tracks = playableTracks.isNotEmpty ? playableTracks : items;
          await dismissLoading();
          if (navigateForTesting != null) {
            final target = (startItem != null && !shuffle) ? startItem : tracks.first;
            await navigateForTesting!(target);
          } else {
            if (!context.mounted) return const PlayQueueCancelled();
            await playTracks(
              context,
              tracks: tracks,
              startTrack: (startItem != null && startItem.kind == MediaKind.track) ? startItem : null,
              shuffle: shuffle,
              playContext: MusicPlayContext(title: item.title, kind: MusicPlayContextKind.playlist),
            );
          }
          return const PlayQueueSuccess();
        }

        final playableVideo = items.where((it) => it.kind.isVideo).toList();
        if (playableVideo.isEmpty) return const PlayQueueEmpty();
        items = playableVideo;

        if (shuffle) {
          items = List.of(items)..shuffle(Random());
        }

        int startIndex = 0;
        if (startItem != null && !shuffle) {
          final exactIndex = items.indexWhere((it) => it.id == startItem.id);
          if (exactIndex >= 0) {
            startIndex = exactIndex;
          } else {
            final descendantIndex = items.indexWhere(
              (it) => it.grandparentId == startItem.id || it.parentId == startItem.id,
            );
            if (descendantIndex >= 0) {
              startIndex = descendantIndex;
            }
          }
        }
        startIndex = startIndex.clamp(0, items.length - 1);

        await dismissLoading();
        if (!context.mounted && navigateForTesting == null) return const PlayQueueCancelled();
        return launchLocalQueuePlayback(
          context: context,
          playbackState: playbackState,
          queue: LocalPlayQueue(items: items, currentIndex: startIndex, shuffled: shuffle),
          contextKey: item.id,
          navigateForTesting: navigateForTesting,
        );
      },
    );
  }

  @override
  Future<PlayQueueResult> launchFromFolder({
    required MediaItem folder,
    required bool shuffle,
    bool showLoadingIndicator = true,
  }) async {
    return PlayQueueError(UnsupportedError('CustomPlaylistLauncher does not support folders'));
  }

  @override
  Future<PlayQueueResult> launchShuffledShow({required MediaItem metadata, bool showLoadingIndicator = true}) async {
    return PlayQueueError(UnsupportedError('CustomPlaylistLauncher does not support shows'));
  }

  @override
  Future<PlayQueueResult> launchShuffledLibrary({
    required MediaLibrary library,
    bool showLoadingIndicator = true,
  }) async {
    return PlayQueueError(UnsupportedError('CustomPlaylistLauncher does not support library shuffling'));
  }
}
