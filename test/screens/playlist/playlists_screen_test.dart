import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/custom_playlist_operations.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/playlist/playlists_screen.dart';
import 'package:plezy/widgets/create_custom_playlist_dialog.dart';
import 'package:plezy/widgets/rename_custom_playlist_dialog.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';
import '../../test_helpers/profile_stack.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late MultiServerProvider multiServerProvider;
  late DownloadProvider downloadProvider;
  late PlaybackStateProvider playbackState;
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
    await profileStack.dispose();
    downloadProvider.dispose();
    multiServerProvider.dispose();
    playbackState.dispose();
    await db.close();
  });

  Widget buildSubject() {
    return TranslationProvider(
      child: MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: db),
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloadProvider),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: profileStack.active),
        ],
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: const PlaylistsScreen(),
        ),
      ),
    );
  }

  testWidgets('PlaylistsScreen renders empty state when no playlists exist', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final emptyManager = MultiServerManager();
    final emptyProvider = testMultiServerProvider(emptyManager);
    addTearDown(() {
      emptyProvider.dispose();
      emptyManager.dispose();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            Provider<AppDatabase>.value(value: db),
            ChangeNotifierProvider<MultiServerProvider>.value(value: emptyProvider),
            ChangeNotifierProvider<DownloadProvider>.value(value: downloadProvider),
            ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: profileStack.active),
          ],
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: const PlaylistsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.playlists.title), findsOneWidget);
    expect(find.text(t.playlists.noPlaylists), findsOneWidget);
  });

  testWidgets('PlaylistsScreen renders Custom Playlists and Server Playlists grouped by server', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    // Create a custom playlist in the database
    await db.createCustomPlaylist(
      profileId: profileStack.active.activeId ?? '',
      title: 'My Custom Mix',
      playlistType: 'video',
      initialItems: [testMediaItem(id: 'm1', title: 'Movie 1')],
    );

    // Provide a server playlist on fakeClient
    fakeClient.playlists = [
      const MediaPlaylist(
        id: 'server-pl-1',
        backend: MediaBackend.plex,
        title: 'Server Action Playlist',
        playlistType: 'video',
        leafCount: 5,
        serverId: 'fake-server',
        serverName: 'Main Plex Server',
      ),
    ];

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    // Verify Custom Playlists section
    expect(find.text(t.playlists.customPlaylists), findsOneWidget);
    expect(find.text('My Custom Mix'), findsOneWidget);

    // Verify Server Playlists section with server subheader
    expect(find.text(t.playlists.serverPlaylists), findsOneWidget);
    expect(find.text('Main Plex Server'), findsOneWidget);
    // Initially folded, server playlists are not fetched or shown yet
    expect(find.text('Server Action Playlist'), findsNothing);

    // Tap to unfold and fetch server playlists
    await tester.tap(find.text('Main Plex Server'));
    await tester.pumpAndSettle();

    expect(find.text('Server Action Playlist'), findsOneWidget);

    // Tap to fold again
    await tester.tap(find.text('Main Plex Server'));
    await tester.pumpAndSettle();
    expect(find.text('Server Action Playlist'), findsNothing);
  });

  testWidgets('PlaylistsScreen create custom playlist dialog allows selecting Audio type', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(buildSubject());
    await tester.pumpAndSettle();

    // Tap on the create button in the empty state
    await tester.tap(find.text(t.playlists.createCustomPlaylist).last);
    await tester.pumpAndSettle();

    // Verify dialog opened with name field and type selection
    expect(find.text(t.fileInfo.video), findsOneWidget);
    expect(find.text(t.fileInfo.audio), findsOneWidget);

    // Enter name
    await tester.enterText(find.byType(EditableText), 'My Audio Tracks');

    // Select Audio segment
    await tester.tap(find.text(t.fileInfo.audio));
    await tester.pumpAndSettle();

    // Submit dialog
    await tester.tap(find.text(t.playlists.create).last);
    await tester.pumpAndSettle();

    // Verify playlist was created with playlistType 'audio'
    final playlists = await db.getCustomPlaylists(profileId: profileStack.active.activeId ?? '');
    expect(playlists.length, 1);
    expect(playlists.first.title, 'My Audio Tracks');
    expect(playlists.first.playlistType, 'audio');
  });

  testWidgets('showCreateCustomPlaylistDialog hides type selector when allowTypeSelection is false', (tester) async {
    ({String name, String type})? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showCreateCustomPlaylistDialog(
                  context,
                  initialType: 'audio',
                  allowTypeSelection: false,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text(t.fileInfo.video), findsNothing);
    expect(find.text(t.fileInfo.audio), findsNothing);

    await tester.enterText(find.byType(EditableText), 'Direct Audio List');
    await tester.tap(find.text(t.playlists.create));
    await tester.pumpAndSettle();

    expect(result?.name, 'Direct Audio List');
    expect(result?.type, 'audio');
  });

  testWidgets('showRenameCustomPlaylistDialog prompts for new title and saves', (tester) async {
    String? newTitle;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                newTitle = await showRenameCustomPlaylistDialog(
                  context,
                  currentTitle: 'Original Name',
                );
              },
              child: const Text('Rename'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(find.text(t.playlists.rename), findsOneWidget);
    expect(find.text('Original Name'), findsOneWidget);

    await tester.enterText(find.byType(EditableText), 'Renamed Mix');
    await tester.tap(find.text(t.common.save));
    await tester.pumpAndSettle();

    expect(newTitle, 'Renamed Mix');
  });
}

class _FakeServerClient implements MediaServerClient {
  @override
  final MediaBackend backend = MediaBackend.plex;

  @override
  final ServerId serverId = ServerId('fake-server');

  @override
  final String serverName = 'Main Plex Server';

  List<MediaPlaylist> playlists = [];

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    return LibraryPage(items: playlists, totalCount: playlists.length);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
