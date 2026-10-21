import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../database/app_database.dart';
import '../../database/custom_playlist_operations.dart';
import '../../focus/focusable_action_bar.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/media_backend.dart';
import '../../media/media_item.dart';
import '../../media/media_playlist.dart';
import '../../mixins/refreshable.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/settings_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/library_refresh_notifier.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/backend_badge.dart';
import '../../widgets/create_custom_playlist_dialog.dart';
import '../../widgets/desktop_app_bar.dart';
import '../../widgets/focusable_media_card.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/media_card_sliver_layout.dart';
import '../libraries/state_messages.dart';

/// Top-level screen displaying all Custom Playlists and Server Playlists grouped by server.
class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen>
    with Refreshable, ManualRefreshable, FullRefreshable, FocusableTab {
  final _actionBarKey = GlobalKey<FocusableActionBarState>();
  final _firstItemFocusNode = FocusNode(debugLabel: 'playlists_first_item');

  StreamSubscription? _playlistsSubscription;
  String? _lastProfileId;

  bool _isLoading = true;
  String? _errorMessage;

  List<MediaPlaylist> _customPlaylists = [];
  List<String> _onlineServerIds = [];
  Map<String, String> _serverNames = {};
  Map<String, MediaBackend> _serverBackends = {};

  final Set<String> _expandedServers = {};
  final Map<String, List<MediaPlaylist>> _serverPlaylistsByServer = {};
  final Set<String> _loadingServers = {};
  final Map<String, String?> _serverErrors = {};

  @override
  void initState() {
    super.initState();
    _playlistsSubscription = LibraryRefreshNotifier().playlistsStream.listen((_) {
      if (mounted) _loadPlaylists();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadPlaylists(showLoadingIndicator: true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final currentProfileId = context.watch<ActiveProfileProvider>().activeId;
    if (_lastProfileId != null && _lastProfileId != currentProfileId) {
      _lastProfileId = currentProfileId;
      _loadPlaylists(showLoadingIndicator: true);
    } else {
      _lastProfileId = currentProfileId;
    }
  }

  @override
  void dispose() {
    _playlistsSubscription?.cancel();
    _firstItemFocusNode.dispose();
    super.dispose();
  }

  @override
  void refresh() => _loadPlaylists();

  @override
  void manualRefresh() => _loadPlaylists(showLoadingIndicator: true);

  @override
  void fullRefresh() => _loadPlaylists(showLoadingIndicator: true);

  @override
  void focusActiveTabIfReady() {
    if (_firstItemFocusNode.canRequestFocus) {
      _firstItemFocusNode.requestFocus();
    }
  }

  Future<void> _loadPlaylists({bool showLoadingIndicator = false}) async {
    if (!mounted) return;
    if (showLoadingIndicator) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final profileId = context.read<ActiveProfileProvider>().activeId ?? '';
      final db = context.read<AppDatabase>();
      final multiServer = context.read<MultiServerProvider>();
      final custom = await db.getCustomPlaylists(profileId: profileId);

      final onlineIds = List<String>.from(multiServer.onlineServerIds);
      final serverNames = <String, String>{};
      final serverBackends = <String, MediaBackend>{};

      for (final serverId in onlineIds) {
        final client = multiServer.getClientForServer(ServerId(serverId));
        if (client == null) continue;
        serverNames[serverId] = multiServer.serverManager.serverDisplayName(ServerId(serverId));
        serverBackends[serverId] = client.backend;
      }

      if (!mounted) return;
      setState(() {
        _customPlaylists = custom;
        _onlineServerIds = onlineIds;
        _serverNames = serverNames;
        _serverBackends = serverBackends;
        _isLoading = false;
        _errorMessage = null;
      });

      // Refresh any server that was already expanded by the user
      for (final serverId in _expandedServers) {
        if (onlineIds.contains(serverId)) {
          unawaited(_fetchServerPlaylists(serverId));
        }
      }
    } catch (e, stack) {
      appLogger.e('Failed to load playlists: $e', error: e, stackTrace: stack);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = t.playlists.errorLoading;
      });
    }
  }

  void _toggleServerExpanded(String serverId) {
    setState(() {
      if (_expandedServers.contains(serverId)) {
        _expandedServers.remove(serverId);
      } else {
        _expandedServers.add(serverId);
        if (!_serverPlaylistsByServer.containsKey(serverId) && !_loadingServers.contains(serverId)) {
          unawaited(_fetchServerPlaylists(serverId));
        }
      }
    });
  }

  Future<void> _fetchServerPlaylists(String serverId) async {
    final multiServer = context.read<MultiServerProvider>();
    final client = multiServer.getClientForServer(ServerId(serverId));
    if (client == null) return;

    setState(() {
      _loadingServers.add(serverId);
      _serverErrors[serverId] = null;
    });

    final sName = _serverNames[serverId] ?? serverId;
    final playlists = <MediaPlaylist>[];
    final seenIds = <String>{};

    try {
      try {
        final page = await client.fetchPlaylistsPage(playlistType: '', size: 200);
        for (final item in page.items) {
          if (seenIds.add(item.id)) {
            playlists.add(item.copyWith(serverId: serverId, serverName: sName));
          }
        }
      } catch (e) {
        appLogger.d('PlaylistsScreen: fetchPlaylistsPage(type: "") failed for $sName: $e');
      }

      if (playlists.isEmpty) {
        for (final type in ['video', 'audio']) {
          try {
            final page = await client.fetchPlaylistsPage(playlistType: type, size: 200);
            for (final item in page.items) {
              if (seenIds.add(item.id)) {
                playlists.add(item.copyWith(serverId: serverId, serverName: sName));
              }
            }
          } catch (e) {
            appLogger.d('PlaylistsScreen: fetchPlaylistsPage(type: "$type") failed for $sName: $e');
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _serverPlaylistsByServer[serverId] = playlists;
        _loadingServers.remove(serverId);
        _serverErrors[serverId] = null;
      });
    } catch (e, stack) {
      appLogger.e('Failed to fetch server playlists: $e', error: e, stackTrace: stack);
      if (!mounted) return;
      setState(() {
        _loadingServers.remove(serverId);
        _serverErrors[serverId] = t.playlists.errorLoading;
      });
    }
  }

  Future<void> _createCustomPlaylist() async {
    final result = await showCreateCustomPlaylistDialog(context);
    if (result == null || !mounted) return;

    try {
      final profileId = context.read<ActiveProfileProvider>().activeId ?? '';
      final db = context.read<AppDatabase>();
      await db.createCustomPlaylist(
        profileId: profileId,
        title: result.name,
        playlistType: result.type,
      );
      if (!mounted) return;
      showSuccessSnackBar(context, t.playlists.created);
      LibraryRefreshNotifier().notifyPlaylistsChanged();
      await _loadPlaylists();
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, t.playlists.errorCreating);
    }
  }

  int get _density => SettingsService.instance.read(SettingsService.libraryDensity);

  @override
  Widget build(BuildContext context) {
    final isEmpty = _customPlaylists.isEmpty && _onlineServerIds.isEmpty;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          DesktopSliverAppBar(
            title: Text(t.playlists.title),
            pinned: false,
            floating: true,
            snap: true,
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            scrolledUnderElevation: 0,
            actions: [
              FocusableActionBar(
                key: _actionBarKey,
                onNavigateDown: _firstItemFocusNode.requestFocus,
                actions: [
                  FocusableAction(
                    icon: Symbols.add_rounded,
                    tooltip: t.playlists.createCustomPlaylist,
                    onPressed: _createCustomPlaylist,
                  ),
                  FocusableAction(
                    icon: Symbols.refresh_rounded,
                    tooltip: t.common.refresh,
                    onPressed: manualRefresh,
                  ),
                ],
              ),
            ],
          ),

          if (_isLoading && isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: LoadingIndicatorBox()),
            )
          else if (_errorMessage != null && isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: StateMessageWidget(
                icon: Symbols.error_outline_rounded,
                message: _errorMessage!,
                actionLabel: t.common.retry,
                onAction: manualRefresh,
              ),
            )
          else if (isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: StateMessageWidget(
                icon: Symbols.playlist_play_rounded,
                message: t.playlists.noPlaylists,
                subtitle: t.playlists.createCustomPlaylist,
                actionLabel: t.playlists.createCustomPlaylist,
                actionIcon: Symbols.add_rounded,
                onAction: _createCustomPlaylist,
              ),
            )
          else ...[
            // ----------------------------------------------------
            // Section 1: Custom Playlists
            // ----------------------------------------------------
            SliverToBoxAdapter(
              child: _buildSectionHeader(
                context,
                icon: Symbols.playlist_play_rounded,
                title: t.playlists.customPlaylists,
                count: _customPlaylists.length,
                trailing: TextButton.icon(
                  onPressed: _createCustomPlaylist,
                  icon: const AppIcon(Symbols.add_rounded, size: 18),
                  label: Text(t.playlists.createCustomPlaylist),
                ),
              ),
            ),
            if (_customPlaylists.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(tokens(context).radiusMd),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        AppIcon(
                          Symbols.info_rounded,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            t.playlists.emptyPlaylist,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: _createCustomPlaylist,
                          icon: const AppIcon(Symbols.add_rounded, size: 16),
                          label: Text(t.playlists.create),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              MediaCardSliverLayout(
                viewMode: ViewMode.grid,
                density: _density,
                shape: CardShape.square,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: _customPlaylists.length,
                itemBuilder: (context, position) {
                  final index = position.index;
                  final item = _customPlaylists[index];
                  return FocusableMediaCard(
                    key: Key(item.globalKey),
                    item: item,
                    focusNode: index == 0 ? _firstItemFocusNode : null,
                    cardShapeOverride: CardShape.square,
                    disableScale: position.disableScale,
                    onListRefresh: _loadPlaylists,
                  );
                },
              ),

            // ----------------------------------------------------
            // Section 2: Server Playlists (Grouped per Server)
            // ----------------------------------------------------
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
            SliverToBoxAdapter(
              child: _buildSectionHeader(
                context,
                icon: Symbols.dns_rounded,
                title: t.playlists.serverPlaylists,
                count: _onlineServerIds.length,
              ),
            ),

            if (_onlineServerIds.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    t.playlists.noPlaylists,
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              )
            else
              for (final serverId in _onlineServerIds) ...[
                SliverToBoxAdapter(
                  child: _buildServerSubheader(
                    context,
                    serverId: serverId,
                    serverName: _serverNames[serverId] ?? serverId,
                    backend: _serverBackends[serverId] ?? MediaBackend.plex,
                    isExpanded: _expandedServers.contains(serverId),
                    isLoading: _loadingServers.contains(serverId),
                    count: _serverPlaylistsByServer[serverId]?.length,
                  ),
                ),
                if (_expandedServers.contains(serverId)) ...[
                  if (_loadingServers.contains(serverId))
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          ),
                        ),
                      ),
                    )
                  else if (_serverErrors[serverId] != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 8, 16, 16),
                        child: Row(
                          children: [
                            AppIcon(Symbols.error_rounded, size: 18, color: Theme.of(context).colorScheme.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _serverErrors[serverId]!,
                                style: TextStyle(color: Theme.of(context).colorScheme.error),
                              ),
                            ),
                            const SizedBox(width: 12),
                            TextButton(
                              onPressed: () => _fetchServerPlaylists(serverId),
                              child: Text(t.common.retry),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if ((_serverPlaylistsByServer[serverId] ?? const []).isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(28, 4, 16, 16),
                        child: Text(
                          t.playlists.noPlaylists,
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodySmall?.color?.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    )
                  else
                    MediaCardSliverLayout(
                      viewMode: ViewMode.grid,
                      density: _density,
                      shape: CardShape.square,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: _serverPlaylistsByServer[serverId]!.length,
                      itemBuilder: (context, position) {
                        final item = _serverPlaylistsByServer[serverId]![position.index];
                        return FocusableMediaCard(
                          key: Key(item.globalKey),
                          item: item,
                          cardShapeOverride: CardShape.square,
                          disableScale: position.disableScale,
                          onListRefresh: () => _fetchServerPlaylists(serverId),
                        );
                      },
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                ],
              ],

            const SliverToBoxAdapter(child: SizedBox(height: 36)),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context, {
    required IconData icon,
    required String title,
    int? count,
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          AppIcon(icon, size: 22, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              letterSpacing: 0.2,
            ),
          ),
          if (count != null && count > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }

  Widget _buildServerSubheader(
    BuildContext context, {
    required String serverId,
    required String serverName,
    required MediaBackend backend,
    required bool isExpanded,
    required bool isLoading,
    int? count,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _toggleServerExpanded(serverId),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                BackendBadge(backend: backend, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    serverName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
                if (isLoading) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ] else if (count != null) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$count',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                AppIcon(
                  isExpanded ? Symbols.expand_less_rounded : Symbols.expand_more_rounded,
                  size: 22,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
