import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/utils/library_grouping.dart';

MediaLibrary _makeLib({
  required String id,
  required String title,
  required String serverId,
  required String serverName,
  required MediaBackend backend,
}) {
  return MediaLibrary(
    id: id,
    title: title,
    kind: MediaKind.movie,
    serverId: ServerId(serverId),
    serverName: serverName,
    backend: backend,
  );
}

class _FakeServerManager extends MultiServerManager {
  final Map<String, MediaBackend> backends;
  final Map<String, String> names;

  _FakeServerManager({this.backends = const {}, this.names = const {}});

  @override
  MediaBackend? serverBackend(ServerId serverId) => backends[serverId.value];

  @override
  String serverDisplayName(ServerId serverId) => names[serverId.value] ?? serverId.value;
}

void main() {
  group('groupLibrariesDeterministically', () {
    test('sorts by backend (plex -> jellyfin -> emby), then alphabetically by name', () {
      final libs = [
        _makeLib(
          id: '1',
          title: 'Movies',
          serverId: 'jf-1',
          serverName: 'Zeta Jellyfin',
          backend: MediaBackend.jellyfin,
        ),
        _makeLib(id: '2', title: 'Shows', serverId: 'plex-b', serverName: 'Beta Plex', backend: MediaBackend.plex),
        _makeLib(id: '3', title: 'Anime', serverId: 'emby-1', serverName: 'Alpha Emby', backend: MediaBackend.emby),
        _makeLib(
          id: '4',
          title: 'Home Videos',
          serverId: 'plex-a',
          serverName: 'alpha Plex',
          backend: MediaBackend.plex,
        ),
        _makeLib(
          id: '5',
          title: 'Docs',
          serverId: 'jf-2',
          serverName: 'Alpha Jellyfin',
          backend: MediaBackend.jellyfin,
        ),
      ];

      final result = groupLibrariesDeterministically(libs);

      // Order should be:
      // 1. plex-a ('alpha Plex')
      // 2. plex-b ('Beta Plex')
      // 3. jf-2 ('Alpha Jellyfin')
      // 4. jf-1 ('Zeta Jellyfin')
      // 5. emby-1 ('Alpha Emby')
      expect(result.serverOrder, equals(['plex-a', 'plex-b', 'jf-2', 'jf-1', 'emby-1']));
      expect(result.byServer['plex-a']!.length, equals(1));
      expect(result.byServer['plex-b']!.length, equals(1));
      expect(result.byServer['jf-2']!.length, equals(1));
      expect(result.byServer['jf-1']!.length, equals(1));
      expect(result.byServer['emby-1']!.length, equals(1));
    });

    test('places empty serverId first', () {
      final libs = [
        _makeLib(id: '1', title: 'Movies', serverId: 'plex-1', serverName: 'Plex Server', backend: MediaBackend.plex),
        MediaLibrary(id: '2', title: 'Local', kind: MediaKind.movie, backend: MediaBackend.plex),
      ];

      final result = groupLibrariesDeterministically(libs);
      expect(result.serverOrder, equals(['', 'plex-1']));
    });

    test('includes extraServerIds even when they have no libraries (offline servers)', () {
      final libs = [
        _makeLib(
          id: '1',
          title: 'Movies',
          serverId: 'plex-online',
          serverName: 'Plex Online',
          backend: MediaBackend.plex,
        ),
      ];

      final fakeManager = _FakeServerManager(
        backends: {
          'plex-online': MediaBackend.plex,
          'plex-offline': MediaBackend.plex,
          'jf-offline': MediaBackend.jellyfin,
        },
        names: {'plex-online': 'Plex Online', 'plex-offline': 'Alpha Offline Plex', 'jf-offline': 'Offline Jellyfin'},
      );

      final result = groupLibrariesDeterministically(
        libs,
        serverManager: fakeManager,
        extraServerIds: {'plex-offline', 'jf-offline'},
      );

      // Order:
      // 1. plex-offline ('Alpha Offline Plex')
      // 2. plex-online ('Plex Online')
      // 3. jf-offline ('Offline Jellyfin')
      expect(result.serverOrder, equals(['plex-offline', 'plex-online', 'jf-offline']));
      expect(result.byServer['plex-offline'], isEmpty);
      expect(result.byServer['jf-offline'], isEmpty);
      expect(result.byServer['plex-online']!.length, equals(1));
    });
  });
}
