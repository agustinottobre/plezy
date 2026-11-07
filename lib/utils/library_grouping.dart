import '../media/ids.dart';
import '../media/media_library.dart';
import '../services/multi_server_manager.dart';

typedef LibraryServerGroups = ({List<String> serverOrder, Map<String, List<MediaLibrary>> byServer});

/// Groups libraries by server while preserving each server's first appearance in
/// the provided list. Libraries without a server id are placed in the empty-key
/// bucket at their first occurrence.
LibraryServerGroups groupLibrariesByFirstAppearance(List<MediaLibrary> libraries) {
  final order = <String>[];
  final byServer = <String, List<MediaLibrary>>{};
  for (final lib in libraries) {
    final key = lib.serverId ?? '';
    if (!byServer.containsKey(key)) {
      order.add(key);
      byServer[key] = [];
    }
    byServer[key]!.add(lib);
  }
  return (serverOrder: order, byServer: byServer);
}

/// Groups libraries by server and sorts the servers deterministically:
/// 1. By server backend type (Plex, then Jellyfin, then Emby)
/// 2. Alphabetically by server name (case-insensitive)
/// 3. By server id as tie-breaker
///
/// Libraries without a server id are placed first in the empty-key bucket.
/// If [extraServerIds] are provided (e.g. offline servers with no loaded libraries),
/// they are included in [byServer] and [serverOrder] so offline servers do not disappear.
LibraryServerGroups groupLibrariesDeterministically(
  List<MediaLibrary> libraries, {
  MultiServerManager? serverManager,
  Iterable<String>? extraServerIds,
}) {
  final byServer = <String, List<MediaLibrary>>{};
  for (final lib in libraries) {
    final key = lib.serverId ?? '';
    (byServer[key] ??= []).add(lib);
  }
  if (extraServerIds != null) {
    for (final id in extraServerIds) {
      byServer.putIfAbsent(id, () => []);
    }
  }

  final order = byServer.keys.toList();
  order.sort((a, b) {
    if (a.isEmpty && b.isEmpty) return 0;
    if (a.isEmpty) return -1;
    if (b.isEmpty) return 1;

    final backendA = (byServer[a]?.firstOrNull?.backend ?? serverManager?.serverBackend(ServerId(a)))?.index ?? 99;
    final backendB = (byServer[b]?.firstOrNull?.backend ?? serverManager?.serverBackend(ServerId(b)))?.index ?? 99;
    if (backendA != backendB) return backendA.compareTo(backendB);

    final nameA = (byServer[a]?.firstOrNull?.serverName ?? serverManager?.serverDisplayName(ServerId(a)) ?? a)
        .toLowerCase();
    final nameB = (byServer[b]?.firstOrNull?.serverName ?? serverManager?.serverDisplayName(ServerId(b)) ?? b)
        .toLowerCase();
    final nameCompare = nameA.compareTo(nameB);
    if (nameCompare != 0) return nameCompare;

    return a.compareTo(b);
  });

  return (serverOrder: order, byServer: byServer);
}
