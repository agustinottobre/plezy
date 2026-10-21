import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/custom_playlist_operations.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_playlist.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/custom_playlist_launcher.dart';
import 'package:plezy/services/media_list_playback_launcher.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';

void main() {
  late AppDatabase db;
  late PlaybackStateProvider playbackState;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    playbackState = PlaybackStateProvider();
  });

  tearDown(() async {
    await db.close();
  });

  Widget buildTestContext(Widget child) {
    return MultiProvider(
      providers: [
        Provider<AppDatabase>.value(value: db),
        ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  testWidgets('MediaListPlaybackLauncher.forItem dispatches to CustomPlaylistLauncher for custom playlists', (
    tester,
  ) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(
      buildTestContext(
        Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox();
          },
        ),
      ),
    );

    const customPlaylist = MediaPlaylist(
      id: 'custom-1',
      backend: MediaBackend.plex,
      title: 'Custom Test',
      playlistType: 'video',
      isCustom: true,
    );

    final launcher = MediaListPlaybackLauncher.forItem(capturedContext, customPlaylist);
    expect(launcher, isA<CustomPlaylistLauncher>());
  });

  testWidgets('CustomPlaylistLauncher returns PlayQueueEmpty when custom playlist is empty', (tester) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(
      buildTestContext(
        Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox();
          },
        ),
      ),
    );

    final pl = await db.createCustomPlaylist(profileId: 'p1', title: 'Empty Playlist');
    final mediaPlaylist = (await db.getCustomPlaylist(pl.id))!;

    final launcher = CustomPlaylistLauncher(context: capturedContext, navigateForTesting: (_) async {});
    final result = await launcher.launchFromCollectionOrPlaylist(item: mediaPlaylist, shuffle: false);

    expect(result, isA<PlayQueueEmpty>());
    expect(playbackState.isQueueActive, isFalse);
  });

  testWidgets('CustomPlaylistLauncher builds and publishes LocalPlayQueue with items and startItem', (tester) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(
      buildTestContext(
        Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox();
          },
        ),
      ),
    );

    final item1 = testMediaItem(id: 'i1', title: 'First Movie');
    final item2 = testMediaItem(id: 'i2', title: 'Second Movie');
    final item3 = testMediaItem(id: 'i3', title: 'Third Movie');

    final pl = await db.createCustomPlaylist(profileId: 'p1', title: 'Queue Test', initialItems: [item1, item2, item3]);
    final mediaPlaylist = (await db.getCustomPlaylist(pl.id))!;

    final launcher = CustomPlaylistLauncher(context: capturedContext, navigateForTesting: (_) async {});
    final result = await launcher.launchFromCollectionOrPlaylist(item: mediaPlaylist, shuffle: false, startItem: item2);

    expect(result, isA<PlayQueueSuccess>());
    expect(playbackState.isQueueActive, isTrue);
    expect(playbackState.loadedItems, hasLength(3));
    expect(playbackState.loadedItems[0].id, 'i1');
    expect(playbackState.loadedItems[1].id, 'i2');
    expect(playbackState.loadedItems[2].id, 'i3');
    expect(playbackState.currentPlayQueueItemID, 1); // started at item2 (index 1)
    expect(playbackState.isShuffleActive, isFalse);
    expect(playbackState.shuffleContextKey, pl.id);
  });

  testWidgets('CustomPlaylistLauncher shuffles items when shuffle is true', (tester) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(
      buildTestContext(
        Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox();
          },
        ),
      ),
    );

    final items = List.generate(20, (i) => testMediaItem(id: 'item-$i', title: 'Movie $i'));
    final pl = await db.createCustomPlaylist(profileId: 'p1', title: 'Shuffle Test', initialItems: items);
    final mediaPlaylist = (await db.getCustomPlaylist(pl.id))!;

    final launcher = CustomPlaylistLauncher(context: capturedContext, navigateForTesting: (_) async {});
    final result = await launcher.launchFromCollectionOrPlaylist(item: mediaPlaylist, shuffle: true);

    expect(result, isA<PlayQueueSuccess>());
    expect(playbackState.isQueueActive, isTrue);
    expect(playbackState.loadedItems, hasLength(20));
    expect(playbackState.isShuffleActive, isTrue);
    expect(playbackState.currentPlayQueueItemID, 0);
  });

  testWidgets('CustomPlaylistLauncher plays audio playlist via audio playback pathway', (tester) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(
      buildTestContext(
        Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox();
          },
        ),
      ),
    );

    final track1 = testMediaItem(id: 't1', title: 'Song 1', kind: MediaKind.track);
    final track2 = testMediaItem(id: 't2', title: 'Song 2', kind: MediaKind.track);

    final pl = await db.createCustomPlaylist(
      profileId: 'p1',
      title: 'Audio Mix',
      playlistType: 'audio',
      initialItems: [track1, track2],
    );
    final mediaPlaylist = (await db.getCustomPlaylist(pl.id))!;

    MediaItem? playedItem;
    final launcher = CustomPlaylistLauncher(
      context: capturedContext,
      navigateForTesting: (target) async {
        playedItem = target;
      },
    );
    final result = await launcher.launchFromCollectionOrPlaylist(item: mediaPlaylist, shuffle: false, startItem: track2);

    expect(result, isA<PlayQueueSuccess>());
    expect(playedItem?.id, 't2');
    expect(playbackState.isQueueActive, isFalse);
  });

  testWidgets('CustomPlaylistLauncher returns PlayQueueEmpty when video playlist only contains unplayable show/season containers without client', (tester) async {
    late BuildContext capturedContext;
    await tester.pumpWidget(
      buildTestContext(
        Builder(
          builder: (context) {
            capturedContext = context;
            return const SizedBox();
          },
        ),
      ),
    );

    final showItem = testMediaItem(id: 's1', title: 'Test Show', kind: MediaKind.show);
    final pl = await db.createCustomPlaylist(
      profileId: 'p1',
      title: 'Shows Only',
      initialItems: [showItem],
    );
    final mediaPlaylist = (await db.getCustomPlaylist(pl.id))!;

    final launcher = CustomPlaylistLauncher(context: capturedContext, navigateForTesting: (_) async {});
    final result = await launcher.launchFromCollectionOrPlaylist(item: mediaPlaylist, shuffle: false);

    expect(result, isA<PlayQueueEmpty>());
    expect(playbackState.isQueueActive, isFalse);
  });

  testWidgets('CustomPlaylistLauncher expands show item into episodes when multiServer client is available and targets first episode on startItem', (tester) async {
    final showItem = testMediaItem(id: 's1', title: 'Test Show', kind: MediaKind.show, serverId: 'server_1');
    final ep1 = testMediaItem(id: 'ep1', title: 'Ep 1', kind: MediaKind.episode, grandparentId: 's1', serverId: 'server_1');
    final ep2 = testMediaItem(id: 'ep2', title: 'Ep 2', kind: MediaKind.episode, grandparentId: 's1', serverId: 'server_1');

    final fakeClient = _FakeExpansionClient({'s1': [ep1, ep2]});
    final multiServer = testMultiServer(clients: [fakeClient]);

    late BuildContext capturedContext;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: db),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer.provider),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );

    final pl = await db.createCustomPlaylist(profileId: 'p1', title: 'Show Expansion', initialItems: [showItem]);
    final mediaPlaylist = (await db.getCustomPlaylist(pl.id))!;

    final launcher = CustomPlaylistLauncher(context: capturedContext, navigateForTesting: (_) async {});
    final result = await launcher.launchFromCollectionOrPlaylist(item: mediaPlaylist, shuffle: false, startItem: showItem);

    expect(result, isA<PlayQueueSuccess>());
    expect(playbackState.isQueueActive, isTrue);
    expect(playbackState.loadedItems, hasLength(2));
    expect(playbackState.loadedItems[0].id, 'ep1');
    expect(playbackState.loadedItems[1].id, 'ep2');
    expect(playbackState.currentPlayQueueItemID, 0);
  });
}

class _FakeExpansionClient implements MediaServerClient {
  final Map<String, List<MediaItem>> descendants;

  _FakeExpansionClient(this.descendants);

  @override
  ServerId get serverId => ServerId('server_1');

  @override
  String get serverName => 'Server 1';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId, {AbortController? abort}) async {
    return descendants[parentId] ?? const [];
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
