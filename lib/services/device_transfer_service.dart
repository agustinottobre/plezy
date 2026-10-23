import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../connection/plex_account_setup.dart';
import '../database/app_database.dart';
import '../profiles/active_profile_binder.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/plex_home_service.dart';
import '../profiles/profile.dart';
import '../profiles/profile_connection.dart';
import '../profiles/profile_connection_registry.dart';
import '../profiles/profile_registry.dart';
import '../utils/app_logger.dart';
import '../utils/device_identity.dart';
import '../utils/udp_broadcast_sockets.dart';
import 'package:uuid/uuid.dart';
import 'settings_export_service.dart';
import 'settings_service.dart';
import 'storage_service.dart';

class DeviceTransferException implements Exception {
  final String message;
  const DeviceTransferException(this.message);
  @override
  String toString() => message;
}

class InvalidTransferPinException extends DeviceTransferException {
  const InvalidTransferPinException() : super('Invalid PIN. Please check the code on your target device.');
}

class TransferConnectionException extends DeviceTransferException {
  const TransferConnectionException(super.message);
}

/// Outcome of applying a received setup payload on the target device.
class DeviceTransferApplyResult {
  final int connectionsImported;
  final int settingsImported;
  final int playlistsImported;
  final String? activeProfileName;

  const DeviceTransferApplyResult({
    required this.connectionsImported,
    required this.settingsImported,
    this.playlistsImported = 0,
    this.activeProfileName,
  });
}

/// Core service handling E2E encrypted LAN setup transfer between Plezy devices.
class DeviceTransferService {
  static const int currentFormatVersion = 1;
  static const String transferKdfInfo = 'plezy-device-transfer-v1';
  static final _hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
  static final _aesGcm = AesGcm.with256bits();

  /// Generates a random 6-digit numeric PIN.
  static String generatePin() {
    final rng = Random.secure();
    return (100000 + rng.nextInt(900000)).toString();
  }

  /// Generates a random 16-byte cryptographic salt.
  static Uint8List generateSalt() {
    final rng = Random.secure();
    final bytes = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytes;
  }

  /// Derives a 256-bit AES key from the 6-digit PIN and session salt via HKDF-SHA256.
  static Future<SecretKey> deriveKey(String pin, List<int> salt) {
    return _hkdf.deriveKey(
      secretKey: SecretKey(utf8.encode(pin.trim())),
      nonce: salt,
      info: utf8.encode(transferKdfInfo),
    );
  }

  /// Encrypts a JSON-encodable map into `{nonce, ciphertext, mac}` using AES-256-GCM.
  static Future<Map<String, String>> encryptPayload(Map<String, dynamic> payload, SecretKey key) async {
    final clearBytes = utf8.encode(jsonEncode(payload));
    final box = await _aesGcm.encrypt(clearBytes, secretKey: key);
    return {
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
  }

  /// Decrypts `{nonce, ciphertext, mac}` with the key; throws on MAC mismatch.
  static Future<Map<String, dynamic>> decryptPayload(Map<String, dynamic> encrypted, SecretKey key) async {
    final nonce = base64Decode(encrypted['nonce'] as String);
    final ciphertext = base64Decode(encrypted['ciphertext'] as String);
    final macBytes = base64Decode(encrypted['mac'] as String);
    final box = SecretBox(ciphertext, nonce: nonce, mac: Mac(macBytes));
    final clearBytes = await _aesGcm.decrypt(box, secretKey: key);
    return jsonDecode(utf8.decode(clearBytes)) as Map<String, dynamic>;
  }

  /// Builds the full transfer payload from local state based on chosen options.
  static Future<Map<String, dynamic>> buildPayload({
    required bool includeSettings,
    required bool includeConnections,
    required ConnectionRegistry connections,
    ProfileConnectionRegistry? profileConnections,
    ProfileRegistry? profiles,
    ActiveProfileProvider? activeProfiles,
    AppDatabase? database,
    String? appVersion,
  }) async {
    final payload = <String, dynamic>{
      'formatVersion': currentFormatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'platform': Platform.operatingSystem,
    };

    if (activeProfiles?.active != null) {
      payload['activeProfileId'] = activeProfiles!.active!.id;
      payload['activeProfileName'] = activeProfiles.active!.displayName;
    } else {
      try {
        final storage = await StorageService.getInstance();
        final storedId = storage.getActiveProfileId();
        if (storedId != null) {
          payload['activeProfileId'] = storedId;
        }
      } catch (_) {}
    }

    if (includeSettings) {
      final storage = await StorageService.getInstance();
      final settingsService = await SettingsService.getInstance();
      payload['settings'] = SettingsExportService.buildExportMap(
        settingsService.prefs,
        currentUserUuid: storage.activeUserScope(),
        appVersion: appVersion ?? '',
      );
    }

    if (includeConnections) {
      final all = await connections.list();
      final connectionsList = <Map<String, dynamic>>[];
      for (final conn in all) {
        connectionsList.add({
          'id': conn.id,
          'kind': conn.kind.id,
          'displayName': conn.displayName,
          'createdAt': conn.createdAt.millisecondsSinceEpoch,
          'lastAuthenticatedAt': conn.lastAuthenticatedAt?.millisecondsSinceEpoch,
          'config': conn.toConfigJson(),
        });
      }
      payload['connections'] = connectionsList;

      if (profileConnections != null) {
        final allProfileConnections = await profileConnections.listAll();
        payload['profileConnections'] = allProfileConnections
            .map(
              (pc) => {
                'profileId': pc.profileId,
                'connectionId': pc.connectionId,
                'userToken': pc.userToken,
                'userIdentifier': pc.userIdentifier,
                'isDefault': pc.isDefault,
                'tokenAcquiredAt': pc.tokenAcquiredAt?.millisecondsSinceEpoch,
              },
            )
            .toList();
      }

      if (profiles != null) {
        final allProfiles = await profiles.list();
        payload['profiles'] = allProfiles
            .where((p) => p.isLocal)
            .map(
              (p) => {
                'id': p.id,
                'displayName': p.displayName,
                'avatarThumbUrl': p.avatarThumbUrl,
                'pinHash': p.pinHash,
                'sortOrder': p.sortOrder,
                'createdAt': p.createdAt.millisecondsSinceEpoch,
                'lastUsedAt': p.lastUsedAt?.millisecondsSinceEpoch,
              },
            )
            .toList();
      }

      if (database != null) {
        final playlists = await database.select(database.customPlaylists).get();
        if (playlists.isNotEmpty) {
          final playlistIds = playlists.map((p) => p.id).toList();
          final items =
              await (database.select(database.customPlaylistItems)
                    ..where((t) => t.playlistId.isIn(playlistIds))
                    ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
                  .get();

          payload['customPlaylists'] = playlists
              .map(
                (p) => {
                  'id': p.id,
                  'profileId': p.profileId,
                  'title': p.title,
                  'playlistType': p.playlistType,
                  'summary': p.summary,
                  'thumbPath': p.thumbPath,
                  'createdAt': p.createdAt,
                  'updatedAt': p.updatedAt,
                },
              )
              .toList();

          payload['customPlaylistItems'] = items
              .map(
                (i) => {
                  'playlistId': i.playlistId,
                  'sortOrder': i.sortOrder,
                  'mediaJson': i.mediaJson,
                  'mediaGlobalKey': i.mediaGlobalKey,
                  'addedAt': i.addedAt,
                },
              )
              .toList();
        }
      }
    }

    return payload;
  }

  /// Applies a decrypted payload to the target device.
  static Future<DeviceTransferApplyResult> applyPayload(
    Map<String, dynamic> payload, {
    required ConnectionRegistry connections,
    required ProfileConnectionRegistry profileConnections,
    required PlexHomeService plexHome,
    ProfileRegistry? profileRegistry,
    ActiveProfileProvider? activeProfiles,
    ActiveProfileBinder? activeBinder,
    AppDatabase? database,
  }) async {
    int connectionsImported = 0;
    int settingsImported = 0;
    int playlistsImported = 0;
    final storage = await StorageService.getInstance();
    final importedMediaBrowserConnections = <JellyfinConnection>[];

    // 1. Restore local profiles if provided
    final rawProfiles = payload['profiles'];
    if (rawProfiles is List && profileRegistry != null) {
      for (final p in rawProfiles) {
        if (p is! Map) continue;
        final id = p['id'] as String?;
        final displayName = p['displayName'] as String? ?? 'User';
        final avatarThumbUrl = p['avatarThumbUrl'] as String?;
        final pinHash = p['pinHash'] as String?;
        final sortOrder = p['sortOrder'] as int? ?? 0;
        final createdAt = DateTime.fromMillisecondsSinceEpoch(
          p['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        );
        final lastUsedAt = p['lastUsedAt'] != null ? DateTime.fromMillisecondsSinceEpoch(p['lastUsedAt'] as int) : null;
        if (id == null) continue;
        try {
          await profileRegistry.upsert(
            Profile.local(
              id: id,
              displayName: displayName,
              avatarThumbUrl: avatarThumbUrl,
              pinHash: pinHash,
              sortOrder: sortOrder,
              createdAt: createdAt,
              lastUsedAt: lastUsedAt,
            ),
          );
        } catch (e) {
          appLogger.w('DeviceTransfer: failed to restore profile $id', error: e);
        }
      }
    }

    // 2. Restore connections
    final rawConnections = payload['connections'];
    if (rawConnections is List) {
      for (final item in rawConnections) {
        if (item is! Map) continue;
        final kind = item['kind'] as String?;
        final id = item['id'] as String?;
        final rawConfig = item['config'];
        if (id == null || kind == null || rawConfig is! Map) continue;

        final config = Map<String, Object?>.from(rawConfig);
        final createdAt = DateTime.fromMillisecondsSinceEpoch(
          item['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        );
        final lastAuth = item['lastAuthenticatedAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(item['lastAuthenticatedAt'] as int)
            : null;

        if (kind == 'plex') {
          final accountToken = config['accountToken'] as String? ?? '';
          if (accountToken.isNotEmpty) {
            try {
              await registerPlexAccountFromToken(
                token: accountToken,
                connections: connections,
                profileConnections: profileConnections,
                storage: storage,
                plexHome: plexHome,
              );
              connectionsImported++;
            } catch (e) {
              appLogger.w('DeviceTransfer: online Plex registration failed, saving offline fallback', error: e);
              final fallback = PlexAccountConnection.fromConfigJson(
                id: id,
                json: config,
                createdAt: createdAt,
                lastAuthenticatedAt: lastAuth,
              );
              await connections.upsert(fallback);
              connectionsImported++;
            }
          }
        } else if (kind == 'jellyfin' || kind == 'emby') {
          final conn = JellyfinConnection.fromConfigJson(
            id: id,
            json: config,
            createdAt: createdAt,
            lastAuthenticatedAt: lastAuth,
          );
          await connections.upsert(conn);
          importedMediaBrowserConnections.add(conn);
          connectionsImported++;
        }
      }
    }

    // 3. Restore explicit profile connections if provided
    final rawProfileConnections = payload['profileConnections'];
    if (rawProfileConnections is List) {
      for (final pc in rawProfileConnections) {
        if (pc is! Map) continue;
        final profileId = pc['profileId'] as String?;
        final connectionId = pc['connectionId'] as String?;
        final userToken = pc['userToken'] as String?;
        final userIdentifier = pc['userIdentifier'] as String?;
        final isDefault = pc['isDefault'] as bool? ?? false;
        final tokenAcquiredAt = pc['tokenAcquiredAt'] != null
            ? DateTime.fromMillisecondsSinceEpoch(pc['tokenAcquiredAt'] as int)
            : null;
        if (profileId == null || connectionId == null || userIdentifier == null) continue;

        try {
          await profileConnections.upsert(
            ProfileConnection(
              profileId: profileId,
              connectionId: connectionId,
              userToken: userToken,
              userIdentifier: userIdentifier,
              isDefault: isDefault,
              tokenAcquiredAt: tokenAcquiredAt,
            ),
          );
        } catch (e) {
          appLogger.w('DeviceTransfer: failed to restore profile connection $profileId -> $connectionId', error: e);
        }
      }
    }

    // 4. Ensure every imported Jellyfin / Emby connection is bound to a valid profile.
    final rawActiveProfileId = payload['activeProfileId'] as String?;
    final rawActiveProfileName = payload['activeProfileName'] as String?;

    if (activeProfiles != null) {
      try {
        await activeProfiles.reloadFromStorage();
      } catch (_) {}
    }

    // Resolve matching profile from transferred metadata
    Profile? matchingProfile;
    if (activeProfiles != null && activeProfiles.profiles.isNotEmpty) {
      if (rawActiveProfileId != null) {
        matchingProfile = activeProfiles.profiles.where((p) => p.id == rawActiveProfileId).firstOrNull;
      }
      if (matchingProfile == null && rawActiveProfileName != null && rawActiveProfileName.trim().isNotEmpty) {
        final targetName = rawActiveProfileName.trim().toLowerCase();
        matchingProfile = activeProfiles.profiles
            .where((p) => p.displayName.trim().toLowerCase() == targetName)
            .firstOrNull;
      }
      matchingProfile ??= activeProfiles.active ?? activeProfiles.profiles.firstOrNull;
    }

    if (matchingProfile != null) {
      try {
        if (activeProfiles != null) {
          await activeProfiles.activate(matchingProfile);
        }
      } catch (e) {
        appLogger.w('DeviceTransfer: failed to activate profile ${matchingProfile.id}', error: e);
      }
      try {
        await storage.setActiveProfileId(matchingProfile.id);
        await storage.markProfileUsed(matchingProfile.id, DateTime.now());
      } catch (_) {}
    } else if (rawActiveProfileId != null) {
      try {
        await storage.setActiveProfileId(rawActiveProfileId);
        await storage.markProfileUsed(rawActiveProfileId, DateTime.now());
      } catch (_) {}
    }

    var activeId = activeProfiles?.activeId ?? matchingProfile?.id ?? rawActiveProfileId ?? storage.getActiveProfileId();
    if (activeId == null && (activeProfiles?.profiles.isNotEmpty ?? false)) {
      activeId = activeProfiles!.profiles.first.id;
    }

    for (final conn in importedMediaBrowserConnections) {
      final existingMappings = await profileConnections.listForConnection(conn.id);
      if (existingMappings.isEmpty) {
        // If target device has no profiles at all yet, create a local profile for this user
        if (activeId == null && profileRegistry != null) {
          final now = DateTime.now();
          final localProfile = Profile.local(
            id: 'local-${const Uuid().v4()}',
            displayName: conn.userName.isNotEmpty ? conn.userName : conn.serverName,
            sortOrder: now.millisecondsSinceEpoch,
            createdAt: now,
          );
          await profileRegistry.upsert(localProfile);
          if (activeProfiles != null) {
            await activeProfiles.reloadFromStorage();
            await activeProfiles.activate(localProfile);
          }
          await storage.setActiveProfileId(localProfile.id);
          activeId = localProfile.id;
        }

        if (activeId != null) {
          await profileConnections.upsert(
            ProfileConnection(
              profileId: activeId,
              connectionId: conn.id,
              userToken: conn.accessToken,
              userIdentifier: conn.userId,
              isDefault: false,
              tokenAcquiredAt: DateTime.now(),
            ),
          );
        }
      }
    }

    // 5. Reload active profiles and trigger runtime rebind to load all new servers
    if (activeProfiles != null) {
      try {
        await activeProfiles.reloadFromStorage();
        final targetId = activeProfiles.activeId ?? activeId;
        if (targetId != null && activeBinder != null) {
          await activeBinder.rebindIfActive(targetId);
        }
      } catch (e) {
        appLogger.w('DeviceTransfer: failed to rebind active profile', error: e);
      }
    }

    // 6. Restore settings with the active user uuid
    final rawSettings = payload['settings'];
    if (rawSettings is Map<String, dynamic>) {
      final activeUserUuid = storage.activeUserScope() ?? '';
      final settingsService = await SettingsService.getInstance();
      final result = await SettingsExportService.applyImportMap(
        rawSettings,
        settingsService.prefs,
        currentUserUuid: activeUserUuid,
      );
      settingsImported = result.keysImported;
      settingsService.refreshListenables();
    }

    // 7. Restore custom playlists if provided
    final rawPlaylists = payload['customPlaylists'];
    final rawItems = payload['customPlaylistItems'];
    if (rawPlaylists is List && database != null) {
      for (final p in rawPlaylists) {
        if (p is! Map) continue;
        final id = p['id'] as String?;
        final title = p['title'] as String?;
        if (id == null || title == null) continue;
        final profileId = p['profileId'] as String? ?? '';
        final playlistType = p['playlistType'] as String? ?? 'video';
        final summary = p['summary'] as String?;
        final thumbPath = p['thumbPath'] as String?;
        final createdAt = p['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch;
        final updatedAt = p['updatedAt'] as int? ?? createdAt;

        await database
            .into(database.customPlaylists)
            .insertOnConflictUpdate(
              CustomPlaylistsCompanion(
                id: Value(id),
                profileId: Value(profileId),
                title: Value(title),
                playlistType: Value(playlistType),
                summary: Value(summary),
                thumbPath: Value(thumbPath),
                createdAt: Value(createdAt),
                updatedAt: Value(updatedAt),
              ),
            );
        playlistsImported++;
      }

      if (rawItems is List) {
        final importedPlaylistIds = rawPlaylists
            .map((p) => p is Map ? p['id'] as String? : null)
            .whereType<String>()
            .toList();

        if (importedPlaylistIds.isNotEmpty) {
          await (database.delete(
            database.customPlaylistItems,
          )..where((t) => t.playlistId.isIn(importedPlaylistIds))).go();
        }

        for (final item in rawItems) {
          if (item is! Map) continue;
          final playlistId = item['playlistId'] as String?;
          final mediaJson = item['mediaJson'] as String?;
          final mediaGlobalKey = item['mediaGlobalKey'] as String?;
          if (playlistId == null || mediaJson == null || mediaGlobalKey == null) continue;
          final sortOrder = item['sortOrder'] as int? ?? 0;
          final addedAt = item['addedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch;

          await database
              .into(database.customPlaylistItems)
              .insert(
                CustomPlaylistItemsCompanion.insert(
                  playlistId: playlistId,
                  sortOrder: sortOrder,
                  mediaJson: mediaJson,
                  mediaGlobalKey: mediaGlobalKey,
                  addedAt: addedAt,
                ),
              );
        }
      }
    }

    return DeviceTransferApplyResult(
      connectionsImported: connectionsImported,
      settingsImported: settingsImported,
      playlistsImported: playlistsImported,
      activeProfileName: activeProfiles?.active?.displayName,
    );
  }

  /// Lists routable private IPv4 addresses for this device.
  static Future<List<String>> getLocalIpAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLinkLocal: false,
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final ips = <String>[];
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || _isPrivateClassB(ip)) {
            ips.insert(0, ip);
          } else {
            ips.add(ip);
          }
        }
      }
      return ips;
    } catch (e) {
      appLogger.w('DeviceTransfer: could not enumerate network interfaces', error: e);
      return [];
    }
  }

  static bool _isPrivateClassB(String ip) {
    final parts = ip.split('.');
    if (parts.length < 2) return false;
    final second = int.tryParse(parts[1]) ?? 0;
    return parts[0] == '172' && second >= 16 && second <= 31;
  }

  /// Discovers local subnet prefixes (/24) including default gateway / router subnets.
  static Future<List<String>> getSubnetPrefixes() async {
    final prefixes = <String>{};
    final localIps = await getLocalIpAddresses();
    for (final ip in localIps) {
      final lastDot = ip.lastIndexOf('.');
      if (lastDot != -1) {
        prefixes.add(ip.substring(0, lastDot));
      }
    }

    // Inspect default gateway / routing table to detect multi-subnet / supernet LANs
    try {
      if (Platform.isMacOS || Platform.isLinux) {
        final res = await Process.run('route', ['-n', 'get', 'default']);
        if (res.exitCode == 0) {
          final match = RegExp(r'gateway:\s*([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+').firstMatch(res.stdout.toString());
          if (match != null) {
            prefixes.add(match.group(1)!);
          }
        }
      } else if (Platform.isWindows) {
        final res = await Process.run('route', ['print', '0.0.0.0']);
        if (res.exitCode == 0) {
          final matches = RegExp(
            r'0\.0\.0\.0\s+0\.0\.0\.0\s+([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+',
          ).allMatches(res.stdout.toString());
          for (final m in matches) {
            prefixes.add(m.group(1)!);
          }
        }
      }
    } catch (_) {}

    return prefixes.toList();
  }

  /// Resolves all broadcast addresses across detected local/routed subnet prefixes.
  static Future<List<InternetAddress>> getBroadcastAddresses() async {
    final targets = <InternetAddress>[UdpBroadcastSockets.limitedBroadcastAddress, InternetAddress.loopbackIPv4];
    try {
      final prefixes = await getSubnetPrefixes();
      for (final prefix in prefixes) {
        targets.add(InternetAddress('$prefix.255'));
      }
    } catch (_) {}
    return targets;
  }
}

/// Target device discovered on local Wi-Fi ready to receive setup.
class DiscoveredTargetDevice {
  final String name;
  final String ip;
  final int port;
  final bool isTv;

  const DiscoveredTargetDevice({required this.name, required this.ip, required this.port, this.isTv = false});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredTargetDevice && runtimeType == other.runtimeType && ip == other.ip && port == other.port;

  @override
  int get hashCode => ip.hashCode ^ port.hashCode;
}

/// Ephemeral receiver server that listens on LAN for a single encrypted transfer.
class DeviceTransferReceiver {
  DeviceTransferReceiver({
    required this.pin,
    required this.onPayloadReceived,
    this.maxFailedAttempts = 3,
    this.timeout = const Duration(minutes: 30),
  }) : salt = DeviceTransferService.generateSalt();

  static const int discoveryPort = 48634;
  static const int defaultHttpPort = 48635;
  static const int maxHttpPortOffset = 5;

  final String pin;
  final Uint8List salt;
  final int maxFailedAttempts;
  final Duration timeout;
  final Future<void> Function(Map<String, dynamic> payload) onPayloadReceived;

  HttpServer? _server;
  UdpBroadcastSocketSet? _broadcastSockets;
  RawDatagramSocket? _pingSocket;
  StreamSubscription<RawSocketEvent>? _pingSubscription;
  Timer? _beaconTimer;
  Timer? _timeoutTimer;
  int _failedAttempts = 0;
  bool _isDone = false;
  SecretKey? _derivedKey;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null && !_isDone;

  /// Starts listening on a predictable port or ephemeral port.
  Future<int> start({int? preferredPort}) async {
    _derivedKey = await DeviceTransferService.deriveKey(pin, salt);
    HttpServer? server;
    if (preferredPort != null) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, preferredPort);
      } catch (_) {}
    }
    if (server == null) {
      for (int offset = 0; offset <= maxHttpPortOffset; offset++) {
        try {
          server = await HttpServer.bind(InternetAddress.anyIPv4, defaultHttpPort + offset);
          break;
        } catch (_) {}
      }
    }
    _server = server ?? await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _timeoutTimer = Timer(timeout, stop);
    _listen();
    unawaited(_startBeacon());
    return _server!.port;
  }

  Future<void> _startBeacon() async {
    try {
      final identity = await DeviceIdentityService.resolve();
      final name = identity.deviceName ?? (identity.isTv ? 'Plezy TV' : 'Plezy');
      _broadcastSockets = await UdpBroadcastSockets.bind();
      final beaconData = utf8.encode(
        jsonEncode({
          'service': 'plezy_setup_transfer',
          'v': 1,
          'name': name,
          'isTv': identity.isTv,
          'port': _server!.port,
        }),
      );

      // Bind discovery ping response socket
      try {
        _pingSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
          reusePort: true,
        );
        _pingSocket!.broadcastEnabled = true;
        _pingSubscription = _pingSocket!.listen((event) {
          if (event == RawSocketEvent.read) {
            Datagram? dg;
            while ((dg = _pingSocket?.receive()) != null) {
              try {
                final msg = jsonDecode(utf8.decode(dg!.data)) as Map<String, dynamic>;
                if (msg['action'] == 'plezy_setup_discovery_ping') {
                  _pingSocket?.send(beaconData, dg.address, dg.port);
                }
              } catch (_) {}
            }
          }
        });
      } catch (e) {
        appLogger.w('DeviceTransferReceiver: failed to bind ping listener on $discoveryPort', error: e);
      }

      Future<void> sendOnce() async {
        if (!isRunning || _broadcastSockets == null) return;
        final targets = await DeviceTransferService.getBroadcastAddresses();
        for (final target in targets) {
          try {
            _broadcastSockets?.send(beaconData, target, discoveryPort);
          } catch (_) {}
        }
      }

      unawaited(sendOnce());
      _beaconTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) => unawaited(sendOnce()));
    } catch (e) {
      appLogger.w('DeviceTransferReceiver: failed to start discovery beacon', error: e);
    }
  }

  void _stopBeacon() {
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _pingSubscription?.cancel();
    _pingSubscription = null;
    _pingSocket?.close();
    _pingSocket = null;
    unawaited(_broadcastSockets?.close());
    _broadcastSockets = null;
  }

  void _listen() {
    _server?.listen((request) async {
      try {
        final path = request.uri.path;
        if (request.method == 'GET' && path == '/api/info') {
          final identity = await DeviceIdentityService.resolve();
          final name = identity.deviceName ?? (identity.isTv ? 'Plezy TV' : 'Plezy');
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'service': 'plezy_setup_transfer',
                'name': name,
                'port': _server!.port,
                'isTv': identity.isTv,
                'salt': base64Encode(salt),
              }),
            );
          await request.response.close();
          return;
        }

        if (request.method == 'POST' && path == '/api/transfer') {
          final content = await utf8.decodeStream(request);
          final Map<String, dynamic> body;
          try {
            body = jsonDecode(content) as Map<String, dynamic>;
          } catch (_) {
            request.response
              ..statusCode = HttpStatus.badRequest
              ..write(jsonEncode({'error': 'invalid_json'}));
            await request.response.close();
            return;
          }

          try {
            final decrypted = await DeviceTransferService.decryptPayload(body, _derivedKey!);
            _isDone = true;

            // Immediately send 200 OK so the sender receives instant acknowledgment
            request.response
              ..statusCode = HttpStatus.ok
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'status': 'ok'}));
            await request.response.close();

            // Run payload processing asynchronously after acknowledging HTTP response
            unawaited(() async {
              try {
                await onPayloadReceived(decrypted);
              } catch (e, st) {
                appLogger.e('DeviceTransferReceiver: background payload processing failed', error: e, stackTrace: st);
              } finally {
                Timer(const Duration(milliseconds: 500), stop);
              }
            }());
          } catch (e) {
            _failedAttempts++;
            appLogger.w('DeviceTransferReceiver: decryption failed (attempt $_failedAttempts)', error: e);
            request.response
              ..statusCode = HttpStatus.unauthorized
              ..headers.contentType = ContentType.json
              ..write(jsonEncode({'error': 'invalid_pin'}));
            await request.response.close();

            if (_failedAttempts >= maxFailedAttempts) {
              appLogger.w('DeviceTransferReceiver: max failed attempts reached, shutting down');
              Timer(const Duration(milliseconds: 100), stop);
            }
          }
          return;
        }

        // Default fallback response
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write('<html><body><h3>Plezy Setup Transfer Ready</h3></body></html>');
        await request.response.close();
      } catch (e) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
    });
  }

  Future<void> stop() async {
    _isDone = true;
    _stopBeacon();
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    await _server?.close(force: true);
    _server = null;
  }
}

/// Discovers nearby Plezy devices on Wi-Fi that are in "Receive Setup" mode.
class DeviceTransferDiscovery {
  static const int discoveryPort = DeviceTransferReceiver.discoveryPort;
  static const List<int> candidateHttpPorts = [
    DeviceTransferReceiver.defaultHttpPort,
    DeviceTransferReceiver.defaultHttpPort + 1,
    DeviceTransferReceiver.defaultHttpPort + 2,
    DeviceTransferReceiver.defaultHttpPort + 3,
    DeviceTransferReceiver.defaultHttpPort + 4,
    DeviceTransferReceiver.defaultHttpPort + 5,
  ];

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  Timer? _pingTimer;
  Timer? _probeTimer;
  bool _isStopped = false;
  bool _isProbing = false;
  final Set<String> _seenDevices = {};
  final StreamController<DiscoveredTargetDevice> _controller = StreamController<DiscoveredTargetDevice>.broadcast();

  Stream<DiscoveredTargetDevice> get onDeviceDiscovered => _controller.stream;

  Future<void> start() async {
    _isStopped = false;
    _isProbing = false;
    unawaited(_startUdp());
    _startSubnetProbing();
  }

  Future<void> _startUdp() async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      _socket!.broadcastEnabled = true;
      _subscription = _socket!.listen((event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg;
          while ((dg = _socket?.receive()) != null) {
            try {
              final data = jsonDecode(utf8.decode(dg!.data)) as Map<String, dynamic>;
              if (data['service'] == 'plezy_setup_transfer') {
                final port = data['port'] as int?;
                final name = data['name'] as String? ?? 'Plezy Device';
                final isTv = data['isTv'] as bool? ?? false;
                if (port != null && port > 0) {
                  final key = '${dg.address.address}:$port';
                  if (!_seenDevices.contains(key)) {
                    _seenDevices.add(key);
                    final device = DiscoveredTargetDevice(name: name, ip: dg.address.address, port: port, isTv: isTv);
                    appLogger.i(
                      'DeviceTransferDiscovery: discovered device via UDP beacon: $name at ${device.ip}:$port',
                    );
                    if (!_controller.isClosed) {
                      _controller.add(device);
                    }
                  }
                }
              }
            } catch (_) {}
          }
        }
      });

      // Also actively ping on LAN so waiting receivers respond immediately via unicast
      final pingData = utf8.encode(jsonEncode({'action': 'plezy_setup_discovery_ping'}));

      Future<void> sendPing() async {
        if (_socket == null || _isStopped) return;
        final targets = await DeviceTransferService.getBroadcastAddresses();
        for (final target in targets) {
          try {
            _socket?.send(pingData, target, discoveryPort);
          } catch (_) {}
        }
      }

      unawaited(sendPing());
      _pingTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => unawaited(sendPing()));
    } catch (e) {
      appLogger.w('DeviceTransferDiscovery: failed to bind discovery listener', error: e);
    }
  }

  int _probeCycle = 0;

  void _startSubnetProbing() {
    unawaited(_probeSubnet());
    _probeTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_isStopped && !_isProbing) {
        unawaited(_probeSubnet());
      }
    });
  }

  /// Manually triggers an immediate rescan of local subnets.
  Future<void> rescan() async {
    _isProbing = false;
    await _probeSubnet();
  }

  Future<void> _probeSubnet() async {
    if (_isStopped || _isProbing) return;
    _isProbing = true;
    _probeCycle++;
    try {
      final localIps = await DeviceTransferService.getLocalIpAddresses();
      final subnetPrefixes = await DeviceTransferService.getSubnetPrefixes();
      final targetIps = <String>{'127.0.0.1'};

      for (final prefix in subnetPrefixes) {
        for (int i = 1; i <= 254; i++) {
          final ip = '$prefix.$i';
          if (!localIps.contains(ip)) {
            targetIps.add(ip);
          }
        }
      }

      appLogger.i('DeviceTransferDiscovery: probing ${targetIps.length} target IPs (cycle $_probeCycle)');

      // Priority: defaultHttpPort (48635) is probed on every cycle for near-instant detection (<1s).
      // Candidate offset ports (48636..48640) are probed every 3rd cycle only if no device has been found yet.
      final portsToProbe = (_seenDevices.isEmpty && _probeCycle % 3 == 0)
          ? candidateHttpPorts
          : [DeviceTransferReceiver.defaultHttpPort];

      final ipList = targetIps.toList();
      const batchSize = 64;

      for (final port in portsToProbe) {
        if (_isStopped || _seenDevices.isNotEmpty) break;
        for (var i = 0; i < ipList.length; i += batchSize) {
          if (_isStopped || _seenDevices.isNotEmpty) break;
          final end = (i + batchSize > ipList.length) ? ipList.length : i + batchSize;
          final batch = ipList.sublist(i, end);
          await Future.wait(batch.map((ip) => _probeTarget(ip, port)));
        }
      }
    } catch (e) {
      appLogger.d('DeviceTransferDiscovery: subnet probe error', error: e);
    } finally {
      _isProbing = false;
    }
  }

  Future<void> _probeTarget(String ip, int port) async {
    final key = '$ip:$port';
    if (_seenDevices.contains(key) || _isStopped) return;

    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: const Duration(milliseconds: 250));
      socket.destroy();
      socket = null;

      final client = http.Client();
      try {
        final resp = await client
            .get(Uri.parse('http://$ip:$port/api/info'))
            .timeout(const Duration(milliseconds: 600));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          if (data['service'] == 'plezy_setup_transfer') {
            _seenDevices.add(key);
            final device = DiscoveredTargetDevice(
              name: (data['name'] as String?) ?? 'Plezy Device',
              ip: ip,
              port: (data['port'] as int?) ?? port,
              isTv: (data['isTv'] as bool?) ?? false,
            );
            appLogger.i('DeviceTransferDiscovery: found target device via TCP probe: "${device.name}" at $ip:$port');
            if (!_controller.isClosed) {
              _controller.add(device);
            }
          }
        }
      } catch (_) {
      } finally {
        client.close();
      }
    } catch (_) {
      socket?.destroy();
    }
  }

  Future<void> stop() async {
    _isStopped = true;
    _pingTimer?.cancel();
    _pingTimer = null;
    _probeTimer?.cancel();
    _probeTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    await _controller.close();
  }
}

/// Sender client that discovers receiver salt, encrypts the payload, and POSTs over LAN.
class DeviceTransferSender {
  static Future<void> send({
    required String targetIp,
    required int targetPort,
    required String pin,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final client = http.Client();
    try {
      // 1. Fetch salt from target
      final infoUri = Uri.parse('http://$targetIp:$targetPort/api/info');
      final http.Response infoResp;
      try {
        infoResp = await client.get(infoUri).timeout(timeout);
      } catch (e) {
        throw TransferConnectionException(
          'Could not connect to $targetIp:$targetPort. Ensure both devices are on the same Wi-Fi.',
        );
      }

      if (infoResp.statusCode != 200) {
        throw TransferConnectionException('Target device returned error (${infoResp.statusCode})');
      }

      final infoData = jsonDecode(infoResp.body) as Map<String, dynamic>;
      final saltString = infoData['salt'] as String?;
      if (saltString == null) {
        throw const TransferConnectionException('Invalid handshake from target device.');
      }
      final salt = base64Decode(saltString);

      // 2. Derive key & encrypt payload
      final key = await DeviceTransferService.deriveKey(pin, salt);
      final encrypted = await DeviceTransferService.encryptPayload(payload, key);

      // 3. POST encrypted payload
      final transferUri = Uri.parse('http://$targetIp:$targetPort/api/transfer');
      final http.Response transferResp;
      try {
        transferResp = await client
            .post(transferUri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(encrypted))
            .timeout(timeout);
      } catch (e) {
        throw TransferConnectionException('Failed to deliver setup payload to target device: $e');
      }

      if (transferResp.statusCode == 401) {
        throw const InvalidTransferPinException();
      }
      if (transferResp.statusCode != 200) {
        throw TransferConnectionException('Target device rejected setup (${transferResp.statusCode})');
      }
    } finally {
      client.close();
    }
  }
}
