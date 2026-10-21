import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../database/app_database.dart';
import '../database/custom_playlist_operations.dart';
import '../focus/focusable_text_field.dart';
import '../focus/key_event_utils.dart';
import '../i18n/strings.g.dart';
import '../media/library_query.dart';
import '../media/media_item.dart';
import '../media/media_playlist.dart';
import '../media/media_server_client.dart';
import '../profiles/active_profile_provider.dart';
import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart';
import 'app_icon.dart';
import 'dialog_action_button.dart';
import 'focusable_list_tile.dart';
import 'pill_input_decoration.dart';
import 'scroll_ink_boundary.dart';

typedef _PickerPageLoader<T> = Future<LibraryPage<T>> Function(int start, int size, AbortController abort);

typedef _PickerItemBuilder<T> = Widget Function(BuildContext context, T item);

/// Shared loading, filtering, and TV focus shell for collection-style pickers.
class _PickerDialogScaffold<T> extends StatefulWidget {
  final String title;
  final String searchHint;
  final String emptyMessage;
  final _PickerPageLoader<T> loadPage;
  final String Function(T item) itemTitle;
  final _PickerItemBuilder<T> itemBuilder;

  const _PickerDialogScaffold({
    required this.title,
    required this.searchHint,
    required this.emptyMessage,
    required this.loadPage,
    required this.itemTitle,
    required this.itemBuilder,
  });

  @override
  State<_PickerDialogScaffold<T>> createState() => _PickerDialogScaffoldState<T>();
}

class _PickerDialogScaffoldState<T> extends State<_PickerDialogScaffold<T>> {
  static const int _pageSize = 100;
  static const int _filterThreshold = 10;

  final _filterController = TextEditingController();
  final _filterFocusNode = FocusNode(debugLabel: 'PickerFilter');
  final _firstItemFocusNode = FocusNode(debugLabel: 'PickerFirstItem');
  final _abortController = AbortController();
  final _scrollController = ScrollController();
  final List<T> _items = [];
  List<T> _filteredItems = [];
  bool _isLoading = false;
  bool _initialFocusRequested = false;
  String? _errorMessage;
  int? _totalCount;

  bool get _hasMore => _totalCount == null || _items.length < _totalCount!;
  bool get _showFilter => _items.length >= _filterThreshold;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_loadNextPage());
  }

  @override
  void dispose() {
    _abortController.abort();
    _scrollController.dispose();
    _filterController.dispose();
    _filterFocusNode.dispose();
    _firstItemFocusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || !_hasMore || _isLoading) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 240) {
      unawaited(_loadNextPage());
    }
  }

  Future<void> _loadNextPage() async {
    if (_isLoading || !_hasMore) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      while (mounted && _hasMore) {
        final page = await widget.loadPage(_items.length, _pageSize, _abortController);
        if (!mounted) return;
        setState(() {
          _items.addAll(page.items);
          _totalCount = page.totalCount;
          _applyFilter(_filterController.text);
        });
        if (_filterController.text.isEmpty || page.items.isEmpty) break;
      }
      if (!mounted) return;
      setState(() => _isLoading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
    _requestInitialFocus();
  }

  void _requestInitialFocus() {
    if (_initialFocusRequested) return;
    _initialFocusRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (_showFilter ? _filterFocusNode : _firstItemFocusNode).requestFocus();
    });
  }

  void _onFilterChanged(String query) {
    setState(() => _applyFilter(query));
    if (query.isNotEmpty && _hasMore) {
      unawaited(_loadNextPage());
    }
  }

  void _applyFilter(String query) {
    final lower = query.toLowerCase();
    _filteredItems = lower.isEmpty
        ? List.of(_items)
        : _items.where((item) => widget.itemTitle(item).toLowerCase().contains(lower)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final showStatus = _hasMore || _isLoading || _errorMessage != null || _filteredItems.isEmpty;
    return Focus(
      onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
      child: AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: .min,
            children: [
              if (_showFilter) ...[
                FocusableTextField(
                  controller: _filterController,
                  focusNode: _filterFocusNode,
                  tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
                  tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.afterFirstFocus,
                  onNavigateDown: _firstItemFocusNode.requestFocus,
                  decoration: pillInputDecoration(
                    context,
                    hintText: widget.searchHint,
                    prefixIcon: const AppIcon(Symbols.search_rounded, size: 20),
                  ),
                  onChanged: _onFilterChanged,
                ),
                const SizedBox(height: 8),
              ],
              Flexible(
                child: ScrollInkBoundary(
                  child: ListView.builder(
                    controller: _scrollController,
                    shrinkWrap: true,
                    itemCount: _filteredItems.length + 1 + (showStatus ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return FocusableListTile(
                          focusNode: _firstItemFocusNode,
                          leading: const AppIcon(Symbols.add_rounded, fill: 1),
                          title: Text(t.common.createNew),
                          onTap: () => Navigator.pop(context, '_create_new'),
                        );
                      }

                      if (index <= _filteredItems.length) {
                        return widget.itemBuilder(context, _filteredItems[index - 1]);
                      }

                      if (_errorMessage != null) {
                        return FocusableListTile(
                          leading: const AppIcon(Symbols.error_rounded, fill: 1),
                          title: Text(t.messages.errorLoading(error: _errorMessage!)),
                          onTap: _loadNextPage,
                        );
                      }
                      if (_hasMore || _isLoading) {
                        if (_hasMore && !_isLoading) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) unawaited(_loadNextPage());
                          });
                        }
                        return const Padding(
                          padding: .all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      return Padding(
                        padding: const .all(16),
                        child: Text(widget.emptyMessage, textAlign: TextAlign.center),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [DialogActionButton(onPressed: () => Navigator.pop(context), label: t.common.cancel)],
      ),
    );
  }
}

/// Dialog to select a playlist or create a new one.
/// Supports both local cross-server Custom Playlists and remote Server Playlists.
class PlaylistSelectionDialog extends StatefulWidget {
  final MediaServerClient? client;
  final MediaItem? item;

  const PlaylistSelectionDialog({super.key, this.client, this.item});

  @override
  State<PlaylistSelectionDialog> createState() => _PlaylistSelectionDialogState();
}

class _PlaylistSelectionDialogState extends State<PlaylistSelectionDialog> {
  static const int _pageSize = 100;
  static const int _filterThreshold = 5;

  final _filterController = TextEditingController();
  final _filterFocusNode = FocusNode(debugLabel: 'PlaylistPickerFilter');
  final _firstItemFocusNode = FocusNode(debugLabel: 'PlaylistPickerFirstItem');
  final _abortController = AbortController();
  final _scrollController = ScrollController();

  List<MediaPlaylist> _customPlaylists = [];
  List<MediaPlaylist> _filteredCustomPlaylists = [];
  bool _isLoadingCustom = false;

  final List<MediaPlaylist> _serverPlaylists = [];
  List<MediaPlaylist> _filteredServerPlaylists = [];
  bool _isLoadingServer = false;
  bool _serverInitialPageLoaded = false;
  String? _serverErrorMessage;
  int? _serverTotalCount;

  bool _initialFocusRequested = false;

  String get _playlistType => (widget.item?.kind.isMusic ?? false) ? 'audio' : 'video';
  bool get _hasMoreServer =>
      widget.client != null && (_serverTotalCount == null || _serverPlaylists.length < _serverTotalCount!);
  int get _totalItemCount => _customPlaylists.length + _serverPlaylists.length;
  bool get _showFilter => _totalItemCount >= _filterThreshold;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_loadCustomPlaylists());
    if (widget.client != null) {
      unawaited(_loadNextServerPage());
    }
  }

  @override
  void dispose() {
    _abortController.abort();
    _scrollController.dispose();
    _filterController.dispose();
    _filterFocusNode.dispose();
    _firstItemFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadCustomPlaylists() async {
    final db = Provider.of<AppDatabase?>(context, listen: false);
    if (db == null) {
      _requestInitialFocus();
      return;
    }
    setState(() => _isLoadingCustom = true);
    try {
      final activeProfile = Provider.of<ActiveProfileProvider?>(context, listen: false);
      final profileId = activeProfile?.activeId ?? '';
      final list = await db.getCustomPlaylists(profileId: profileId, playlistType: _playlistType);
      if (!mounted) return;
      setState(() {
        _customPlaylists = list;
        _isLoadingCustom = false;
        _applyFilter(_filterController.text);
      });
    } catch (e, st) {
      appLogger.e('Failed to load custom playlists', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() => _isLoadingCustom = false);
    }
    _requestInitialFocus();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || !_hasMoreServer || _isLoadingServer) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 240) {
      unawaited(_loadNextServerPage());
    }
  }

  Future<void> _loadNextServerPage() async {
    final client = widget.client;
    if (client == null || _isLoadingServer || !_hasMoreServer) return;
    setState(() {
      _isLoadingServer = true;
      _serverErrorMessage = null;
    });
    try {
      while (mounted && _hasMoreServer) {
        final page = await client.fetchPlaylistsPage(
          playlistType: _playlistType,
          smart: false,
          start: _serverPlaylists.length,
          size: _pageSize,
          abort: _abortController,
        );
        if (!mounted) return;
        setState(() {
          _serverPlaylists.addAll(page.items);
          _serverTotalCount = page.totalCount;
          _applyFilter(_filterController.text);
        });
        if (_filterController.text.isEmpty || page.items.isEmpty) break;
      }
      if (!mounted) return;
      setState(() {
        _serverInitialPageLoaded = true;
        _isLoadingServer = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _serverInitialPageLoaded = true;
        _serverErrorMessage = e.toString();
        _isLoadingServer = false;
      });
    }
    _requestInitialFocus();
  }

  void _onFilterChanged(String query) {
    setState(() => _applyFilter(query));
    if (query.isNotEmpty && _hasMoreServer) {
      unawaited(_loadNextServerPage());
    }
  }

  void _requestInitialFocus() {
    if (_initialFocusRequested) return;
    if (_isLoadingCustom) return;
    if (widget.client != null && !_serverInitialPageLoaded) return;
    _initialFocusRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (_showFilter ? _filterFocusNode : _firstItemFocusNode).requestFocus();
    });
  }

  void _applyFilter(String query) {
    final lower = query.toLowerCase();
    _filteredCustomPlaylists = lower.isEmpty
        ? List.of(_customPlaylists)
        : _customPlaylists.where((p) => p.title.toLowerCase().contains(lower)).toList();
    _filteredServerPlaylists = lower.isEmpty
        ? List.of(_serverPlaylists)
        : _serverPlaylists.where((p) => p.title.toLowerCase().contains(lower)).toList();
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.bold),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasCustom = Provider.of<AppDatabase?>(context, listen: false) != null;
    final hasServer = widget.client != null;
    return Focus(
      onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
      child: AlertDialog(
        title: Text(t.playlists.selectPlaylist),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showFilter) ...[
                FocusableTextField(
                  controller: _filterController,
                  focusNode: _filterFocusNode,
                  tvTextInputPresentation: TvTextInputPresentation.flutterOverlay,
                  tvTextInputAutoOpenBehavior: TvTextInputAutoOpenBehavior.afterFirstFocus,
                  onNavigateDown: _firstItemFocusNode.requestFocus,
                  decoration: pillInputDecoration(
                    context,
                    hintText: t.playlists.searchPlaylists,
                    prefixIcon: const AppIcon(Symbols.search_rounded, size: 20),
                  ),
                  onChanged: _onFilterChanged,
                ),
                const SizedBox(height: 8),
              ],
              Flexible(
                child: ScrollInkBoundary(
                  child: ListView(
                    controller: _scrollController,
                    shrinkWrap: true,
                    children: [
                      // Section 1: Custom Playlists
                      if (hasCustom) ...[
                        _buildSectionHeader(context, t.playlists.customPlaylists),
                        FocusableListTile(
                          focusNode: _firstItemFocusNode,
                          leading: const AppIcon(Symbols.add_rounded, fill: 1),
                          title: Text(t.playlists.createCustomPlaylist),
                          onTap: () => Navigator.pop(context, '_create_custom'),
                        ),
                        for (final playlist in _filteredCustomPlaylists) ...[
                          FocusableListTile(
                            leading: const AppIcon(Symbols.playlist_play_rounded, fill: 1),
                            title: Text(playlist.title),
                            subtitle: playlist.leafCount != null
                                ? Text(
                                    playlist.leafCount == 1
                                        ? t.playlists.oneItem
                                        : t.playlists.itemCount(count: playlist.leafCount!),
                                  )
                                : null,
                            onTap: () => Navigator.pop(context, 'custom:${playlist.id}'),
                          ),
                        ],
                        if (_isLoadingCustom)
                          const Padding(
                            padding: EdgeInsets.all(8),
                            child: Center(
                              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                            ),
                          ),
                      ],

                      // Section 2: Server Playlists
                      if (hasServer) ...[
                        if (hasCustom) ...[
                          const SizedBox(height: 8),
                          _buildSectionHeader(context, t.playlists.serverPlaylists),
                        ],
                        FocusableListTile(
                          focusNode: hasCustom ? null : _firstItemFocusNode,
                          leading: const AppIcon(Symbols.add_rounded, fill: 1),
                          title: Text(hasCustom ? t.playlists.createServerPlaylist : t.common.createNew),
                          onTap: () => Navigator.pop(context, '_create_server'),
                        ),
                        for (final playlist in _filteredServerPlaylists) ...[
                          FocusableListTile(
                            leading: playlist.smart
                                ? const AppIcon(Symbols.auto_awesome_rounded, fill: 1)
                                : const AppIcon(Symbols.playlist_play_rounded, fill: 1),
                            title: Text(playlist.title),
                            subtitle: playlist.leafCount != null
                                ? Text(
                                    playlist.leafCount == 1
                                        ? t.playlists.oneItem
                                        : t.playlists.itemCount(count: playlist.leafCount!),
                                  )
                                : null,
                            onTap: playlist.smart ? null : () => Navigator.pop(context, playlist.id),
                            enabled: !playlist.smart,
                          ),
                        ],
                        if (_serverErrorMessage != null)
                          FocusableListTile(
                            leading: const AppIcon(Symbols.error_rounded, fill: 1),
                            title: Text(t.messages.errorLoading(error: _serverErrorMessage!)),
                            onTap: _loadNextServerPage,
                          ),
                        if (_isLoadingServer)
                          const Padding(
                            padding: EdgeInsets.all(8),
                            child: Center(
                              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [DialogActionButton(onPressed: () => Navigator.pop(context), label: t.common.cancel)],
      ),
    );
  }
}

/// Dialog to select a collection or create a new one
class CollectionSelectionDialog extends StatelessWidget {
  final MediaServerClient client;
  final String libraryId;

  const CollectionSelectionDialog({super.key, required this.client, required this.libraryId});

  @override
  Widget build(BuildContext context) {
    return _PickerDialogScaffold<MediaItem>(
      title: t.collections.selectCollection,
      searchHint: t.collections.searchCollections,
      emptyMessage: t.libraries.noCollections,
      loadPage: (start, size, abort) => client.fetchCollectionsPage(libraryId, start: start, size: size, abort: abort),
      itemTitle: (collection) => collection.title ?? '',
      itemBuilder: (context, collection) => FocusableListTile(
        leading: const AppIcon(Symbols.collections_rounded, fill: 1),
        title: Text(collection.title ?? ''),
        subtitle: collection.childCount != null ? Text(t.playlists.itemCount(count: collection.childCount!)) : null,
        onTap: () => Navigator.pop(context, collection.id),
      ),
    );
  }
}
