import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../database/app_database.dart';
import '../../../database/custom_playlist_operations.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/library_query.dart';
import '../../../media/media_playlist.dart';
import '../../../profiles/active_profile_provider.dart';
import '../../../utils/library_refresh_notifier.dart';
import '../../../utils/media_server_http_client.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/create_custom_playlist_dialog.dart';
import 'base_library_tab.dart';
import 'paginated_card_grid_tab.dart';

/// Playlists tab for library screen
/// Shows playlists that contain items from the current library
class LibraryPlaylistsTab extends BaseLibraryTab<MediaPlaylist> {
  const LibraryPlaylistsTab({
    super.key,
    required super.library,
    super.viewMode,
    super.density,
    super.onDataLoaded,
    super.isActive,
    super.suppressAutoFocus,
    super.onBack,
  });

  @override
  State<LibraryPlaylistsTab> createState() => _LibraryPlaylistsTabState();
}

class _LibraryPlaylistsTabState extends PaginatedCardGridTabState<MediaPlaylist, LibraryPlaylistsTab> {
  @override
  int get pageSize => 200;

  @override
  String get focusNodeDebugLabel => 'playlists_first_item';

  @override
  IconData get emptyIcon => Symbols.playlist_play_rounded;

  @override
  String get emptyMessage => t.playlists.noPlaylists;

  @override
  String? get emptyActionLabel => t.playlists.createCustomPlaylist;

  @override
  IconData? get emptyActionIcon => Symbols.add_rounded;

  @override
  VoidCallback? get onEmptyAction => _createCustomPlaylist;

  @override
  String get errorContext => t.playlists.title;

  @override
  Stream<void>? getRefreshStream() => LibraryRefreshNotifier().playlistsStream;

  @override
  String idOf(MediaPlaylist playlist) => playlist.id;

  String get _playlistType => widget.library.kind.isMusic ? 'audio' : 'video';

  Future<void> _createCustomPlaylist() async {
    final result = await showCreateCustomPlaylistDialog(
      context,
      initialType: _playlistType,
      allowTypeSelection: false,
    );
    if (result == null || !mounted) return;

    final profileId = context.read<ActiveProfileProvider?>()?.activeId ?? '';
    final db = context.read<AppDatabase?>();
    if (db == null) return;
    await db.createCustomPlaylist(profileId: profileId, title: result.name, playlistType: result.type);
    if (!mounted) return;
    showSuccessSnackBar(context, t.playlists.created);
    LibraryRefreshNotifier().notifyPlaylistsChanged();
  }

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPage(int start, int size, AbortController? abort) async {
    // Both backends return playlists scoped to the server (not the library) —
    // neither Plex nor Jellyfin's API filters playlists by section. Music
    // libraries surface audio playlists; everything else keeps video.
    final client = getMediaClientForLibrary();
    final playlistType = _playlistType;

    final profileId = context.read<ActiveProfileProvider?>()?.activeId ?? '';
    final db = context.read<AppDatabase?>();
    final customPlaylists = db != null
        ? await db.getCustomPlaylists(profileId: profileId, playlistType: playlistType)
        : <MediaPlaylist>[];
    final customCount = customPlaylists.length;

    // Determine how many custom items fall into [start, start + size)
    final customItemsInPage = (start < customCount)
        ? customPlaylists.sublist(start, math.min(start + size, customCount))
        : <MediaPlaylist>[];

    // Determine server offset and remaining size needed
    final serverStart = math.max(0, start - customCount);
    final serverNeeded = size - customItemsInPage.length;

    List<MediaPlaylist> serverItems = [];
    int serverTotal = 0;
    if (serverNeeded > 0) {
      try {
        final serverPage = await client.fetchPlaylistsPage(
          playlistType: playlistType,
          start: serverStart,
          size: serverNeeded,
          abort: abort,
        );
        serverItems = serverPage.items;
        serverTotal = serverPage.totalCount;
      } catch (e) {
        if (customCount == 0 || start > 0) rethrow;
        // If start == 0 and server failed, still return custom items with serverTotal = 0
      }
    }

    return LibraryPage(items: [...customItemsInPage, ...serverItems], totalCount: customCount + serverTotal);
  }

  @override
  bool get usesSquareCards => widget.library.kind.isMusic;
}
