import 'dart:async';
import 'dart:io';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/custom_playlist_operations.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/services/device_transfer_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/utils/device_identity.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  DeviceIdentityService.debugOverride(const DeviceIdentity(platform: 'macOS', deviceName: 'Test Machine'));

  group('DeviceTransferService crypto', () {
    test('generatePin produces 6 digit numeric strings', () {
      for (int i = 0; i < 20; i++) {
        final pin = DeviceTransferService.generatePin();
        expect(pin.length, 6);
        expect(int.tryParse(pin), isNotNull);
        expect(int.parse(pin), inInclusiveRange(100000, 999999));
      }
    });

    test('generateSalt produces 16 byte random salts', () {
      final s1 = DeviceTransferService.generateSalt();
      final s2 = DeviceTransferService.generateSalt();
      expect(s1.length, 16);
      expect(s2.length, 16);
      expect(s1, isNot(equals(s2)));
    });

    test('deriveKey + encryptPayload + decryptPayload works with matching PIN', () async {
      const pin = '482915';
      final salt = DeviceTransferService.generateSalt();

      final key1 = await DeviceTransferService.deriveKey(pin, salt);
      final key2 = await DeviceTransferService.deriveKey(pin, salt);

      final payload = {
        'formatVersion': 1,
        'appVersion': '1.0.0',
        'settings': {'theme': 'dark'},
        'connections': [
          {'id': 'plex-1', 'kind': 'plex'},
        ],
      };

      final encrypted = await DeviceTransferService.encryptPayload(payload, key1);
      expect(encrypted['nonce'], isNotNull);
      expect(encrypted['ciphertext'], isNotNull);
      expect(encrypted['mac'], isNotNull);

      final decrypted = await DeviceTransferService.decryptPayload(encrypted, key2);
      expect(decrypted, equals(payload));
    });

    test('decryptPayload throws on wrong PIN', () async {
      const correctPin = '482915';
      const wrongPin = '123456';
      final salt = DeviceTransferService.generateSalt();

      final key = await DeviceTransferService.deriveKey(correctPin, salt);
      final wrongKey = await DeviceTransferService.deriveKey(wrongPin, salt);

      final payload = {'secret': 'super_sensitive_token'};
      final encrypted = await DeviceTransferService.encryptPayload(payload, key);

      expect(() => DeviceTransferService.decryptPayload(encrypted, wrongKey), throwsA(isA<Exception>()));
    });
  });

  group('DeviceTransferReceiver and DeviceTransferSender integration', () {
    test('successful transfer over local port', () async {
      const pin = '771234';
      final completer = Completer<Map<String, dynamic>>();

      final receiver = DeviceTransferReceiver(
        pin: pin,
        onPayloadReceived: (payload) async {
          completer.complete(payload);
        },
      );

      final port = await receiver.start();
      expect(port, greaterThan(0));

      final testPayload = {
        'formatVersion': 1,
        'settings': {'audioPassthrough': true},
        'connections': [
          {
            'kind': 'jellyfin',
            'config': {'baseUrl': 'http://192.168.1.50:8096'},
          },
        ],
      };

      await DeviceTransferSender.send(targetIp: '127.0.0.1', targetPort: port, pin: pin, payload: testPayload);

      final received = await completer.future.timeout(const Duration(seconds: 5));
      expect(received['formatVersion'], 1);
      expect(received['settings']['audioPassthrough'], true);
      expect(received['connections'][0]['kind'], 'jellyfin');

      await receiver.stop();
    });

    test('transfer with wrong PIN throws InvalidTransferPinException', () async {
      const correctPin = '771234';
      const wrongPin = '000000';

      final receiver = DeviceTransferReceiver(pin: correctPin, onPayloadReceived: (_) async {});

      final port = await receiver.start();

      await expectLater(
        DeviceTransferSender.send(targetIp: '127.0.0.1', targetPort: port, pin: wrongPin, payload: {'test': true}),
        throwsA(isA<InvalidTransferPinException>()),
      );

      await receiver.stop();
    });

    test('discovery finds broadcasting receiver', () async {
      const pin = '112233';
      final receiver = DeviceTransferReceiver(pin: pin, onPayloadReceived: (_) async {});

      final port = await receiver.start();
      final discovery = DeviceTransferDiscovery();
      await discovery.start();

      final discoveredDevice = await discovery.onDeviceDiscovered
          .firstWhere((d) => d.port == port)
          .timeout(const Duration(seconds: 4));

      expect(discoveredDevice.port, port);
      expect(discoveredDevice.name, isNotEmpty);

      await discovery.stop();
      await receiver.stop();
    });

    test('discovery finds receiver via direct TCP probe', () async {
      const pin = '445566';
      final receiver = DeviceTransferReceiver(pin: pin, onPayloadReceived: (_) async {});

      final port = await receiver.start(preferredPort: 48635);
      expect(port, 48635);

      final discovery = DeviceTransferDiscovery();
      await discovery.start();

      final discoveredDevice = await discovery.onDeviceDiscovered
          .firstWhere((d) => d.port == port && d.ip == '127.0.0.1')
          .timeout(const Duration(seconds: 4));

      expect(discoveredDevice.port, 48635);
      expect(discoveredDevice.name, isNotEmpty);

      await discovery.stop();
      await receiver.stop();
    });

    test('receiver terminates after 3 failed PIN attempts', () async {
      const correctPin = '771234';
      const wrongPin = '000000';

      final receiver = DeviceTransferReceiver(pin: correctPin, maxFailedAttempts: 3, onPayloadReceived: (_) async {});

      final port = await receiver.start();

      // Attempts 1 and 2 fail
      for (int i = 0; i < 2; i++) {
        await expectLater(
          DeviceTransferSender.send(targetIp: '127.0.0.1', targetPort: port, pin: wrongPin, payload: {'test': true}),
          throwsA(isA<InvalidTransferPinException>()),
        );
      }

      // Attempt 3 fails and triggers receiver shutdown
      await expectLater(
        DeviceTransferSender.send(targetIp: '127.0.0.1', targetPort: port, pin: wrongPin, payload: {'test': true}),
        throwsA(isA<InvalidTransferPinException>()),
      );

      // Give it a brief tick to process shutdown
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // Attempt 4 should fail with connection error because server closed
      await expectLater(
        DeviceTransferSender.send(targetIp: '127.0.0.1', targetPort: port, pin: wrongPin, payload: {'test': true}),
        throwsA(isA<TransferConnectionException>()),
      );

      await receiver.stop();
    });

    test('receiver responds HTTP 200 immediately before slow onPayloadReceived completes', () async {
      const pin = '882341';
      final payloadProcessingCompleter = Completer<void>();

      final receiver = DeviceTransferReceiver(
        pin: pin,
        onPayloadReceived: (payload) async {
          // Simulate slow outbound registration or DB work
          await payloadProcessingCompleter.future;
        },
      );

      final port = await receiver.start();

      // Send payload with a short sender timeout.
      // If receiver held the connection while onPayloadReceived ran, this would timeout.
      final sendFuture = DeviceTransferSender.send(
        targetIp: '127.0.0.1',
        targetPort: port,
        pin: pin,
        payload: {'test': 'immediate_ack'},
        timeout: const Duration(seconds: 2),
      );

      await expectLater(sendFuture, completes);

      // Complete the background processing
      payloadProcessingCompleter.complete();
      await receiver.stop();
    });
  });

  group('DeviceTransferService Jellyfin and profile connection persistence', () {
    late AppDatabase dbSender;
    late AppDatabase dbReceiver;

    setUp(() async {
      resetSharedPreferencesForTest();
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      dbSender = AppDatabase.forTesting(NativeDatabase.memory());
      dbReceiver = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await dbSender.close();
      await dbReceiver.close();
    });

    test('buildPayload and applyPayload roundtrips Jellyfin connection and profile connection', () async {
      final senderConnReg = ConnectionRegistry(dbSender);
      final senderProfReg = ProfileRegistry(dbSender);
      final senderPcReg = ProfileConnectionRegistry(dbSender);

      // 1. Setup sender data
      final testProfile = Profile.local(id: 'prof-local-1', displayName: 'Test User', createdAt: DateTime.now());
      await senderProfReg.upsert(testProfile);

      final jfConn = JellyfinConnection(
        id: 'jf-server-1',
        serverName: 'Home Jellyfin',
        serverMachineId: 'machine-jf-1',
        baseUrl: 'http://192.168.1.100:8096',
        userId: 'user-jf-123',
        userName: 'alice',
        accessToken: 'secret-jf-token-abc',
        deviceId: 'dev-1',
        createdAt: DateTime.now(),
      );
      await senderConnReg.upsert(jfConn);

      final pc = ProfileConnection(
        profileId: 'prof-local-1',
        connectionId: 'jf-server-1',
        userToken: 'secret-jf-token-abc',
        userIdentifier: 'user-jf-123',
        isDefault: true,
        tokenAcquiredAt: DateTime.now(),
      );
      await senderPcReg.upsert(pc);

      // 2. Build payload
      final payload = await DeviceTransferService.buildPayload(
        includeSettings: false,
        includeConnections: true,
        connections: senderConnReg,
        profileConnections: senderPcReg,
        profiles: senderProfReg,
      );

      expect(payload['connections'], isNotEmpty);
      expect(payload['profileConnections'], isNotEmpty);
      expect(payload['profiles'], isNotEmpty);

      // 3. Apply on fresh receiver
      final rxConnReg = ConnectionRegistry(dbReceiver);
      final rxProfReg = ProfileRegistry(dbReceiver);
      final rxPcReg = ProfileConnectionRegistry(dbReceiver);
      final rxPlexHome = PlexHomeService(
        connections: rxConnReg,
        profileConnections: rxPcReg,
        storage: await StorageService.getInstance(),
      );

      final result = await DeviceTransferService.applyPayload(
        payload,
        connections: rxConnReg,
        profileConnections: rxPcReg,
        plexHome: rxPlexHome,
        profileRegistry: rxProfReg,
      );

      expect(result.connectionsImported, 1);

      // Verify connection restored
      final rxConnections = await rxConnReg.list();
      expect(rxConnections.length, 1);
      expect(rxConnections.first.id, 'jf-server-1');
      expect((rxConnections.first as JellyfinConnection).accessToken, 'secret-jf-token-abc');

      // Verify profile restored
      final rxProfiles = await rxProfReg.list();
      expect(rxProfiles.length, 1);
      expect(rxProfiles.first.id, 'prof-local-1');
      expect(rxProfiles.first.displayName, 'Test User');

      // Verify profile connection restored
      final rxProfileConnections = await rxPcReg.listForProfile('prof-local-1');
      expect(rxProfileConnections.length, 1);
      expect(rxProfileConnections.first.connectionId, 'jf-server-1');
      expect(rxProfileConnections.first.userToken, 'secret-jf-token-abc');
    });

    test(
      'applyPayload auto-binds Jellyfin connection to a fallback profile if payload has no profile bindings',
      () async {
        final rxConnReg = ConnectionRegistry(dbReceiver);
        final rxProfReg = ProfileRegistry(dbReceiver);
        final rxPcReg = ProfileConnectionRegistry(dbReceiver);
        final rxPlexHome = PlexHomeService(
          connections: rxConnReg,
          profileConnections: rxPcReg,
          storage: await StorageService.getInstance(),
        );

        // Payload has Jellyfin server but NO profile connections (legacy payload or standalone server)
        final legacyPayload = {
          'formatVersion': 1,
          'connections': [
            {
              'kind': 'jellyfin',
              'id': 'jf-orphan-1',
              'config': {
                'serverName': 'Orphan Jellyfin',
                'serverMachineId': 'machine-orphan-1',
                'baseUrl': 'http://192.168.1.150:8096',
                'userId': 'user-orphan-456',
                'userName': 'bob',
                'accessToken': 'orphan-token-789',
                'deviceId': 'dev-orphan',
              },
            },
          ],
        };

        final result = await DeviceTransferService.applyPayload(
          legacyPayload,
          connections: rxConnReg,
          profileConnections: rxPcReg,
          plexHome: rxPlexHome,
          profileRegistry: rxProfReg,
        );

        expect(result.connectionsImported, 1);

        // A fallback local profile should have been created
        final rxProfiles = await rxProfReg.list();
        expect(rxProfiles.length, 1);
        final fallbackProfile = rxProfiles.first;

        // The Jellyfin connection must be bound to this fallback profile!
        final rxProfileConnections = await rxPcReg.listForProfile(fallbackProfile.id);
        expect(rxProfileConnections.length, 1);
        expect(rxProfileConnections.first.connectionId, 'jf-orphan-1');
        expect(rxProfileConnections.first.userToken, 'orphan-token-789');
      },
    );

    test('buildPayload and applyPayload transfers custom playlists and custom playlist items', () async {
      final senderConnReg = ConnectionRegistry(dbSender);
      final rxConnReg = ConnectionRegistry(dbReceiver);
      final rxProfReg = ProfileRegistry(dbReceiver);
      final rxPcReg = ProfileConnectionRegistry(dbReceiver);
      final rxPlexHome = PlexHomeService(
        connections: rxConnReg,
        profileConnections: rxPcReg,
        storage: await StorageService.getInstance(),
      );

      // 1. Create custom playlist on sender
      final item1 = MediaItem(id: 'item-1', backend: MediaBackend.jellyfin, kind: MediaKind.movie, title: 'Movie 1');
      final item2 = MediaItem(id: 'item-2', backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Movie 2');

      await dbSender.createCustomPlaylist(
        profileId: 'prof-local-1',
        title: 'My Favorite Sci-Fi',
        playlistType: 'video',
        summary: 'Cross-server collection',
        initialItems: [item1, item2],
      );

      // 2. Build payload with database
      final payload = await DeviceTransferService.buildPayload(
        includeSettings: false,
        includeConnections: true,
        connections: senderConnReg,
        database: dbSender,
      );

      expect(payload['customPlaylists'], isNotEmpty);
      expect((payload['customPlaylists'] as List).length, 1);
      expect(payload['customPlaylistItems'], isNotEmpty);
      expect((payload['customPlaylistItems'] as List).length, 2);

      // 3. Apply on receiver
      final result = await DeviceTransferService.applyPayload(
        payload,
        connections: rxConnReg,
        profileConnections: rxPcReg,
        plexHome: rxPlexHome,
        profileRegistry: rxProfReg,
        database: dbReceiver,
      );

      expect(result.playlistsImported, 1);

      // 4. Verify receiver database has the custom playlist and items
      final rxPlaylists = await dbReceiver.getCustomPlaylists(profileId: 'prof-local-1');
      expect(rxPlaylists.length, 1);
      expect(rxPlaylists.first.title, 'My Favorite Sci-Fi');
      expect(rxPlaylists.first.summary, 'Cross-server collection');
      expect(rxPlaylists.first.leafCount, 2);
    });

    test('buildPayload and applyPayload preserves and activates active profile identity', () async {
      final senderConnReg = ConnectionRegistry(dbSender);
      final senderProfReg = ProfileRegistry(dbSender);
      final senderPcReg = ProfileConnectionRegistry(dbSender);
      final senderStorage = await StorageService.getInstance();

      final profileA = Profile.local(id: 'prof-local-a', displayName: 'Alice', createdAt: DateTime.now());
      final profileB = Profile.local(id: 'prof-local-b', displayName: 'Bob', createdAt: DateTime.now());
      await senderProfReg.upsert(profileA);
      await senderProfReg.upsert(profileB);
      await senderStorage.setActiveProfileId('prof-local-b');

      final payload = await DeviceTransferService.buildPayload(
        includeSettings: false,
        includeConnections: true,
        connections: senderConnReg,
        profileConnections: senderPcReg,
        profiles: senderProfReg,
      );

      expect(payload['activeProfileId'], 'prof-local-b');

      final rxConnReg = ConnectionRegistry(dbReceiver);
      final rxProfReg = ProfileRegistry(dbReceiver);
      final rxPcReg = ProfileConnectionRegistry(dbReceiver);
      final rxStorage = await StorageService.getInstance();
      final rxPlexHome = PlexHomeService(
        connections: rxConnReg,
        profileConnections: rxPcReg,
        storage: rxStorage,
      );

      final rxActiveProfiles = ActiveProfileProvider(
        registry: rxProfReg,
        plexHome: rxPlexHome,
        connections: rxConnReg,
        profileConnections: rxPcReg,
        storage: rxStorage,
      );
      await rxActiveProfiles.initialize();

      final result = await DeviceTransferService.applyPayload(
        payload,
        connections: rxConnReg,
        profileConnections: rxPcReg,
        plexHome: rxPlexHome,
        profileRegistry: rxProfReg,
        activeProfiles: rxActiveProfiles,
      );

      expect(result.activeProfileName, 'Bob');
      expect(rxActiveProfiles.activeId, 'prof-local-b');
      expect(rxStorage.getActiveProfileId(), 'prof-local-b');

      rxActiveProfiles.dispose();
    });
  });
}
