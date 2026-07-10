import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/alert_service.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/models/module_type.dart';
import '../../core/models/sleep_score.dart';
import '../../core/models/eeg_sample.dart';
import '../../core/widgets/connection_status_bar.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/channel_config_service.dart';
import '../../core/services/permission_service.dart';
import 'nidra_module.dart';
import 'auditory_stim_service.dart';
import '../standalone/standalone_screen.dart';

/// Refactored Train NIDRA screen (replacing the 3439-line monolith).
///
/// Combines live EEG waveform inspection, real-time ONNX sleep stage prediction,
/// spectral band power visualization, interactive hypnogram chart, and auditory
/// closed-loop stimulation (ACLS) controls for bed-tilt and sleep experiments.
class NidraScreen extends StatefulWidget {
  const NidraScreen({super.key});

  @override
  State<NidraScreen> createState() => _NidraScreenState();
}

class _NidraScreenState extends State<NidraScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late TextEditingController _subjectController;
  late NidraModule _module;
  StreamSubscription<EegSample>? _sampleSub;
  StreamSubscription<AcquisitionState>? _acqStateSub;
  bool _eegDisconnected = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    final sessionManager = context.read<SessionManager>();
    final alertService = context.read<AlertService>();
    final eegService = context.read<AcquisitionService>();
    final settings = context.read<SettingsService>();

    _subjectController = TextEditingController(text: settings.subjectCode);

    _module = NidraModule(
      sessionManager: sessionManager,
      alertService: alertService,
    );
    _module.initPipeline(eegService.sampleRate);

    _sampleSub = eegService.samples.listen((sample) {
      _module.pushSample(sample);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final code = context.read<SettingsService>().subjectCode;
      if (code.isNotEmpty && _subjectController.text != code) {
        setState(() => _subjectController.text = code);
      }
      // Subscribe for disconnect overlay
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
    _sampleSub?.cancel();
    _acqStateSub?.cancel();
    _tabController.dispose();
    _subjectController.dispose();
    _module.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final eegService = context.watch<AcquisitionService>();
    final sessionManager = context.watch<SessionManager>();
    final settings = context.watch<SettingsService>();
    final channelConfig = context.watch<ChannelConfigService>();
    final lightTeal = const Color(0xFF14B8A6);

    if (_subjectController.text != settings.subjectCode) {
      _subjectController.value = _subjectController.value.copyWith(
        text: settings.subjectCode,
        selection: TextSelection.collapsed(offset: settings.subjectCode.length),
      );
    }

    return ChangeNotifierProvider<NidraModule>.value(
      value: _module,
      child: Consumer<NidraModule>(
        builder: (context, module, _) {
          final isRecording = sessionManager.isRecording;
          final latestScore = module.latestScore;
          final stimService = module.stimService;

          return Scaffold(
            backgroundColor: const Color(0xFF0B0F19),
            appBar: AppBar(
              title: const Text(
                'Train NIDRA • Sleep & Neurofeedback',
                style: TextStyle(color: Colors.white),
              ),
              backgroundColor: const Color(0xFF111827),
              elevation: 0,
              iconTheme: const IconThemeData(color: Colors.white),
              bottom: TabBar(
                controller: _tabController,
                indicatorColor: lightTeal,
                labelColor: lightTeal,
                unselectedLabelColor: Colors.white54,
                tabs: const [
                  Tab(text: 'Live Sleep Staging & Hypnogram'),
                  Tab(text: 'Auditory Closed-Loop Stim (ACLS)'),
                ],
              ),
            ),
            body: Stack(
              children: [
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20.0,
                      vertical: 12.0,
                    ),
                    child: Column(
                  children: [
                    // Connection & Recording Bar
                    Row(
                      children: [
                        Expanded(
                          child: ConnectionStatusBar(
                            eegState: eegService.currentState,
                            nirsState: null,
                            deviceLabel: 'xAMP-L10',
                            onDisconnectEeg: () => eegService.disconnect(),
                          ),
                        ),
                        const SizedBox(width: 12),
                        if (isRecording)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            margin: const EdgeInsets.only(right: 12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEF4444).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: const Color(0xFFEF4444),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  _eegDisconnected
                                      ? Icons.pause_circle_outline
                                      : Icons.timer,
                                  color: const Color(0xFFEF4444),
                                  size: 18,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _eegDisconnected
                                      ? '⏸ PAUSED'
                                      : sessionManager.formattedDuration,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isRecording
                                ? const Color(0xFFEF4444)
                                : lightTeal,
                            foregroundColor: isRecording
                                ? Colors.white
                                : Colors.black,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () async {
                            if (isRecording) {
                              final currentSubject = sessionManager.subject;
                              final currentStart = sessionManager.sessionStart;
                              final scores = context.read<NidraModule>().scores;

                              await sessionManager.stopRecording();

                              if (currentStart != null && scores.isNotEmpty) {
                                try {
                                  final jsonStr = jsonEncode(scores.map((s) => s.toJson()).toList());
                                  final path = await FileNamingService.jsonPath(currentSubject, ModuleType.nidra, currentStart);
                                  final file = File(path);
                                  await file.writeAsString(jsonStr);
                                  final stem = FileNamingService.stem(currentSubject, ModuleType.nidra, currentStart);
                                  await FileNamingService.exportToDownloads(path, subject: currentSubject, sessionStem: stem);
                                  debugPrint('[NidraScreen] Saved NIDRA scores JSON to $path');
                                } catch (e) {
                                  debugPrint('[NidraScreen] Error exporting JSON scores: $e');
                                }
                              }
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
                              final code =
                                  _subjectController.text.trim().isEmpty
                                  ? 'S001'
                                  : _subjectController.text.trim();
                              if (context.mounted) {
                                context.read<SettingsService>().updateSubjectCode(
                                  code,
                                );
                                await sessionManager.startRecording(
                                  module: ModuleType.nidra,
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
                            isRecording
                                ? Icons.stop
                                : Icons.fiber_manual_record,
                            size: 20,
                          ),
                          label: Text(
                            isRecording ? 'STOP RECORDING' : 'RECORD SLEEP',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: lightTeal,
                            side: BorderSide(color: lightTeal),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 14,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(builder: (_) => const StandaloneScreen()),
                            );
                          },
                          icon: const Icon(Icons.monitor_heart, size: 20),
                          label: const Text(
                            'OPEN EEG VIEWER',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Main Tab View
                    Expanded(
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _buildStagingTab(
                            module,
                            latestScore,
                            eegService,
                            lightTeal,
                            channelConfig.labels,
                          ),
                          _buildAclsTab(stimService, lightTeal),
                        ],
                      ),
                    ),
                  ],
                    ),
                  ),
                ),
                // Disconnect overlay — only shown while actively recording
                if (_eegDisconnected && isRecording) _buildConnectionLostOverlay(),
              ],
            ),
          );
        },
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
                horizontal: 40,
                vertical: 32,
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: Color(0xFFEF4444),
                  ),
                  SizedBox(height: 20),
                  Text(
                    'EEG Amplifier Disconnected',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
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

  Widget _buildStagingTab(
    NidraModule module,
    SleepScoreResult? score,
    AcquisitionService eegService,
    Color lightTeal,
    List<String> channelLabels,
  ) {
    return Column(
      children: [
        // Top row: Current Stage & Band Powers
        Row(
          children: [
            Expanded(
              flex: 2,
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _getStageColor(
                      score?.stage ?? SleepStage.wake,
                    ).withOpacity(0.4),
                    width: 2,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'CURRENT SLEEP STAGE',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _getStageColor(
                              score?.stage ?? SleepStage.wake,
                            ).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            module.usesModel
                                ? 'ONNX AI MODEL'
                                : 'HEURISTIC SCORER',
                            style: TextStyle(
                              color: _getStageColor(
                                score?.stage ?? SleepStage.wake,
                              ),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          score?.stage.label ?? 'WAKE',
                          style: TextStyle(
                            color: _getStageColor(
                              score?.stage ?? SleepStage.wake,
                            ),
                            fontSize: 38,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          score != null
                              ? '${(score.confidence * 100).toStringAsFixed(1)}% conf'
                              : 'Waiting for epochs...',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 3,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'SPECTRAL BAND POWERS',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildBandPower(
                          'Delta',
                          '0.5-4Hz',
                          score?.deltaPower ?? 0,
                          const Color(0xFF3B82F6),
                        ),
                        _buildBandPower(
                          'Theta',
                          '4-8Hz',
                          score?.thetaPower ?? 0,
                          const Color(0xFF10B981),
                        ),
                        _buildBandPower(
                          'Alpha',
                          '8-12Hz',
                          score?.alphaPower ?? 0,
                          const Color(0xFFFBBF24),
                        ),
                        _buildBandPower(
                          'Beta',
                          '12-30Hz',
                          score?.betaPower ?? 0,
                          const Color(0xFFEF4444),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              border: Border.all(color: Colors.white12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'HYPNOGRAM',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (module.scores.isNotEmpty)
                      TextButton(
                        onPressed: () => module.clearScores(),
                        child: const Text(
                          'Clear',
                          style: TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: module.scores.isNotEmpty
                      ? CustomPaint(
                          painter: _HypnogramPainter(scores: module.scores),
                          size: Size.infinite,
                        )
                      : const Center(
                          child: Text(
                            'Waiting for sleep data...',
                            style: TextStyle(color: Colors.white38, fontSize: 13),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBandPower(
    String label,
    String freqRange,
    double power,
    Color color,
  ) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 11,
          ),
        ),
        Text(
          freqRange,
          style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 9),
        ),
        const SizedBox(height: 4),
        Text(
          '${power.toStringAsFixed(1)} dB',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  Widget _buildAclsTab(AuditoryStimService stim, Color lightTeal) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: stim.enabled ? lightTeal : Colors.white12,
            width: stim.enabled ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.volume_up,
                      color: stim.enabled ? lightTeal : Colors.white54,
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Closed-Loop Stimulation',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Switch(
                  value: stim.enabled,
                  activeColor: lightTeal,
                  onChanged: (val) => stim.setEnabled(val),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'When active, tone stimulation will trigger during detected slow-wave (N3) sleep periods.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 13,
                height: 1.4,
              ),
            ),
            if (stim.enabled) ...[
              const SizedBox(height: 20),
              const Divider(color: Colors.white10),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Stimulation State:',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: stim.isStimulating
                          ? const Color(0xFF10B981).withOpacity(0.2)
                          : Colors.white10,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      stim.isStimulating ? 'ACTIVE' : 'STANDBY',
                      style: TextStyle(
                        color: stim.isStimulating
                            ? const Color(0xFF10B981)
                            : Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Consecutive N3 Epochs:',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  Text(
                    '${stim.stableDurationSecs ~/ 30} epochs',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Total Tones Played:',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  Text(
                    '${stim.totalStimBursts}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _getStageColor(SleepStage stage) {
    return switch (stage) {
      SleepStage.wake => const Color(0xFF10B981),
      SleepStage.rem => const Color(0xFFFBBF24),
      SleepStage.n1 => const Color(0xFF60A5FA),
      SleepStage.n2 => const Color(0xFF3B82F6),
      SleepStage.n3 => const Color(0xFF8B5CF6),
    };
  }
}

class _HypnogramPainter extends CustomPainter {
  _HypnogramPainter({required this.scores});

  final List<SleepScoreResult> scores;
  static const List<SleepStage> stages = [
    SleepStage.wake,
    SleepStage.rem,
    SleepStage.n1,
    SleepStage.n2,
    SleepStage.n3,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (scores.isEmpty) return;

    final rowH = size.height / stages.length;
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..strokeWidth = 1;

    for (var i = 0; i <= stages.length; i++) {
      final y = i * rowH;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    for (var i = 0; i < stages.length; i++) {
      final y = i * rowH + rowH / 2;
      final label = TextPainter(
        text: TextSpan(
          text: stages[i].label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.6),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(4, y - label.height / 2));
    }

    final stepX = (size.width - 40) / math.max(1, scores.length - 1);
    final path = Path();
    final paint = Paint()
      ..color = const Color(0xFF14B8A6)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    for (var i = 0; i < scores.length; i++) {
      final stageIdx = stages.indexOf(scores[i].stage);
      final x = 40 + i * stepX;
      final y = (stageIdx + 0.5) * rowH;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        final prevY = (stages.indexOf(scores[i - 1].stage) + 0.5) * rowH;
        path.lineTo(x, prevY);
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_HypnogramPainter old) =>
      old.scores.length != scores.length;
}


