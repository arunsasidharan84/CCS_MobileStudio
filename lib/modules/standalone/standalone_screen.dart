import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/multi_stream_lsl_service.dart';
import '../../core/services/multi_device_acquisition_service.dart';
import '../../core/models/module_type.dart';
import '../../core/models/device_profile.dart';
import '../../core/widgets/eeg_viewer.dart';
import '../../core/widgets/connection_status_bar.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/permission_service.dart';
import '../../core/services/channel_config_service.dart';

/// Standalone EEG & fNIRS Recorder cum Viewer.
///
/// All three cognitive/sleep modules share this exact same viewing and recording
/// engine, while also being accessible as an independent utility module.
class StandaloneScreen extends StatefulWidget {
  const StandaloneScreen({super.key, this.viewerOnly = false});

  /// Used when this screen is opened from a paradigm that owns the recorder.
  /// It exposes live waveforms without allowing an accidental stop/restart
  /// under the standalone EEG filename prefix.
  final bool viewerOnly;

  @override
  State<StandaloneScreen> createState() => _StandaloneScreenState();
}

class _StandaloneScreenState extends State<StandaloneScreen> {
  late TextEditingController _subjectController;
  Timer? _uiRefreshTimer;
  StreamSubscription<AcquisitionState>? _acqStateSub;
  bool _eegDisconnected = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsService>();
    _subjectController = TextEditingController(text: settings.subjectCode);

    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final code = context.read<SettingsService>().subjectCode;
      if (code.isNotEmpty && _subjectController.text != code) {
        setState(() => _subjectController.text = code);
      }
      // subscribe to EEG state changes for the disconnect overlay
      final eegService = context.read<AcquisitionService>();
      _acqStateSub = eegService.state.listen(_handleAcqState);
      _handleAcqState(eegService.currentState);
    });
  }

  void _handleAcqState(AcquisitionState state) {
    final disconnected = state != AcquisitionState.streaming;
    if (disconnected != _eegDisconnected) {
      setState(() => _eegDisconnected = disconnected);
    }
  }

  @override
  void dispose() {
    _uiRefreshTimer?.cancel();
    _acqStateSub?.cancel();
    _subjectController.dispose();
    super.dispose();
  }

  Future<void> _toggleRecording({
    required SessionManager sessionManager,
    required AcquisitionService eegService,
    required SettingsService settings,
    required ChannelConfigService channelConfig,
  }) async {
    if (sessionManager.isRecording) {
      await sessionManager.stopRecording();
      return;
    }
    final hasStorage = await context
        .read<PermissionService>()
        .requestManageExternalStorage(context);
    if (!hasStorage) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cannot start recording: storage permission is required.',
            ),
          ),
        );
      }
      return;
    }
    final code = _subjectController.text.trim().isEmpty
        ? 'S001'
        : _subjectController.text.trim();
    if (!mounted) return;
    settings.updateSubjectCode(code);
    await sessionManager.startRecording(
      module: ModuleType.standalone,
      subjectId: code,
      channelCount: eegService.channelCount,
      sampleRate: eegService.sampleRate.toInt(),
      channelLabels: eegService.recordingChannelLabels(channelConfig.labels),
      enabledChannels: eegService.recordingEnabledChannels(
        channelConfig.enabled,
      ),
    );
  }

  Widget _buildSubjectEditor(SettingsService settings, bool isRecording) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Subject ID / Session Tag',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _subjectController,
          enabled: !isRecording,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: const Color(0xFF111827),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
          onChanged: (value) {
            final code = value.trim().isEmpty ? 'S001' : value.trim();
            settings.updateSubjectCode(code);
          },
        ),
      ],
    );
  }

  Widget _buildMarkerControls(SessionManager sessionManager) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Tag Event Marker:',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 6),
        _buildMarkerButtons(sessionManager),
      ],
    );
  }

  Widget _buildMarkerButtons(SessionManager sessionManager) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [1, 2, 3, 5, 10].map((code) {
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                foregroundColor: Colors.white,
                minimumSize: const Size(44, 36),
                padding: EdgeInsets.zero,
              ),
              onPressed: () {
                sessionManager.recordEvent('manual_marker_$code', code);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Tagged event marker M$code'),
                    duration: const Duration(milliseconds: 600),
                  ),
                );
              },
              child: Text(
                'M$code',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildConnectedStreamTabs(
    AcquisitionService eegService,
    MultiStreamLslService multiLsl,
    MultiDeviceAcquisitionService multiDevice,
  ) {
    final entries = multiLsl.connectedStreamProfiles.entries
        .where((entry) => entry.value.signalType != SignalType.marker)
        .toList(growable: false);
    final showPrimary = eegService.isStreamReady;
    final secondary = multiDevice.readySecondaryServices;
    final labels = <String>[
      if (showPrimary) eegService.connectedDeviceLabel,
      ...secondary.map((service) => service.connectedDeviceLabel),
      ...entries.map((entry) => entry.value.name),
    ];
    final viewers = <Widget>[
      if (showPrimary)
        EegViewer(
          key: ValueKey('device-${eegService.connectedDeviceId}'),
          eegService: eegService,
          displayStateKey: 'device:${eegService.connectedDeviceId}',
          initialDurationSeconds: 4,
          showControls: true,
          showMetrics: true,
        ),
      ...secondary.map(
        (service) => EegViewer(
          key: ValueKey('direct-${service.connectedDeviceId}'),
          eegService: service,
          displayStateKey: 'device:${service.connectedDeviceId}',
          initialDurationSeconds: 4,
          showControls: true,
          showMetrics: true,
        ),
      ),
      ...entries.map((entry) {
        final runtime = SignalStreamProfile.fromJson(entry.value.toJson())
          ..id = entry.key;
        return EegViewer(
          key: ValueKey(entry.key),
          signalStream: multiLsl.samples,
          signalProfile: runtime,
          displayStateKey: 'stream:${entry.key}',
          initialDurationSeconds: 4,
          showControls: true,
          showMetrics: runtime.signalType != SignalType.fnirs,
        );
      }),
    ];
    if (viewers.isEmpty) {
      return const Center(
        child: Text(
          'No validated signal stream connected.\n'
          'Use Connect above, then select a device. A viewer opens only after '
          'valid samples arrive.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    if (viewers.length == 1) return viewers.single;
    return DefaultTabController(
      key: ValueKey(labels.join('|')),
      length: viewers.length,
      child: Column(
        children: [
          Container(
            color: const Color(0xFF111827),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              indicatorColor: const Color(0xFF14B8A6),
              labelColor: const Color(0xFF14B8A6),
              unselectedLabelColor: Colors.white54,
              tabs: labels.map((label) => Tab(text: label)).toList(),
            ),
          ),
          Expanded(child: TabBarView(children: viewers)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final eegService = context.watch<AcquisitionService>();
    final multiLsl = context.watch<MultiStreamLslService>();
    final multiDevice = context.watch<MultiDeviceAcquisitionService>();
    final sessionManager = context.watch<SessionManager>();
    final settings = context.watch<SettingsService>();
    final channelConfig = context.watch<ChannelConfigService>();
    final lightTeal = const Color(0xFF14B8A6);
    final compact = MediaQuery.sizeOf(context).width < 600;

    final isRecording = sessionManager.isRecording;

    if (_subjectController.text != settings.subjectCode) {
      _subjectController.value = _subjectController.value.copyWith(
        text: settings.subjectCode,
        selection: TextSelection.collapsed(offset: settings.subjectCode.length),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        title: Text(
          widget.viewerOnly
              ? (compact
                    ? 'Live EEG Viewer'
                    : 'Live EEG Viewer • Train NIDRA recording protected')
              : (compact ? 'Recorder' : 'Multi-device Signal Recorder'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF111827),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: EdgeInsets.all(compact ? 12 : 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConnectionStatusBar(
                    eegState: eegService.currentState,
                    nirsState: null,
                    deviceLabel: eegService.connectedDeviceLabel,
                    onDisconnectEeg: () => eegService.disconnect(),
                  ),
                  if (multiLsl.recentMarkers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF7C3AED).withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF8B5CF6)),
                        ),
                        child: Text(
                          'LSL marker: ${multiLsl.recentMarkers.last.value} '
                          '(code ${multiLsl.recentMarkers.last.code})',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),

                  // Recording Control Panel
                  if (widget.viewerOnly)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F766E).withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: lightTeal),
                      ),
                      child: Text(
                        isRecording
                            ? '${sessionManager.module.displayName} recording is active '
                                  '(${sessionManager.formattedDuration}). Recording controls are locked here.'
                            : 'Viewer-only mode. Return to Train NIDRA to start or stop the recording.',
                        style: const TextStyle(color: Colors.white),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isRecording
                              ? const Color(0xFFEF4444)
                              : Colors.white12,
                          width: isRecording ? 2 : 1,
                        ),
                      ),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final compact = constraints.maxWidth < 700;
                          final recordButton = ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isRecording
                                  ? const Color(0xFFEF4444)
                                  : lightTeal,
                              foregroundColor: isRecording
                                  ? Colors.white
                                  : Colors.black,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 16,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: () => _toggleRecording(
                              sessionManager: sessionManager,
                              eegService: eegService,
                              settings: settings,
                              channelConfig: channelConfig,
                            ),
                            icon: Icon(
                              isRecording ? Icons.stop : Icons.play_arrow,
                              size: 24,
                            ),
                            label: Text(
                              isRecording
                                  ? 'STOP${sessionManager.timerPaused ? ' ⏸ PAUSED' : ' ▶ ${sessionManager.formattedDuration}'}'
                                  : 'START RECORDING',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          );
                          final subjectEditor = _buildSubjectEditor(
                            settings,
                            isRecording,
                          );
                          if (compact) {
                            if (isRecording) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _subjectController.text,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(flex: 3, child: recordButton),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  _buildMarkerButtons(sessionManager),
                                ],
                              );
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                subjectEditor,
                                if (isRecording) ...[
                                  const SizedBox(height: 12),
                                  _buildMarkerControls(sessionManager),
                                ],
                                const SizedBox(height: 12),
                                recordButton,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(flex: 2, child: subjectEditor),
                              const SizedBox(width: 16),
                              if (isRecording) ...[
                                Expanded(
                                  flex: 3,
                                  child: _buildMarkerControls(sessionManager),
                                ),
                                const SizedBox(width: 16),
                              ],
                              recordButton,
                            ],
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 16),

                  // Live Waveforms Viewer
                  Expanded(
                    child: _buildConnectedStreamTabs(
                      eegService,
                      multiLsl,
                      multiDevice,
                    ),
                  ),
                ],
              ),
            ),
            // Disconnect overlay
            if (_eegDisconnected && isRecording) _buildConnectionLostOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionLostOverlay() {
    return Positioned.fill(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: Container(
          color: Colors.black.withValues(alpha: 0.55),
          child: Center(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF111827),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFEF4444), width: 2),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Color(0xFFEF4444)),
                  const SizedBox(height: 20),
                  const Text(
                    'EEG Amplifier Disconnected',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Recording timer paused.\nRestart your amplifier — it will reconnect automatically.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
