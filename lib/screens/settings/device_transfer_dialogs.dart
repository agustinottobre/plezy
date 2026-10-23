import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../connection/connection_registry.dart';
import '../../database/app_database.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/plex_home_service.dart';
import '../../profiles/profile_connection_registry.dart';
import '../../profiles/profile_registry.dart';
import '../../services/device_transfer_service.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/app_logger.dart';
import '../../utils/platform_detector.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/dialog_action_button.dart';
import '../../widgets/loading_indicator_box.dart';

double _radiusMd(BuildContext context) => Theme.of(context).extension<MonoTokens>()?.radiusMd ?? 12.0;

enum _ReceiveState { waiting, applying, success, error }

/// Dialog shown on the receiver device (e.g. TV or fresh device).
/// Runs an ephemeral HTTP server on LAN, renders a QR code and 6-digit PIN,
/// and applies incoming configuration upon receipt.
class ReceiveSetupDialog extends StatefulWidget {
  const ReceiveSetupDialog({super.key, this.onSetupCompleted});

  final FutureOr<void> Function()? onSetupCompleted;

  @override
  State<ReceiveSetupDialog> createState() => _ReceiveSetupDialogState();
}

class _ReceiveSetupDialogState extends State<ReceiveSetupDialog> {
  late final String _pin;
  DeviceTransferReceiver? _receiver;
  List<String> _localIps = [];
  int _port = 0;
  _ReceiveState _state = _ReceiveState.waiting;
  String _statusMessage = '';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _pin = DeviceTransferService.generatePin();
    _initReceiver();
  }

  Future<void> _initReceiver() async {
    final ips = await DeviceTransferService.getLocalIpAddresses();
    if (!mounted) return;

    final receiver = DeviceTransferReceiver(pin: _pin, onPayloadReceived: _handlePayload);

    try {
      final port = await receiver.start();
      if (!mounted) {
        await receiver.stop();
        return;
      }
      setState(() {
        _receiver = receiver;
        _port = port;
        _localIps = ips;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _ReceiveState.error;
        _errorMessage = t.deviceTransfer.receiveError(error: e);
      });
    }
  }

  Future<void> _handlePayload(Map<String, dynamic> payload) async {
    if (!mounted) return;
    setState(() {
      _state = _ReceiveState.applying;
      _statusMessage = t.deviceTransfer.applyingReceivedSetup;
    });

    try {
      final connections = context.read<ConnectionRegistry>();
      final profileConnections = context.read<ProfileConnectionRegistry>();
      final plexHome = context.read<PlexHomeService>();
      final activeProfiles = context.read<ActiveProfileProvider>();
      ProfileRegistry? profileRegistry;
      try {
        profileRegistry = context.read<ProfileRegistry>();
      } catch (_) {}
      ActiveProfileBinder? activeBinder;
      try {
        activeBinder = context.read<ActiveProfileBinder>();
      } catch (_) {}
      AppDatabase? database;
      try {
        database = context.read<AppDatabase>();
      } catch (_) {}

      final result = await DeviceTransferService.applyPayload(
        payload,
        connections: connections,
        profileConnections: profileConnections,
        plexHome: plexHome,
        profileRegistry: profileRegistry,
        activeProfiles: activeProfiles,
        activeBinder: activeBinder,
        database: database,
      );

      if (!mounted) return;
      setState(() {
        _state = _ReceiveState.success;
        final parts = <String>[];
        parts.add(t.deviceTransfer.serversCount(count: result.connectionsImported));
        if (result.playlistsImported > 0) {
          parts.add(t.deviceTransfer.playlistsCount(count: result.playlistsImported));
        }
        parts.add(t.deviceTransfer.settingsCount(count: result.settingsImported));
        _statusMessage = t.deviceTransfer.transferredSummary(summary: parts.join(', '));
      });

      await Future<void>.delayed(const Duration(milliseconds: 1000));
      if (!mounted) return;

      if (widget.onSetupCompleted != null) {
        await widget.onSetupCompleted!();
      }
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e, st) {
      appLogger.e('ReceiveSetupDialog: failed to apply payload', error: e, stackTrace: st);
      if (!mounted) return;
      setState(() {
        _state = _ReceiveState.error;
        _errorMessage = t.deviceTransfer.applyError(error: e);
      });
    }
  }

  @override
  void dispose() {
    unawaited(_receiver?.stop());
    super.dispose();
  }

  String get _primaryIp => _localIps.isNotEmpty ? _localIps.first : '127.0.0.1';

  String get _qrUrl {
    final salt = _receiver?.salt;
    final saltParam = salt != null ? '&salt=${base64Url.encode(salt)}' : '';
    return 'http://$_primaryIp:$_port/?pin=$_pin$saltParam';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final screenSize = MediaQuery.sizeOf(context);
    final isTV = PlatformDetector.isTV();
    final isWide = isTV || screenSize.width >= 560;

    final dialogWidth = isWide
        ? (isTV ? 520.0 : (screenSize.width * 0.85).clamp(460.0, 520.0))
        : (screenSize.width - 40).clamp(280.0, 360.0);

    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          Icon(Symbols.phonelink_setup_rounded, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(t.deviceTransfer.receiveTitle)),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        child: switch (_state) {
          _ReceiveState.waiting => _buildWaitingContent(scheme, isWide),
          _ReceiveState.applying => _buildApplyingContent(scheme),
          _ReceiveState.success => _buildSuccessContent(scheme),
          _ReceiveState.error => _buildErrorContent(scheme),
        },
      ),
      actions: [
        DialogActionButton(
          label: _state == _ReceiveState.success ? t.common.close : t.common.cancel,
          isPrimary: _state == _ReceiveState.success,
          onPressed: () => Navigator.of(context).pop(_state == _ReceiveState.success),
        ),
      ],
    );
  }

  Widget _buildWaitingContent(ColorScheme scheme, bool isWide) {
    if (_receiver == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: LoadingIndicatorBox(size: 32)),
      );
    }

    final theme = Theme.of(context);
    final formattedPin = _pin.length == 6 ? '${_pin.substring(0, 3)}  ${_pin.substring(3)}' : _pin;

    Widget qrWidget(double size) => SizedBox.square(
      dimension: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_radiusMd(context)),
        child: QrImageView(
          data: _qrUrl,
          size: size,
          version: QrVersions.auto,
          backgroundColor: Colors.white,
        ),
      ),
    );

    final urlWidget = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Text(
        'http://$_primaryIp:$_port',
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
          fontFamily: 'monospace',
        ),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );

    Widget pinBox({bool compact = false}) => Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 16 : 20,
        vertical: compact ? 8 : 12,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(_radiusMd(context)),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            t.deviceTransfer.pinCode,
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.5,
              color: scheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              formattedPin,
              style: (compact ? theme.textTheme.headlineSmall : theme.textTheme.headlineMedium)?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 4,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );

    Widget waitingRow({bool center = false}) => Row(
      mainAxisAlignment: center ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        const LoadingIndicatorBox(size: 14),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            t.deviceTransfer.waitingForIncoming,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );

    if (isWide) {
      const qrSize = 160.0;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              qrWidget(qrSize),
              const SizedBox(height: 8),
              urlWidget,
            ],
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  t.deviceTransfer.receiveInstructions,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 12),
                pinBox(compact: false),
                const SizedBox(height: 12),
                waitingRow(center: false),
              ],
            ),
          ),
        ],
      );
    }

    const qrSize = 145.0;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            t.deviceTransfer.receiveInstructions,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          qrWidget(qrSize),
          const SizedBox(height: 6),
          urlWidget,
          const SizedBox(height: 12),
          pinBox(compact: true),
          const SizedBox(height: 12),
          waitingRow(center: true),
        ],
      ),
    );
  }

  Widget _buildApplyingContent(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LoadingIndicatorBox(size: 36),
          const SizedBox(height: 16),
          Text(_statusMessage, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildSuccessContent(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.check_circle_rounded, size: 48, color: scheme.primary),
          const SizedBox(height: 12),
          Text(
            t.deviceTransfer.setupTransferredTitle,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(_statusMessage, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildErrorContent(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.error_rounded, size: 48, color: scheme.error),
          const SizedBox(height: 12),
          Text(
            _errorMessage ?? t.deviceTransfer.generalError,
            style: TextStyle(color: scheme.error),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Dialog shown on the source device to send its current setup to a target device.
class SendSetupDialog extends StatefulWidget {
  const SendSetupDialog({super.key, this.initialAddress, this.initialPin});

  final String? initialAddress;
  final String? initialPin;

  @override
  State<SendSetupDialog> createState() => _SendSetupDialogState();
}

class _SendSetupDialogState extends State<SendSetupDialog> {
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: DeviceTransferReceiver.defaultHttpPort.toString());
  final _pinController = TextEditingController();

  final DeviceTransferDiscovery _discovery = DeviceTransferDiscovery();
  final List<DiscoveredTargetDevice> _discoveredDevices = [];
  DiscoveredTargetDevice? _selectedDevice;
  bool _showManualAddress = false;

  bool _includeSettings = true;
  bool _includeConnections = true;
  bool _isSending = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.initialAddress != null) {
      _showManualAddress = true;
      _parseAddress(widget.initialAddress!);
    }
    if (widget.initialPin != null) {
      _pinController.text = widget.initialPin!;
    }
    _startDiscovery();
  }

  void _startDiscovery() {
    _discovery.onDeviceDiscovered.listen((device) {
      if (!mounted) return;
      setState(() {
        if (!_discoveredDevices.contains(device)) {
          _discoveredDevices.add(device);
        }
        if (_selectedDevice == null && _discoveredDevices.isNotEmpty) {
          _selectDevice(_discoveredDevices.first);
        }
      });
    });
    unawaited(_discovery.start());
  }

  void _selectDevice(DiscoveredTargetDevice device) {
    setState(() {
      _selectedDevice = device;
      _ipController.text = device.ip;
      _portController.text = device.port.toString();
    });
  }

  void _parseAddress(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null) {
        if (uri.host.isNotEmpty) {
          _ipController.text = uri.host;
          _ipController.selection = TextSelection.collapsed(offset: uri.host.length);
        }
        if (uri.hasPort) _portController.text = uri.port.toString();
        final urlPin = uri.queryParameters['pin'];
        if (urlPin != null && urlPin.isNotEmpty) {
          _pinController.text = urlPin;
        }
        return;
      }
    }
    if (trimmed.contains(':')) {
      final parts = trimmed.split(':');
      final host = parts[0].trim();
      _ipController.text = host;
      _ipController.selection = TextSelection.collapsed(offset: host.length);
      if (parts.length > 1 && int.tryParse(parts[1].trim()) != null) {
        _portController.text = parts[1].trim();
      }
    }
  }

  @override
  void dispose() {
    unawaited(_discovery.stop());
    _ipController.dispose();
    _portController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    final ip = _ipController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final pin = _pinController.text.trim().replaceAll(' ', '');

    if (ip.isEmpty) {
      setState(() => _errorMessage = t.deviceTransfer.validationSelectTarget);
      return;
    }
    if (port == null || port <= 0 || port > 65535) {
      setState(() => _errorMessage = t.deviceTransfer.validationValidPort);
      return;
    }
    if (pin.length != 6) {
      setState(() => _errorMessage = t.deviceTransfer.validationEnterPin);
      return;
    }
    if (!_includeSettings && !_includeConnections) {
      setState(() => _errorMessage = t.deviceTransfer.validationSelectItems);
      return;
    }

    setState(() {
      _isSending = true;
      _errorMessage = null;
    });

    try {
      final connections = context.read<ConnectionRegistry>();
      ProfileConnectionRegistry? profileConnections;
      try {
        profileConnections = context.read<ProfileConnectionRegistry>();
      } catch (_) {}
      ProfileRegistry? profiles;
      try {
        profiles = context.read<ProfileRegistry>();
      } catch (_) {}
      ActiveProfileProvider? activeProfiles;
      try {
        activeProfiles = context.read<ActiveProfileProvider>();
      } catch (_) {}
      AppDatabase? database;
      try {
        database = context.read<AppDatabase>();
      } catch (_) {}

      final payload = await DeviceTransferService.buildPayload(
        includeSettings: _includeSettings,
        includeConnections: _includeConnections,
        connections: connections,
        profileConnections: profileConnections,
        profiles: profiles,
        activeProfiles: activeProfiles,
        database: database,
      );

      await DeviceTransferSender.send(targetIp: ip, targetPort: port, pin: pin, payload: payload);

      if (!mounted) return;
      Navigator.of(context).pop(true);
      final targetLabel = _selectedDevice?.name ?? ip;
      showSuccessSnackBar(context, t.deviceTransfer.setupDeliveredSuccess(device: targetLabel));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSending = false;
        _errorMessage = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final screenSize = MediaQuery.sizeOf(context);
    final dialogWidth = (screenSize.width - 40).clamp(280.0, 420.0);

    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          Icon(Symbols.send_rounded, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(t.deviceTransfer.sendTitle)),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTargetDeviceSection(scheme),
              const SizedBox(height: 16),
              FocusableTextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: _selectedDevice != null
                      ? t.deviceTransfer.pinLabelDevice(device: _selectedDevice!.name)
                      : t.deviceTransfer.pinLabel,
                  hintText: t.deviceTransfer.pinHint,
                  isDense: true,
                  counterText: '',
                  prefixIcon: const Icon(Symbols.lock_rounded, size: 20),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                t.deviceTransfer.includeInTransfer,
                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _includeSettings,
                title: Text(t.deviceTransfer.appAndPlayerSettings),
                subtitle: Text(t.deviceTransfer.appAndPlayerSettingsDescription),
                onChanged: (val) => setState(() => _includeSettings = val ?? true),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _includeConnections,
                title: Text(t.deviceTransfer.serverAccountsAndLogins),
                subtitle: Text(t.deviceTransfer.serverAccountsAndLoginsDescription),
                onChanged: (val) => setState(() => _includeConnections = val ?? true),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(_errorMessage!, style: TextStyle(color: scheme.error, fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        DialogActionButton(label: t.common.cancel, onPressed: _isSending ? null : () => Navigator.of(context).pop()),
        DialogActionButton(
          label: _selectedDevice != null
              ? t.deviceTransfer.sendToDevice(device: _selectedDevice!.name)
              : t.deviceTransfer.sendSetup,
          isPrimary: true,
          icon: _isSending ? const LoadingIndicatorBox(size: 16) : null,
          onPressed: _isSending ? null : _handleSend,
        ),
      ],
    );
  }

  Widget _buildTargetDeviceSection(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t.deviceTransfer.targetDevice,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (_discoveredDevices.isNotEmpty) ...[
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(_radiusMd(context)),
            ),
            child: Column(
              children: _discoveredDevices.map((device) {
                final isSelected = _selectedDevice == device;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    device.isTv ? Symbols.tv_rounded : Symbols.devices_rounded,
                    color: isSelected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                  title: Text(device.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(t.deviceTransfer.readyOnWifi(ip: device.ip)),
                  trailing: isSelected ? Icon(Symbols.check_circle_rounded, color: scheme.primary) : null,
                  tileColor: isSelected ? scheme.primaryContainer.withValues(alpha: 0.3) : null,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radiusMd(context))),
                  onTap: () => _selectDevice(device),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
        ] else if (!_showManualAddress) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(_radiusMd(context)),
              border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                const LoadingIndicatorBox(size: 16),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    t.deviceTransfer.scanningNearbyDevices,
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                ),
                IconButton(
                  icon: const Icon(Symbols.refresh_rounded, size: 18),
                  tooltip: t.common.refresh,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => unawaited(_discovery.rescan()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        // Toggle for manual IP entry
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
            icon: Icon(_showManualAddress ? Symbols.expand_less_rounded : Symbols.tune_rounded, size: 16),
            label: Text(
              _showManualAddress ? t.deviceTransfer.hideManualAddress : t.deviceTransfer.cantFindDevice,
              style: const TextStyle(fontSize: 12),
            ),
            onPressed: () => setState(() => _showManualAddress = !_showManualAddress),
          ),
        ),
        if (_showManualAddress) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: FocusableTextField(
                  controller: _ipController,
                  onChanged: (val) {
                    setState(() => _selectedDevice = null);
                    _parseAddress(val);
                  },
                  decoration: InputDecoration(
                    labelText: t.deviceTransfer.targetIp,
                    hintText: t.deviceTransfer.targetIpHint,
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: FocusableTextField(
                  controller: _portController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t.deviceTransfer.port,
                    hintText: t.deviceTransfer.portHint,
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
