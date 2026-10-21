import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/custom_playlist_operations.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/play_queue.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/libraries/tabs/library_playlists_tab.dart';
import 'package:plezy/screens/media_detail_screen.dart';
import 'package:plezy/screens/playlist/playlist_detail_screen.dart';
import 'package:plezy/screens/playlist/playlist_item_card.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/widgets/collection_picker_dialog.dart';
import 'package:plezy/widgets/media_context_menu.dart';
import 'package:plezy/widgets/video_controls/sheets/queue_sheet.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/profile_navigation.dart';
import '../test_helpers/profile_stack.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late MultiServerProvider multiServerProvider;
  late DownloadProvider downloadProvider;
  late PlaybackStateProvider playbackState;
  late OfflineWatchSyncService offlineWatch;
  late ProfileStack profileStack;
  late _FakeServerClient fakeClient;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);

    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    JellyfinApiCache.initialize(db);
    fakeClient = _FakeServerClient();
    final manager = MultiServerManager()..debugRegisterClientForTesting(fakeClient);
    multiServerProvider = testMultiServerProvider(manager);
    offlineWatch = OfflineWatchSyncService(database: db, serverManager: manager);

    final downloadManager = DownloadManagerService(
      database: db,
      storageService: DownloadStorageService.instance,
      clientResolver: (serverId, {clientScopeId}) => null,
    );
    downloadManager.recoveryFuture = Future<void>.value();
    downloadProvider = DownloadProvider.forTesting(downloadManager: downloadManager, database: db);
    await downloadProvider.ensureInitialized();

    playbackState = PlaybackStateProvider();
    profileStack = await ProfileStack.create(db: db, withStorage: false);
  });

  tearDown(() async {
    offlineWatch.dispose();
    await profileStack.dispose();
    downloadProvider.dispose();
    multiServerProvider.dispose();
    playbackState.dispose();
    await db.close();
  });

  Widget wrapWithProviders(Widget child) {
    return TranslationProvider(
      child: MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: db),
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
          ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloadProvider),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: profileStack.active),
        ],
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          builder: (context, child) => withProfileNavigationScope(child: child ?? const SizedBox()),
          home: Scaffold(body: child),
        ),
      ),
    );
  }

  testWidgets('E2E: PlaylistSelectionDialog renders Custom and Server sections and filters both', (tester) async {
    // Seed one custom playlist in SQLite
    await db.createCustomPlaylist(
      profileId: profileStack.active.activeId ?? '',
      title: 'Action Movie Marathon',
      playlistType: 'video',
    );

    // Seed server playlists in fake client
    fakeClient.serverPlaylists = [
      const MediaPlaylist(
        id: 'server_pl_1',
        backend: MediaBackend.plex,
        title: 'Server Comedy',
        playlistType: 'video',
        serverId: 'server_1',
      ),
    ];

    String? selectedResult;

    await tester.pumpWidget(
      wrapWithProviders(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selectedResult = await showDialog<String>(
                context: context,
                builder: (_) => PlaylistSelectionDialog(
                  client: fakeClient,
                  item: testMediaItem(id: 'item_1', title: 'New Movie'),
                ),
              );
            },
            child: const Text('Open Picker'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Picker'));
    await tester.pumpAndSettle();

    // Verify dialog title and sections
    expect(find.text(t.playlists.selectPlaylist), findsOneWidget);
    expect(find.text(t.playlists.customPlaylists), findsOneWidget);
    expect(find.text(t.playlists.createCustomPlaylist), findsOneWidget);
    expect(find.text('Action Movie Marathon'), findsOneWidget);

    expect(find.text(t.playlists.serverPlaylists), findsOneWidget);
    expect(find.text(t.playlists.createServerPlaylist), findsOneWidget);
    expect(find.text('Server Comedy'), findsOneWidget);

    // Tap on the custom playlist
    await tester.tap(find.text('Action Movie Marathon'));
    await tester.pumpAndSettle();

    // Verify selection returned the custom prefix
    expect(selectedResult, startsWith('custom:'));
  });

  testWidgets('E2E: PlaylistSelectionDialog functions offline when client is null', (tester) async {
    await db.createCustomPlaylist(
      profileId: profileStack.active.activeId ?? '',
      title: 'Offline Custom Playlist',
      playlistType: 'video',
    );

    await tester.pumpWidget(
      wrapWithProviders(
        PlaylistSelectionDialog(
          client: null, // offline
          item: testMediaItem(id: 'item_offline', title: 'Offline Item'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Custom section is present
    expect(find.text(t.playlists.customPlaylists), findsOneWidget);
    expect(find.text(t.playlists.createCustomPlaylist), findsOneWidget);
    expect(find.text('Offline Custom Playlist'), findsOneWidget);

    // Server section is gracefully omitted
    expect(find.text(t.playlists.serverPlaylists), findsNothing);
    expect(find.text(t.playlists.createServerPlaylist), findsNothing);
  });

  testWidgets('E2E: Custom playlist detail screen renders cross-server items, reorders, removes and deletes', (
    tester,
  ) async {
    final plexMovie = testMediaItem(
      id: 'plex_movie_1',
      serverId: 'server_plex',
      backend: MediaBackend.plex,
      title: 'Inception (Plex)',
      durationMs: 8880000,
    );
    final jfMovie = testMediaItem(
      id: 'jf_movie_1',
      serverId: 'server_jf',
      backend: MediaBackend.jellyfin,
      title: 'Interstellar (Jellyfin)',
      durationMs: 10140000,
    );

    final createdRow = await db.createCustomPlaylist(
      profileId: profileStack.active.activeId ?? '',
      title: 'Sci-Fi Cross-Server',
      playlistType: 'video',
      initialItems: [plexMovie, jfMovie],
    );

    final customPlaylist = (await db.getCustomPlaylist(createdRow.id))!;
    expect(customPlaylist.isCustom, isTrue);

    bool? routePoppedResult;

    await tester.pumpWidget(
      wrapWithProviders(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              routePoppedResult = await Navigator.of(
                context,
              ).push<bool>(MaterialPageRoute(builder: (_) => PlaylistDetailScreen(playlist: customPlaylist)));
            },
            child: const Text('Open Detail'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Detail'));
    await tester.pumpAndSettle();

    // 1. Verify screen rendered both items from different servers without mediaClient errors
    expect(find.text('Sci-Fi Cross-Server'), findsWidgets);
    expect(find.text('Inception (Plex)'), findsOneWidget);
    expect(find.text('Interstellar (Jellyfin)'), findsOneWidget);

    // Verify app bar actions: Play, Shuffle, Delete (no sync rule action)
    expect(find.byTooltip(t.common.play), findsOneWidget);
    expect(find.byTooltip(t.common.shuffle), findsOneWidget);
    expect(find.byTooltip(t.playlists.delete), findsOneWidget);

    // 2. Test reordering items via drag
    final firstCard = tester.getRect(find.byType(PlaylistItemCard).first);
    final secondCard = tester.getRect(find.byType(PlaylistItemCard).at(1));
    await tester.timedDrag(
      find.byType(ReorderableDragStartListener).first,
      Offset(0, secondCard.top - firstCard.top),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();

    // Verify order in SQLite has been reversed
    final reorderedItems = await db.getCustomPlaylistItems(customPlaylist.id);
    expect(reorderedItems[0].id, 'jf_movie_1');
    expect(reorderedItems[1].id, 'plex_movie_1');

    // 3. Test item removal
    // Tap the remove button on the first card
    final removeButton = find.descendant(
      of: find.byType(PlaylistItemCard).first,
      matching: find.byTooltip(t.playlists.removeItem),
    );
    await tester.tap(removeButton);
    await tester.pumpAndSettle();

    // Verify one item remains in the UI and SQLite
    expect(find.byType(PlaylistItemCard), findsOneWidget);
    final remainingDbItems = await db.getCustomPlaylistItems(customPlaylist.id);
    expect(remainingDbItems, hasLength(1));
    expect(remainingDbItems.single.id, 'plex_movie_1');

    // 4. Test playlist deletion with confirmation
    await tester.tap(find.byTooltip(t.playlists.delete));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(t.playlists.deleteConfirm), findsOneWidget);

    // Tap Confirm delete
    await tester.tap(find.text(t.common.delete));
    await tester.pumpAndSettle();

    // Route popped with true
    expect(routePoppedResult, isTrue);
    expect(find.byType(PlaylistDetailScreen), findsNothing);

    // Playlist is deleted from SQLite
    final finalPlaylists = await db.getCustomPlaylists(profileId: profileStack.active.activeId ?? '');
    expect(finalPlaylists, isEmpty);
  });

  testWidgets('E2E: LibraryPlaylistsTab displays custom playlists prepended to server playlists', (tester) async {
    // Seed one custom playlist in SQLite
    await db.createCustomPlaylist(
      profileId: profileStack.active.activeId ?? '',
      title: 'My Custom List',
      playlistType: 'video',
      initialItems: [testMediaItem(id: 'm1', title: 'Movie 1')],
    );

    // Seed server playlists in fake client
    fakeClient.serverPlaylists = [
      const MediaPlaylist(
        id: 'srv_pl_1',
        backend: MediaBackend.plex,
        title: 'Server List 1',
        playlistType: 'video',
        serverId: 'server_1',
      ),
    ];

    const library = MediaLibrary(
      id: 'lib_1',
      serverId: 'server_1',
      title: 'Movies',
      kind: MediaKind.movie,
      backend: MediaBackend.plex,
    );

    await tester.pumpWidget(
      wrapWithProviders(
        SizedBox(
          width: 1280,
          height: 720,
          child: Scaffold(
            body: NestedScrollView(
              headerSliverBuilder: (context, _) => [
                SliverOverlapAbsorber(
                  handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
                  sliver: const SliverToBoxAdapter(child: SizedBox(height: 1)),
                ),
              ],
              body: const LibraryPlaylistsTab(library: library, isActive: true),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify custom playlist is rendered
    expect(find.text('My Custom List'), findsOneWidget);
    expect(find.text('Server List 1'), findsOneWidget);

    // Verify badge text "Custom • 1 items" on the custom card
    expect(find.textContaining('${t.playlists.customBadge} •'), findsOneWidget);
  });

  testWidgets('E2E: Custom playlist detail screen tapping a show item launches its episodes', (tester) async {
    final show = testMediaItem(
      id: 'show_1',
      title: 'Breaking Bad',
      kind: MediaKind.show,
      serverId: 'server_1',
      serverName: 'Server 1',
    );
    final ep1 = testMediaItem(
      id: 'ep_1',
      title: 'Pilot',
      kind: MediaKind.episode,
      grandparentId: 'show_1',
      serverId: 'server_1',
      serverName: 'Server 1',
    );
    final ep2 = testMediaItem(
      id: 'ep_2',
      title: "Cat's in the Bag...",
      kind: MediaKind.episode,
      grandparentId: 'show_1',
      serverId: 'server_1',
      serverName: 'Server 1',
    );

    fakeClient.playableDescendants['show_1'] = [ep1, ep2];

    final created = await db.createCustomPlaylist(
      profileId: profileStack.active.activeId ?? '',
      title: 'TV Series List',
      initialItems: [show],
    );
    final playlist = (await db.getCustomPlaylist(created.id))!;

    await tester.pumpWidget(
      wrapWithProviders(
        SizedBox(
          width: 1280,
          height: 720,
          child: PlaylistDetailScreen(playlist: playlist),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify the show item card is rendered
    expect(find.text('Breaking Bad'), findsOneWidget);

    // Tap on the show row - opens MediaDetailScreen instead of error/direct video play
    await tester.tap(find.text('Breaking Bad'));
    await tester.pumpAndSettle();

    expect(find.byType(MediaDetailScreen), findsOneWidget);

    // Pop back to playlist detail screen
    Navigator.of(tester.element(find.byType(MediaDetailScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistDetailScreen), findsOneWidget);

    // Tap Play button in App Bar - this launches the playlist and expands episodes
    await tester.tap(find.byTooltip(t.common.play));
    await tester.pumpAndSettle();

    // Verify playback state launched with the expanded episodes, starting at ep1
    expect(playbackState.isQueueActive, isTrue);
    expect(playbackState.loadedItems, hasLength(2));
    expect(playbackState.loadedItems[0].id, 'ep_1');
    expect(playbackState.loadedItems[1].id, 'ep_2');
    expect(playbackState.currentPlayQueueItemID, 0);
    tester.takeException(); // Consume layout overflow from mock video player UI
  });

  testWidgets('E2E: Video player QueueSheet provides add-to-playlist action', (tester) async {
    final movie = testMediaItem(
      id: 'movie_player_1',
      title: 'Playing Movie',
      serverId: 'server_1',
      serverName: 'Server 1',
    );

    playbackState.setPlaybackFromLocalQueue(LocalPlayQueue(items: [movie], currentIndex: 0));

    await tester.pumpWidget(
      wrapWithProviders(
        QueueSheet(onItemSelected: (_) {}),
      ),
    );
    await tester.pumpAndSettle();

    // Verify add to playlist icon button is rendered in QueueSheet
    expect(find.byIcon(Symbols.playlist_add_rounded), findsOneWidget);
  });

  testWidgets('E2E: Adding a show expands all its episodes into custom playlist', (tester) async {
    final show = testMediaItem(
      id: 'show_2',
      title: 'Better Call Saul',
      kind: MediaKind.show,
      serverId: 'server_1',
      serverName: 'Server 1',
    );
    final ep1 = testMediaItem(
      id: 'bcs_1',
      title: 'Uno',
      kind: MediaKind.episode,
      grandparentId: 'show_2',
      serverId: 'server_1',
      serverName: 'Server 1',
    );
    final ep2 = testMediaItem(
      id: 'bcs_2',
      title: 'Mijo',
      kind: MediaKind.episode,
      grandparentId: 'show_2',
      serverId: 'server_1',
      serverName: 'Server 1',
    );
    fakeClient.playableDescendants['show_2'] = [ep1, ep2];

    final created = await db.createCustomPlaylist(
      profileId: profileStack.active.activeId ?? '',
      title: 'Saul Playlist',
      playlistType: 'video',
    );

    final menuKey = GlobalKey<MediaContextMenuState>();
    await tester.pumpWidget(
      wrapWithProviders(
        MediaContextMenu(
          key: menuKey,
          item: show,
          child: const Text('Show Target'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Open context menu
    menuKey.currentState!.showContextMenu(tester.element(find.text('Show Target')));
    await tester.pumpAndSettle();

    // Tap "Add to..."
    expect(find.text(t.common.addTo), findsOneWidget);
    await tester.tap(find.text(t.common.addTo));
    await tester.pumpAndSettle();

    // If "Playlist" / "Collection" sub-options are presented, pick "Playlist"
    if (find.text(t.playlists.playlist).evaluate().isNotEmpty) {
      await tester.tap(find.text(t.playlists.playlist));
      await tester.pumpAndSettle();
    }

    // Tap "Saul Playlist" in PlaylistSelectionDialog
    expect(find.text('Saul Playlist'), findsOneWidget);
    await tester.tap(find.text('Saul Playlist'));
    await tester.pumpAndSettle();

    // Verify both episodes were expanded and added to SQLite customPlaylistItems
    final itemsInDb = await db.getCustomPlaylistItems(created.id);
    expect(itemsInDb, hasLength(2));
    expect(itemsInDb[0].id, 'bcs_1');
    expect(itemsInDb[0].title, 'Uno');
    expect(itemsInDb[1].id, 'bcs_2');
    expect(itemsInDb[1].title, 'Mijo');
  });
}

class _FakeServerClient implements MediaServerClient {
  List<MediaPlaylist> serverPlaylists = [];
  Map<String, List<MediaItem>> playableDescendants = {};

  @override
  final ServerId serverId = ServerId('server_1');

  @override
  final MediaBackend backend = MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => const ServerCapabilities();

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId, {AbortController? abort}) async {
    return playableDescendants[parentId] ?? const [];
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId, {AbortController? abort}) async {
    return const [];
  }

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String? playlistType,
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    return LibraryPage(items: serverPlaylists, totalCount: serverPlaylists.length);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
