import 'package:flutter/material.dart';
import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../media/ids.dart';
import '../media/media_backend.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../providers/multi_server_provider.dart';
import '../screens/settings/add_connection_screen.dart';
import '../screens/settings/add_jellyfin_screen.dart';
import '../screens/settings/add_plex_account_screen.dart';
import '../focus/focusable_button.dart';
import 'app_icon.dart';
import 'backend_badge.dart';

/// Top-of-app banner for servers that answered and refused this account.
/// Distinct from "server offline" — the server is reachable, so empty hubs
/// need an explanation.
///
/// Two refusals, two rows. A rejected token (HTTP 401,
/// [MultiServerProvider.authErrorServers]) gets a CTA that opens
/// [AddConnectionScreen]; the user picks the right backend and the resulting
/// token replaces the stale row in the registry, which clears the auth-error
/// state on the next health sweep. A refused account (HTTP 403,
/// [MultiServerProvider.accessDeniedServers]) gets no CTA: a new sign-in gets
/// the same refusal, and only the server owner or the network the device is on
/// can change it.
///
/// Collapses to `SizedBox.shrink()` when no visible server refuses.
class AuthErrorBanner extends StatelessWidget {
  const AuthErrorBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final signInEntries = context.select<MultiServerProvider, List<({ServerId serverId, String displayName})>>(
      (p) => p.authErrorServers,
    );
    final deniedEntries = context.select<MultiServerProvider, List<({ServerId serverId, String displayName})>>(
      (p) => p.accessDeniedServers,
    );
    if (signInEntries.isEmpty && deniedEntries.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (signInEntries.isNotEmpty)
              _BannerRow(
                icon: Symbols.lock_rounded,
                label: _buildSignInLabel(signInEntries),
                action: FocusableButton(
                  onPressed: () => _openReauth(context, signInEntries),
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.onErrorContainer,
                      foregroundColor: scheme.errorContainer,
                    ),
                    onPressed: () => _openReauth(context, signInEntries),
                    child: Text(t.connections.signInAgain),
                  ),
                ),
              ),
            if (deniedEntries.isNotEmpty)
              _BannerRow(
                icon: Symbols.block_rounded,
                label: deniedEntries.length == 1
                    ? t.connections.accessDeniedOne(name: deniedEntries.first.displayName)
                    : t.connections.accessDeniedMany(count: deniedEntries.length),
              ),
          ],
        ),
      ),
    );
  }

  String _buildSignInLabel(List<({ServerId serverId, String displayName})> entries) {
    if (entries.isEmpty) return '';
    if (entries.length == 1) {
      return t.connections.sessionExpiredOne(name: entries.first.displayName);
    }
    if (entries.length == 2) {
      return t.connections.sessionExpiredNamedMany(
        names: '${entries[0].displayName} & ${entries[1].displayName}',
      );
    }
    final names = entries.take(2).map((e) => e.displayName).join(', ');
    return t.connections.sessionExpiredNamedMany(
      names: '$names (+${entries.length - 2})',
    );
  }

  Future<void> _openReauth(
    BuildContext context,
    List<({ServerId serverId, String displayName})> entries,
  ) async {
    List<Connection> connections = const [];
    try {
      connections = await context.read<ConnectionRegistry>().list();
    } catch (_) {}

    if (!context.mounted) return;

    if (entries.length == 1) {
      final entry = entries.first;
      final conn = connections.where((c) {
        if (c is JellyfinConnection) return c.serverMachineId == entry.serverId.value;
        if (c is PlexAccountConnection) return c.servers.any((s) => s.clientIdentifier == entry.serverId.value);
        return false;
      }).firstOrNull;

      if (conn is JellyfinConnection) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AddJellyfinScreen(
              initialServerUrl: conn.baseUrl,
              initialUsername: conn.userName,
              dialect: conn.dialect,
            ),
          ),
        );
        return;
      } else if (conn is PlexAccountConnection) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AddPlexAccountScreen()),
        );
        return;
      }
    }

    await showExpiredServersSheet(context, entries, connections);
  }
}

Future<void> showExpiredServersSheet(
  BuildContext context,
  List<({ServerId serverId, String displayName})> entries,
  List<Connection> connections,
) async {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const AppIcon(Symbols.lock_rounded, size: 22, color: Color(0xFFFFA726)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.connections.expiredSessionsTitle,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const AppIcon(Symbols.close_rounded),
                    onPressed: () => Navigator.of(sheetContext).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                t.connections.expiredSessionsSubtitle,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: entries.map((entry) {
                      final conn = connections.where((c) {
                        if (c is JellyfinConnection) return c.serverMachineId == entry.serverId.value;
                        if (c is PlexAccountConnection) {
                          return c.servers.any((s) => s.clientIdentifier == entry.serverId.value);
                        }
                        return false;
                      }).firstOrNull;

                      final backend = conn?.backend ?? MediaBackend.jellyfin;
                      final subtitleText = conn is JellyfinConnection
                          ? '${conn.baseUrl} (${conn.userName})'
                          : t.connections.signInAgain;

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        elevation: 0,
                        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: const Color(0xFFFFA726).withValues(alpha: 0.4)),
                        ),
                        child: ListTile(
                          leading: BackendBadge(backend: backend, size: 24),
                          title: Text(entry.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            subtitleText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                          trailing: FilledButton.tonal(
                            onPressed: () async {
                              Navigator.of(sheetContext).pop();
                              if (conn is JellyfinConnection) {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => AddJellyfinScreen(
                                      initialServerUrl: conn.baseUrl,
                                      initialUsername: conn.userName,
                                      dialect: conn.dialect,
                                    ),
                                  ),
                                );
                              } else if (conn is PlexAccountConnection) {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => const AddPlexAccountScreen()),
                                );
                              } else {
                                await Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => const AddConnectionScreen()),
                                );
                              }
                            },
                            child: Text(t.connections.signInAgain),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const AppIcon(Symbols.add_link_rounded, size: 18),
                label: Text(t.connections.addConnection),
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddConnectionScreen()));
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _BannerRow extends StatelessWidget {
  const _BannerRow({required this.icon, required this.label, this.action});

  final IconData icon;
  final String label;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final action = this.action;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, action == null ? 16 : 8, 8),
      child: Row(
        children: [
          AppIcon(icon, fill: 1, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onErrorContainer, fontWeight: .w500),
            ),
          ),
          if (action != null) ...[const SizedBox(width: 8), action],
        ],
      ),
    );
  }
}
