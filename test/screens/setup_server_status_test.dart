import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/main.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/widgets/app_icon.dart';

void main() {
  group('buildStartupServerStatusList', () {
    testWidgets('sorts servers by backend (plex -> jellyfin -> emby), then alphabetically by name', (tester) async {
      final servers = <String, StartupServerEntry>{
        'jf-2': StartupServerEntry(
          serverId: 'jf-2',
          name: 'Zeta Jellyfin',
          backend: MediaBackend.jellyfin,
          connected: true,
        ),
        'plex-2': StartupServerEntry(
          serverId: 'plex-2',
          name: 'Beta Plex',
          backend: MediaBackend.plex,
          connected: true,
        ),
        'emby-1': StartupServerEntry(
          serverId: 'emby-1',
          name: 'Alpha Emby',
          backend: MediaBackend.emby,
          connected: false,
        ),
        'plex-1': StartupServerEntry(
          serverId: 'plex-1',
          name: 'Alpha Plex',
          backend: MediaBackend.plex,
          connected: null,
        ),
        'jf-1': StartupServerEntry(
          serverId: 'jf-1',
          name: 'Alpha Jellyfin',
          backend: MediaBackend.jellyfin,
          connected: true,
        ),
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Builder(builder: (context) => buildStartupServerStatusList(context, servers))),
        ),
      );

      // Backend headers with counts should be visible because multiple backends exist
      expect(find.text('Plex (2)'), findsOneWidget);
      expect(find.text('Jellyfin (2)'), findsOneWidget);
      expect(find.text('Emby (1)'), findsOneWidget);

      // Verify the rendered order of server cards:
      // Plex: Alpha Plex, Beta Plex
      // Jellyfin: Alpha Jellyfin, Zeta Jellyfin
      // Emby: Alpha Emby
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data)
          .where((t) => t != null && !t.contains('('))
          .toList();

      expect(texts, equals(['Alpha Plex', 'Beta Plex', 'Alpha Jellyfin', 'Zeta Jellyfin', 'Alpha Emby']));
    });

    testWidgets('omits backend headers when only one backend is present', (tester) async {
      final servers = <String, StartupServerEntry>{
        'plex-2': StartupServerEntry(
          serverId: 'plex-2',
          name: 'Beta Plex',
          backend: MediaBackend.plex,
          connected: true,
        ),
        'plex-1': StartupServerEntry(
          serverId: 'plex-1',
          name: 'Alpha Plex',
          backend: MediaBackend.plex,
          connected: true,
        ),
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Builder(builder: (context) => buildStartupServerStatusList(context, servers))),
        ),
      );

      // No header like 'Plex (2)'
      expect(find.text('Plex (2)'), findsNothing);
      // Alphabetical order
      final texts = tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).toList();
      expect(texts, equals(['Alpha Plex', 'Beta Plex']));
    });

    testWidgets('renders status icons for pending, online, and offline states', (tester) async {
      final servers = <String, StartupServerEntry>{
        'pending': StartupServerEntry(
          serverId: 'pending',
          name: 'Pending Server',
          backend: MediaBackend.plex,
          connected: null,
        ),
        'online': StartupServerEntry(
          serverId: 'online',
          name: 'Online Server',
          backend: MediaBackend.plex,
          connected: true,
        ),
        'offline': StartupServerEntry(
          serverId: 'offline',
          name: 'Offline Server',
          backend: MediaBackend.plex,
          connected: false,
        ),
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Builder(builder: (context) => buildStartupServerStatusList(context, servers))),
        ),
      );

      final icons = tester.widgetList<AppIcon>(find.byType(AppIcon)).map((i) => i.icon).toList();
      expect(icons, contains(Symbols.circle_rounded));
      expect(icons, contains(Symbols.check_circle_rounded));
      expect(icons, contains(Symbols.cancel_rounded));
    });

    testWidgets('renders a large number of servers cleanly in Wrap without overflow', (tester) async {
      final servers = <String, StartupServerEntry>{};
      for (var i = 0; i < 24; i++) {
        servers['s-$i'] = StartupServerEntry(
          serverId: 's-$i',
          name: 'Server ${i.toString().padLeft(2, '0')}',
          backend: i % 2 == 0 ? MediaBackend.plex : MediaBackend.jellyfin,
          connected: i % 3 == 0 ? false : true,
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Builder(builder: (context) => buildStartupServerStatusList(context, servers)),
            ),
          ),
        ),
      );

      // All 24 servers should be rendered
      for (var i = 0; i < 24; i++) {
        expect(find.text('Server ${i.toString().padLeft(2, '0')}'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  });
}
