import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/services/nirs_acquisition_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/models/module_type.dart';
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
  const StandaloneScreen({super.key});

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

  @override
  Widget build(BuildContext context) {
    final eegService = context.watch<AcquisitionService>();
    final nirsService = context.watch<NirsAcquisitionService>();
    final sessionManager = context.watch<SessionManager>();
    final settings = context.watch<SettingsService>();
    final channelConfig = context.watch<ChannelConfigService>();
    final lightTeal = const Color(0xFF14B8A6);

    final isRecording = sessionManager.isRecording;

    if (_subjectController.text != settings.subjectCode) {
      _subjectController.value = _subjectController.value.copyWith(
        text: settings.subjectCode,
        selection: TextSelection.collapsed(offset: settings.subjectCode.length),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        title: const Text(
          'Standalone EEG & fNIRS Recorder',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF111827),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              ConnectionStatusBar(
                eegState: eegService.currentState,
                nirsState: nirsService.currentState,
                deviceLabel: 'xAMP-L10',
                onDisconnectEeg: () => eegService.disconnect(),
                onDisconnectNirs: () => nirsService.disconnect(),
              ),
              const SizedBox(height: 16),

              // Recording Control Panel
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
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Subject ID / Session Tag',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
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
                            onChanged: (val) {
                              final code = val.trim().isEmpty
                                  ? 'S001'
                                  : val.trim();
                              settings.updateSubjectCode(code);
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    if (isRecording) ...[
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Tag Event Marker:',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 6),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [1, 2, 3, 5, 10].map((code) {
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: ElevatedButton(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF3B82F6,
                                        ),
                                        foregroundColor: Colors.white,
                                        minimumSize: const Size(44, 36),
                                        padding: EdgeInsets.zero,
                                      ),
                                      onPressed: () {
                                        sessionManager.recordEvent(
                                          'manual_marker_$code',
                                          code,
                                        );
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Tagged event marker M$code',
                                            ),
                                            duration: const Duration(
                                              milliseconds: 600,
                                            ),
                                          ),
                                        );
                                      },
                                      child: Text(
                                        'M$code',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const Spacer(),
                    ElevatedButton.icon(
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
                      onPressed: () async {
                        if (isRecording) {
                          await sessionManager.stopRecording();
                        } else {
                          final hasStorage = await context.read<PermissionService>().requestManageExternalStorage(context);
                          if (!hasStorage) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Cannot start recording: storage permission is required.')),
                              );
                            }
                            return;
                          }
                          final code = _subjectController.text.trim().isEmpty
                              ? 'S001'
                              : _subjectController.text.trim();
                          if (context.mounted) {
                            context.read<SettingsService>().updateSubjectCode(
                              code,
                            );
                            await sessionManager.startRecording(
                              module: ModuleType.standalone,
                              subjectId: code,
                              channelCount: eegService.channelCount,
                              sampleRate: eegService.sampleRate.toInt(),
                              channelLabels: channelConfig.labels,
                              enabledChannels: channelConfig.enabled,
                            );
                          }
                        }
                      },
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
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Live Waveforms Viewer
              Expanded(
                child: EegViewer(
                  eegService: eegService,
                  nirsService: nirsService,
                  initialDurationSeconds: 4,
                  showControls: true,
                  showMetrics: true,
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
          color: Colors.black.withOpacity(0.55),
          child: Center(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF111827),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFEF4444), width: 2),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 40, vertical: 32,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(
                    color: Color(0xFFEF4444),
                  ),
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
