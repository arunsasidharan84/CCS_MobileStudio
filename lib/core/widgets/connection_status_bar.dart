import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../eeg/acquisition_service.dart';
import '../services/nirs_acquisition_service.dart';
import '../services/session_manager.dart';
import '../services/multi_stream_lsl_service.dart';
import '../services/multi_device_acquisition_service.dart';
import '../services/settings_service.dart';

/// Unified connection status bar showing device connection state,
/// active stream name, battery/signal if available, and disconnect/reconnect controls.
class ConnectionStatusBar extends StatelessWidget {
  const ConnectionStatusBar({
    super.key,
    required this.eegState,
    this.nirsState = NirsAcquisitionState.disconnected,
    this.deviceLabel,
    this.onDisconnectEeg,
    this.onDisconnectNirs,
    this.onOpenConnectDialog,
  });

  final AcquisitionState eegState;
  final NirsAcquisitionState? nirsState;
  final String? deviceLabel;
  final VoidCallback? onDisconnectEeg;
  final VoidCallback? onDisconnectNirs;
  final VoidCallback? onOpenConnectDialog;

  @override
  Widget build(BuildContext context) {
    final eegService = context.watch<AcquisitionService>();
    final multiLsl = context.watch<MultiStreamLslService>();
    final multiDevice = context.watch<MultiDeviceAcquisitionService>();
    final secondaryConnected = multiDevice.readySecondaryServices;
    final eegConnected = eegService.isStreamReady;
    final eegConnecting =
        eegState == AcquisitionState.connecting ||
        eegState == AcquisitionState.scanning;
    final nirsStateVal = nirsState ?? NirsAcquisitionState.disconnected;
    final nirsConnected = nirsStateVal == NirsAcquisitionState.connected;
    final nirsConnecting = nirsStateVal == NirsAcquisitionState.resolving;

    final anythingConnected =
        eegConnected ||
        secondaryConnected.isNotEmpty ||
        nirsConnected ||
        multiLsl.isConnected;
    final anythingConnecting =
        eegConnecting ||
        multiDevice.isBusy ||
        nirsConnecting ||
        multiLsl.state == AcquisitionState.connecting;
    bool rateIsDegraded(AcquisitionService service) {
      final received = service.deliveredSampleRate;
      return received != null && received < service.sampleRate * 0.8;
    }

    final rateDegraded =
        (eegConnected && rateIsDegraded(eegService)) ||
        secondaryConnected.any(rateIsDegraded);

    Color statusColor;
    String statusText;
    IconData statusIcon;

    if (anythingConnected) {
      statusColor = rateDegraded
          ? const Color(0xFFFBBF24)
          : const Color(0xFF10B981);
      statusIcon = rateDegraded ? Icons.warning_amber : Icons.check_circle;
      final parts = <String>[];
      if (rateDegraded) parts.add('Stream rate degraded');
      if (eegConnected) parts.add(deviceLabel ?? 'EEG Connected');
      if (secondaryConnected.isNotEmpty) {
        parts.add('${secondaryConnected.length} additional device(s)');
      }
      if (nirsConnected) parts.add('fNIRS Connected');
      if (multiLsl.isConnected) {
        parts.add('${multiLsl.connectedStreams.length} LSL stream(s)');
      }
      statusText = parts.join(' • ');
    } else if (anythingConnecting) {
      statusColor = const Color(0xFFFBBF24); // Amber
      statusIcon = Icons.sync;
      statusText = nirsConnecting && !eegConnecting && !multiDevice.isBusy
          ? 'Connecting fNIRS...'
          : 'Connecting devices...';
    } else {
      statusColor = const Color(0xFFEF4444); // Red
      statusIcon = Icons.error_outline;
      statusText = 'Disconnected';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withOpacity(0.3), width: 1.5),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  statusText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                if (eegConnected ||
                    secondaryConnected.isNotEmpty ||
                    nirsConnected ||
                    multiLsl.isConnected)
                  Text(
                    rateDegraded
                        ? 'Data delivery is below the configured sample rate'
                        : 'Streaming live data',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          if (anythingConnected) ...[
            TextButton.icon(
              icon: const Icon(Icons.settings_input_antenna, size: 18),
              label: const Text('Manage'),
              onPressed:
                  onOpenConnectDialog ??
                  () => showDeviceConnectionDialog(context),
            ),
            TextButton.icon(
              icon: const Icon(Icons.link_off, size: 18),
              label: const Text('Disconnect all'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFFCA5A5),
              ),
              onPressed: () async {
                await multiDevice.disconnectAll();
                onDisconnectNirs?.call();
                await multiLsl.disconnect();
              },
            ),
          ] else ...[
            ElevatedButton.icon(
              onPressed: anythingConnecting
                  ? () => multiDevice.disconnectAll()
                  : onOpenConnectDialog ??
                        () => showDeviceConnectionDialog(context),
              icon: Icon(
                anythingConnecting ? Icons.close : Icons.link,
                size: 16,
              ),
              label: Text(anythingConnecting ? 'Cancel' : 'Connect'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                minimumSize: Size.zero,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

void showDeviceConnectionDialog(BuildContext context) {
  showDialog(context: context, builder: (_) => const DeviceConnectionDialog());
}

class DeviceConnectionDialog extends StatelessWidget {
  const DeviceConnectionDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final eegService = context.watch<AcquisitionService>();
    final multiLsl = context.watch<MultiStreamLslService>();
    final multiDevice = context.watch<MultiDeviceAcquisitionService>();
    final settings = context.watch<SettingsService>();
    final configuredLslStreams = settings.deviceProfiles
        .where((device) => device.enabled && device.transport.name == 'lsl')
        .expand((device) => device.enabledStreams)
        .length;

    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Connect Devices',
        style: TextStyle(color: Colors.white),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Bluetooth EEG/PPG (xAMP-L10 / EpiDome / ORBIT)',
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.bluetooth_searching,
                  color: Color(0xFF14B8A6),
                ),
                title: const Text(
                  'Scan for xAMP or ORBIT',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Scan, then select each intended device below',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF14B8A6),
                    foregroundColor: Colors.black,
                  ),
                  onPressed: multiDevice.isScanning
                      ? null
                      : () => multiDevice.scan(),
                  child: Text(multiDevice.isScanning ? 'Scanning…' : 'Scan'),
                ),
              ),
              const Divider(color: Colors.white12, height: 24),
              const Text(
                'Bench Testing & Simulation',
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.waves, color: Color(0xFF38BDF8)),
                title: const Text(
                  'Synthetic EEG Mode (16-ch)',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Simulates 16-ch EpiDome waveforms at 250 Hz',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF38BDF8),
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () {
                    eegService.addSyntheticDevice();
                    final synth = eegService.discoveredDevices.firstWhere(
                      (d) => d.kind == DeviceKind.synthetic,
                    );
                    eegService.connect(synth);
                    Navigator.of(context).pop();
                  },
                  child: const Text('Simulate'),
                ),
              ),
              const Divider(color: Colors.white12, height: 24),
              const Text(
                'Configured WiFi / LSL Streams',
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.wifi, color: Color(0xFFB57BFF)),
                title: Text(
                  configuredLslStreams == 0
                      ? 'No enabled LSL profiles'
                      : 'Connect $configuredLslStreams configured stream(s)',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Supports EEG, EOG, EMG, fNIRS, physiological, and marker streams',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB57BFF),
                    foregroundColor: Colors.black,
                  ),
                  onPressed:
                      configuredLslStreams == 0 ||
                          multiLsl.state == AcquisitionState.connecting
                      ? null
                      : () {
                          multiLsl.connectConfigured(settings.deviceProfiles);
                          Navigator.of(context).pop();
                        },
                  child: Text(
                    multiLsl.state == AcquisitionState.connecting
                        ? 'Resolving…'
                        : 'Connect',
                  ),
                ),
              ),
              if (multiDevice.discoveredDevices
                  .where((d) => d.kind != DeviceKind.synthetic)
                  .isNotEmpty) ...[
                const Divider(color: Colors.white12, height: 24),
                const Text(
                  'Discovered Devices',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                ...multiDevice.discoveredDevices
                    .where((d) => d.kind != DeviceKind.synthetic)
                    .map(
                      (device) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          device.isBle ? Icons.bluetooth : Icons.devices_other,
                          color: const Color(0xFF14B8A6),
                        ),
                        title: Text(
                          device.name,
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          '${device.id} • ${device.kind.name.toUpperCase()}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                        trailing: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF14B8A6),
                            foregroundColor: Colors.black,
                          ),
                          onPressed:
                              multiDevice.isDeviceConnectedOrConnecting(
                                device.id,
                              )
                              ? null
                              : () => multiDevice.connect(device),
                          child: Text(
                            multiDevice.isDeviceConnectedOrConnecting(device.id)
                                ? 'Connected'
                                : 'Connect',
                          ),
                        ),
                      ),
                    ),
              ],
              if (eegService.connectedDeviceId != null ||
                  multiDevice.secondaryServices.isNotEmpty) ...[
                const Divider(color: Colors.white12, height: 24),
                const Text(
                  'Direct Device Connections',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (eegService.connectedDeviceId != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      eegService.isStreamReady
                          ? Icons.graphic_eq
                          : Icons.bluetooth_searching,
                      color: eegService.isStreamReady
                          ? const Color(0xFF10B981)
                          : const Color(0xFFFBBF24),
                    ),
                    title: Text(
                      eegService.connectedDeviceLabel,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      eegService.isStreamReady
                          ? 'Streaming validated samples'
                          : eegService.currentState.name,
                      style: const TextStyle(color: Colors.white54),
                    ),
                    trailing: IconButton(
                      tooltip: 'Disconnect this device',
                      icon: const Icon(
                        Icons.link_off,
                        color: Color(0xFFEF4444),
                      ),
                      onPressed: eegService.disconnect,
                    ),
                  ),
                ...multiDevice.secondaryDevices.entries.map(
                  (entry) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.bluetooth_connected,
                      color: Color(0xFF10B981),
                    ),
                    title: Text(
                      entry.value.connectedDeviceLabel,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      entry.value.isStreamReady
                          ? 'Streaming validated samples'
                          : entry.value.currentState.name,
                      style: const TextStyle(color: Colors.white54),
                    ),
                    trailing: IconButton(
                      tooltip: 'Disconnect this device',
                      icon: const Icon(
                        Icons.link_off,
                        color: Color(0xFFEF4444),
                      ),
                      onPressed: () => multiDevice.disconnect(entry.key),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close', style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }
}

void showQuickModuleSwitcher(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF1E293B),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => const QuickModuleSwitcherModal(),
  );
}

class QuickModuleSwitcherModal extends StatelessWidget {
  const QuickModuleSwitcherModal({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.apps, color: Color(0xFF3B82F6), size: 24),
                SizedBox(width: 10),
                Text(
                  'Quick Module Switcher',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Switch between research modules without disconnecting EEG hardware.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 16),
            _buildModuleOption(
              context,
              title: 'Home Dashboard',
              subtitle: 'Return to main overview & system diagnostics',
              icon: Icons.home_rounded,
              color: const Color(0xFF3B82F6),
              isHome: true,
            ),
            _buildModuleOption(
              context,
              title: 'EEG & fNIRS Recorder',
              subtitle: '16-channel waveform viewer & EDF+ recording',
              icon: Icons.monitor_heart,
              color: const Color(0xFF14B8A6),
              routeName: '/standalone',
            ),
            _buildModuleOption(
              context,
              title: 'Train NIDRA',
              subtitle: 'Real-time sleep staging & auditory biofeedback',
              icon: Icons.nightlight_round,
              color: const Color(0xFF8B5CF6),
              routeName: '/nidra',
            ),
            _buildModuleOption(
              context,
              title: 'ANGEL Cognitive Task',
              subtitle: 'Event-Related Potential battery & PDF reports',
              icon: Icons.psychology,
              color: const Color(0xFFF59E0B),
              routeName: '/angel',
            ),
            _buildModuleOption(
              context,
              title: 'Adaptive Working Memory',
              subtitle: 'N-Back cognitive task with EEG workload tracking',
              icon: Icons.memory,
              color: const Color(0xFFEC4899),
              routeName: '/wm',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModuleOption(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    bool isHome = false,
    String? routeName,
  }) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      onTap: () {
        Navigator.of(context).pop(); // Close switcher modal
        final session = context.read<SessionManager>();
        void doSwitch() {
          if (isHome) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          } else if (routeName != null) {
            Navigator.of(
              context,
            ).pushNamedAndRemoveUntil(routeName, (route) => route.isFirst);
          }
        }

        if (session.isRecording) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              title: const Text(
                '⚠️ Active Recording',
                style: TextStyle(color: Color(0xFFEF4444)),
              ),
              content: Text(
                'An EEG recording is currently active (${session.activeModule?.displayName ?? "Unknown"}). Do you want to stop and save before switching modules?',
                style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    doSwitch();
                  },
                  child: const Text(
                    'Switch Without Stopping',
                    style: TextStyle(color: Color(0xFFF59E0B)),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    session.stopRecording();
                    Navigator.of(ctx).pop();
                    doSwitch();
                  },
                  child: const Text('Stop & Switch'),
                ),
              ],
            ),
          );
        } else {
          doSwitch();
        }
      },
    );
  }
}
