import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_playlist.dart';
import 'app_database.dart';

extension CustomPlaylistOperations on AppDatabase {
  /// Create a new custom playlist with optional initial items.
  Future<CustomPlaylistRow> createCustomPlaylist({
    required String profileId,
    required String title,
    String playlistType = 'video',
    String? summary,
    String? thumbPath,
    List<MediaItem>? initialItems,
  }) {
    return transaction(() async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final playlistId = const Uuid().v4();
      final effectiveThumbPath =
          thumbPath ?? (initialItems != null && initialItems.isNotEmpty ? initialItems.first.posterThumb() : null);

      final row = CustomPlaylistRow(
        id: playlistId,
        profileId: profileId,
        title: title,
        playlistType: playlistType,
        summary: summary,
        thumbPath: effectiveThumbPath,
        createdAt: now,
        updatedAt: now,
      );

      await into(customPlaylists).insert(row);

      if (initialItems != null && initialItems.isNotEmpty) {
        await batch((b) {
          for (var i = 0; i < initialItems.length; i++) {
            final item = initialItems[i];
            b.insert(
              customPlaylistItems,
              CustomPlaylistItemsCompanion.insert(
                playlistId: playlistId,
                sortOrder: i,
                mediaJson: jsonEncode(item.toJson()),
                mediaGlobalKey: item.globalKey,
                addedAt: now,
              ),
            );
          }
        });
      }

      return row;
    });
  }

  /// Retrieve all custom playlists for a profile, optionally filtered by [playlistType].
  Future<List<MediaPlaylist>> getCustomPlaylists({required String profileId, String? playlistType}) async {
    final query = select(customPlaylists)
      ..where((t) => t.profileId.equals(profileId))
      ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]);

    if (playlistType != null) {
      query.where((t) => t.playlistType.equals(playlistType));
    }

    final rows = await query.get();
    if (rows.isEmpty) return const [];

    final playlistIds = rows.map((r) => r.id).toList();
    final allItems = await (select(customPlaylistItems)
          ..where((t) => t.playlistId.isIn(playlistIds))
          ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
        .get();

    final itemsByPlaylist = <String, List<CustomPlaylistItemRow>>{};
    for (final item in allItems) {
      (itemsByPlaylist[item.playlistId] ??= []).add(item);
    }

    final result = <MediaPlaylist>[];
    for (final row in rows) {
      final items = itemsByPlaylist[row.id] ?? const [];

      var durationMs = 0;
      String? firstThumb;
      for (final itemRow in items) {
        final decoded = _decodeMediaItem(itemRow.mediaJson);
        if (decoded != null) {
          durationMs += decoded.durationMs ?? 0;
          firstThumb ??= decoded.posterThumb();
        }
      }

      result.add(
        MediaPlaylist(
          id: row.id,
          backend: MediaBackend.plex,
          title: row.title,
          playlistType: row.playlistType,
          summary: row.summary,
          leafCount: items.length,
          durationMs: durationMs > 0 ? durationMs : null,
          thumbPath: row.thumbPath ?? firstThumb,
          addedAt: row.createdAt,
          updatedAt: row.updatedAt,
          isCustom: true,
        ),
      );
    }

    return result;
  }

  /// Retrieve a single custom playlist by ID as a [MediaPlaylist].
  Future<MediaPlaylist?> getCustomPlaylist(String playlistId) async {
    final row = await (select(customPlaylists)..where((t) => t.id.equals(playlistId))).getSingleOrNull();
    if (row == null) return null;

    final items =
        await (select(customPlaylistItems)
              ..where((t) => t.playlistId.equals(row.id))
              ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
            .get();

    var durationMs = 0;
    String? firstThumb;
    for (final itemRow in items) {
      final decoded = _decodeMediaItem(itemRow.mediaJson);
      if (decoded != null) {
        durationMs += decoded.durationMs ?? 0;
        firstThumb ??= decoded.posterThumb();
      }
    }

    return MediaPlaylist(
      id: row.id,
      backend: MediaBackend.plex,
      title: row.title,
      playlistType: row.playlistType,
      summary: row.summary,
      leafCount: items.length,
      durationMs: durationMs > 0 ? durationMs : null,
      thumbPath: row.thumbPath ?? firstThumb,
      addedAt: row.createdAt,
      updatedAt: row.updatedAt,
      isCustom: true,
    );
  }

  /// Retrieve all items for a custom playlist ordered by `sortOrder ASC`.
  /// Stamps each row's auto-increment `id` into `MediaItem.playlistItemId`
  /// so that playlist row keys stay globally unique.
  Future<List<MediaItem>> getCustomPlaylistItems(String playlistId) async {
    final rows =
        await (select(customPlaylistItems)
              ..where((t) => t.playlistId.equals(playlistId))
              ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
            .get();

    final items = <MediaItem>[];
    for (final row in rows) {
      final decoded = _decodeMediaItem(row.mediaJson);
      if (decoded != null) {
        items.add(_stampPlaylistItemId(decoded, row.id));
      }
    }

    return items;
  }

  /// Append items to the end of a custom playlist in a transaction.
  Future<void> addItemsToCustomPlaylist({required String playlistId, required List<MediaItem> items}) {
    if (items.isEmpty) return Future.value();
    return transaction(() async {
      final existingRows =
          await (select(customPlaylistItems)
                ..where((t) => t.playlistId.equals(playlistId))
                ..orderBy([(t) => OrderingTerm.desc(t.sortOrder)])
                ..limit(1))
              .get();

      final startOrder = existingRows.isNotEmpty ? existingRows.first.sortOrder + 1 : 0;
      final now = DateTime.now().millisecondsSinceEpoch;

      await batch((b) {
        for (var i = 0; i < items.length; i++) {
          final item = items[i];
          b.insert(
            customPlaylistItems,
            CustomPlaylistItemsCompanion.insert(
              playlistId: playlistId,
              sortOrder: startOrder + i,
              mediaJson: jsonEncode(item.toJson()),
              mediaGlobalKey: item.globalKey,
              addedAt: now,
            ),
          );
        }
      });

      await (update(
        customPlaylists,
      )..where((t) => t.id.equals(playlistId))).write(CustomPlaylistsCompanion(updatedAt: Value(now)));
    });
  }

  /// Remove a specific playlist item by its unique row ID and compact sortOrder.
  Future<void> removeCustomPlaylistItem({required String playlistId, required int customPlaylistItemId}) {
    return transaction(() async {
      await (delete(
        customPlaylistItems,
      )..where((t) => t.playlistId.equals(playlistId) & t.id.equals(customPlaylistItemId))).go();

      final remaining =
          await (select(customPlaylistItems)
                ..where((t) => t.playlistId.equals(playlistId))
                ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
              .get();

      await batch((b) {
        for (var i = 0; i < remaining.length; i++) {
          if (remaining[i].sortOrder != i) {
            b.update(
              customPlaylistItems,
              CustomPlaylistItemsCompanion(sortOrder: Value(i)),
              where: (t) => t.id.equals(remaining[i].id),
            );
          }
        }
      });

      final now = DateTime.now().millisecondsSinceEpoch;
      await (update(
        customPlaylists,
      )..where((t) => t.id.equals(playlistId))).write(CustomPlaylistsCompanion(updatedAt: Value(now)));
    });
  }

  /// Shift an item from [oldIndex] to [newIndex] within a playlist in an atomic transaction.
  Future<void> reorderCustomPlaylistItems({required String playlistId, required int oldIndex, required int newIndex}) {
    return transaction(() async {
      final rows =
          await (select(customPlaylistItems)
                ..where((t) => t.playlistId.equals(playlistId))
                ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
              .get();

      if (oldIndex < 0 || oldIndex >= rows.length || newIndex < 0 || newIndex >= rows.length) {
        return;
      }
      if (oldIndex == newIndex) return;

      final reordered = List<CustomPlaylistItemRow>.from(rows);
      final moved = reordered.removeAt(oldIndex);
      reordered.insert(newIndex, moved);

      await batch((b) {
        for (var i = 0; i < reordered.length; i++) {
          if (reordered[i].sortOrder != i) {
            b.update(
              customPlaylistItems,
              CustomPlaylistItemsCompanion(sortOrder: Value(i)),
              where: (t) => t.id.equals(reordered[i].id),
            );
          }
        }
      });

      final now = DateTime.now().millisecondsSinceEpoch;
      await (update(
        customPlaylists,
      )..where((t) => t.id.equals(playlistId))).write(CustomPlaylistsCompanion(updatedAt: Value(now)));
    });
  }

  /// Delete a custom playlist (cascades to all items).
  Future<void> deleteCustomPlaylist(String playlistId) {
    return transaction(() async {
      await (delete(customPlaylistItems)..where((t) => t.playlistId.equals(playlistId))).go();
      await (delete(customPlaylists)..where((t) => t.id.equals(playlistId))).go();
    });
  }

  /// Rename a custom playlist.
  Future<void> updateCustomPlaylistTitle({required String playlistId, required String title}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (update(customPlaylists)..where((t) => t.id.equals(playlistId))).write(
      CustomPlaylistsCompanion(title: Value(title), updatedAt: Value(now)),
    );
  }
}

MediaItem? _decodeMediaItem(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    return MediaItem.fromJson(Map<String, dynamic>.from(decoded));
  } catch (_) {
    return null;
  }
}

MediaItem _stampPlaylistItemId(MediaItem item, int rowId) => switch (item) {
  PlexMediaItem() => item.copyWith(playlistItemId: rowId),
  JellyfinMediaItem() => item.copyWith(playlistItemId: rowId.toString()),
};
