import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/alert_service.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/models/module_type.dart';
import '../../core/models/sleep_score.dart';
import '../../core/models/eeg_sample.dart';
import '../../core/models/device_profile.dart';
import '../../core/widgets/connection_status_bar.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/channel_config_service.dart';
import '../../core/services/permission_service.dart';
import 'nidra_module.dart';
import 'auditory_stim_service.dart';
import 'sleep_channel_selection.dart';
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
  Timer? _uiRefreshTimer;
  bool _eegDisconnected = false;
  String? _pipelineConfigurationKey;
  bool _pipelineInitializationScheduled = false;
  String _chartMode = 'hypnogram';
  Set<SleepStage> _probabilityStages = {
    SleepStage.wake,
    SleepStage.n2,
    SleepStage.n3,
    SleepStage.rem,
  };

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    final sessionManager = context.read<SessionManager>();
    final alertService = context.read<AlertService>();
    final eegService = context.read<AcquisitionService>();
    final settings = context.read<SettingsService>();
    _chartMode = settings.nidraChartMode;
    _probabilityStages = settings.nidraProbabilityStages
        .map(
          (name) => SleepStage.values
              .where((stage) => stage.name == name)
              .firstOrNull,
        )
        .whereType<SleepStage>()
        .toSet();
    if (_probabilityStages.isEmpty) {
      _probabilityStages = {SleepStage.n3};
    }

    _subjectController = TextEditingController(text: settings.subjectCode);

    _module = NidraModule(
      sessionManager: sessionManager,
      alertService: alertService,
    );
    _module.stimulusMarkerCode = settings.nidraStimMarkerCode;
    _module.stimService.configure(
      enabled: settings.nidraStimEnabled,
      targetStage: SleepStage.values.firstWhere(
        (stage) => stage.name == settings.nidraStimTargetStage,
        orElse: () => SleepStage.n3,
      ),
      stimType: settings.nidraStimType,
      toneFrequencyHz: settings.nidraStimToneFrequencyHz,
      toneDurationMs: settings.nidraStimToneDurationMs,
      audioFilePath: settings.nidraStimAudioFilePath,
      volume: settings.nidraStimVolume,
      minProbability: settings.nidraStimMinProbability,
      stableDurationSecs: settings.nidraStimStableDurationSecs,
      maxDurationSecs: settings.nidraStimMaxDurationSecs,
      intervalSecs: settings.nidraStimIntervalSecs,
      refractorySecs: settings.nidraStimRefractorySecs,
      mode: settings.nidraStimMode,
      notifyBeep: settings.nidraStimNotifyBeep,
      notifyFlash: settings.nidraStimNotifyFlash,
      notificationIntervalSecs: settings.nidraStimNotificationIntervalSecs,
    );

    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && context.read<SessionManager>().isRecording) {
        setState(() {});
      }
    });

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

  void _ensureSleepPipeline(
    AcquisitionService eegService,
    SettingsService settings,
    ChannelConfigService channelConfig,
  ) {
    final labels = eegService.displayChannelLabels(eegService.channelCount);
    final enabled = eegService.recordingEnabledChannels(channelConfig.enabled);
    final key =
        '${eegService.sampleRate}:${labels.join('|')}:'
        '${enabled.join('|')}:${settings.nidraScoringSignalLabel}:'
        '${settings.nidraScoringReferenceLabel}';
    if (_pipelineConfigurationKey == key || _pipelineInitializationScheduled) {
      return;
    }
    _pipelineInitializationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pipelineInitializationScheduled = false;
      if (!mounted) return;
      _pipelineConfigurationKey = key;
      unawaited(
        _module.initPipeline(
          eegService.sampleRate,
          channelLabels: labels,
          enabledChannels: enabled,
          preferredSignalLabel: settings.nidraScoringSignalLabel,
          preferredReferenceLabel: settings.nidraScoringReferenceLabel,
        ),
      );
    });
  }

  @override
  void dispose() {
    _sampleSub?.cancel();
    _acqStateSub?.cancel();
    _uiRefreshTimer?.cancel();
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
    _ensureSleepPipeline(eegService, settings, channelConfig);

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

          return ListenableBuilder(
            listenable: stimService,
            builder: (context, _) => Scaffold(
              backgroundColor: const Color(0xFF0B0F19),
              appBar: AppBar(
                title: Text(
                  MediaQuery.sizeOf(context).width < 600
                      ? 'Train NIDRA'
                      : 'Train NIDRA • Sleep & Neurofeedback',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white),
                ),
                backgroundColor: const Color(0xFF111827),
                elevation: 0,
                iconTheme: const IconThemeData(color: Colors.white),
                bottom: TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
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
                      padding: EdgeInsets.symmetric(
                        horizontal: MediaQuery.sizeOf(context).width < 600
                            ? 10
                            : 20,
                        vertical: 12,
                      ),
                      child: Column(
                        children: [
                          // Connection & Recording Bar
                          LayoutBuilder(
                            builder: (context, constraints) {
                              // A tablet in landscape can still have fewer than
                              // 900 logical pixels. At that width the timer plus
                              // the two labelled actions overflow a single row.
                              final compact = constraints.maxWidth < 960;
                              final connectionBar = ConnectionStatusBar(
                                eegState: eegService.currentState,
                                nirsState: null,
                                deviceLabel: eegService.connectedDeviceLabel,
                                onDisconnectEeg: () => eegService.disconnect(),
                              );
                              return Flex(
                                direction: compact
                                    ? Axis.vertical
                                    : Axis.horizontal,
                                // A horizontal Flex lives in an unbounded-height
                                // Column here. Stretching its cross axis prevents
                                // the entire tablet body from being laid out.
                                crossAxisAlignment: compact
                                    ? CrossAxisAlignment.stretch
                                    : CrossAxisAlignment.center,
                                children: [
                                  if (compact)
                                    connectionBar
                                  else
                                    Expanded(child: connectionBar),
                                  SizedBox(
                                    width: compact ? 0 : 12,
                                    height: compact ? 8 : 0,
                                  ),
                                  if (isRecording)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 10,
                                      ),
                                      margin: EdgeInsets.only(
                                        right: compact ? 0 : 12,
                                        bottom: compact ? 8 : 0,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(
                                          0xFFEF4444,
                                        ).withOpacity(0.2),
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
                                                : sessionManager
                                                      .formattedDuration,
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
                                        final currentSubject =
                                            sessionManager.subject;
                                        final currentStart =
                                            sessionManager.sessionStart;
                                        final scores = context
                                            .read<NidraModule>()
                                            .scores;

                                        await sessionManager.stopRecording();

                                        if (currentStart != null &&
                                            scores.isNotEmpty) {
                                          try {
                                            final jsonStr = jsonEncode(
                                              scores.indexed
                                                  .map(
                                                    (entry) => {
                                                      ...entry.$2.toJson(),
                                                      'scoringDerivation':
                                                          entry.$1 <
                                                              module
                                                                  .scoreDerivations
                                                                  .length
                                                          ? module
                                                                .scoreDerivations[entry
                                                                .$1]
                                                          : module
                                                                .scoringDerivation,
                                                    },
                                                  )
                                                  .toList(),
                                            );
                                            final path =
                                                await FileNamingService.jsonPath(
                                                  currentSubject,
                                                  ModuleType.nidra,
                                                  currentStart,
                                                );
                                            final file = File(path);
                                            await file.writeAsString(jsonStr);
                                            final stem = FileNamingService.stem(
                                              currentSubject,
                                              ModuleType.nidra,
                                              currentStart,
                                            );
                                            await FileNamingService.exportToDownloads(
                                              path,
                                              subject: currentSubject,
                                              sessionStem: stem,
                                            );
                                            debugPrint(
                                              '[NidraScreen] Saved NIDRA scores JSON to $path',
                                            );
                                          } catch (e) {
                                            debugPrint(
                                              '[NidraScreen] Error exporting JSON scores: $e',
                                            );
                                          }
                                        }
                                      } else {
                                        final hasStorage = await context
                                            .read<PermissionService>()
                                            .requestManageExternalStorage(
                                              context,
                                            );
                                        if (!hasStorage) {
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'Cannot start recording: storage permission is required.',
                                                ),
                                              ),
                                            );
                                          }
                                          return;
                                        }
                                        final code =
                                            _subjectController.text
                                                .trim()
                                                .isEmpty
                                            ? 'S001'
                                            : _subjectController.text.trim();
                                        if (context.mounted) {
                                          context
                                              .read<SettingsService>()
                                              .updateSubjectCode(code);
                                          await sessionManager.startRecording(
                                            module: ModuleType.nidra,
                                            subjectId: code,
                                            channelCount:
                                                eegService.channelCount,
                                            sampleRate: eegService.sampleRate
                                                .toInt(),
                                            channelLabels: eegService
                                                .recordingChannelLabels(
                                                  channelConfig.labels,
                                                ),
                                            enabledChannels: eegService
                                                .recordingEnabledChannels(
                                                  channelConfig.enabled,
                                                ),
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
                                      isRecording
                                          ? 'STOP RECORDING'
                                          : 'RECORD SLEEP',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: compact ? 0 : 12,
                                    height: compact ? 8 : 0,
                                  ),
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
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const StandaloneScreen(
                                                viewerOnly: true,
                                              ),
                                        ),
                                      );
                                    },
                                    icon: const Icon(
                                      Icons.monitor_heart,
                                      size: 20,
                                    ),
                                    label: const Text(
                                      'OPEN EEG VIEWER',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
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
                                  settings,
                                  channelConfig,
                                  isRecording,
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
                  if (_eegDisconnected && isRecording)
                    _buildConnectionLostOverlay(),
                  if (stimService.conditionActive)
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 18,
                      child: Material(
                        elevation: 12,
                        color: Colors.transparent,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF111827),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: stimService.notificationActive
                                  ? Colors.orangeAccent
                                  : lightTeal,
                              width: 2,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                stimService.notificationActive
                                    ? Icons.notifications_active
                                    : Icons.bedtime,
                                color: stimService.notificationActive
                                    ? Colors.orangeAccent
                                    : lightTeal,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  stimService.statusText,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              Text(
                                _formatDuration(
                                  Duration(
                                    seconds: stimService.conditionElapsedSecs,
                                  ),
                                ),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  fontFeatures: [
                                    ui.FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                onPressed: stimService.snooze,
                                child: const Text('Snooze'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (stimService.flashOn)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Colors.orangeAccent,
                              width: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
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
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFFEF4444)),
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
    SettingsService settings,
    ChannelConfigService channelConfig,
    bool isRecording,
  ) {
    final labels = eegService.displayChannelLabels(eegService.channelCount);
    final types = eegService.displayChannelTypes(eegService.channelCount);
    final enabled = eegService.recordingEnabledChannels(channelConfig.enabled);
    final selection = SleepChannelSelection.fromLabels(
      labels,
      enabledChannels: enabled,
      preferredSignalLabel: settings.nidraScoringSignalLabel,
      preferredReferenceLabel: settings.nidraScoringReferenceLabel,
    );
    final signalLabels = List<int>.generate(labels.length, (index) => index)
        .where(
          (index) =>
              (index >= enabled.length || enabled[index]) &&
              index < types.length &&
              types[index] == SignalType.eeg &&
              !const {
                'M1',
                'M2',
                'A1',
                'A2',
              }.contains(labels[index].trim().toUpperCase()),
        )
        .map((index) => labels[index])
        .toList(growable: false);
    final referenceLabels = List<int>.generate(labels.length, (index) => index)
        .where(
          (index) =>
              (index >= enabled.length || enabled[index]) &&
              index < types.length &&
              types[index] == SignalType.eeg &&
              labels[index] != selection?.signalLabel,
        )
        .map((index) => labels[index])
        .toList(growable: false);
    return Column(
      children: [
        _buildScoringMontageSelector(
          settings: settings,
          signalLabels: signalLabels,
          referenceLabels: referenceLabels,
          selectedSignal: selection?.signalLabel,
          selectedReference: selection?.referenceLabel,
          isRecording: isRecording,
          activeColor: lightTeal,
        ),
        const SizedBox(height: 12),
        // Top row: Current Stage & Band Powers
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 700;
            final poorSignal = score != null && !score.isReliable;
            final stageColor = poorSignal
                ? Colors.orangeAccent
                : _getStageColor(score?.stage ?? SleepStage.wake);
            return SizedBox(
              height: compact ? 280 : 150,
              child: Flex(
                direction: compact ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 2,
                    child: Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: stageColor.withOpacity(0.4),
                          width: 2,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'CURRENT SLEEP STAGE',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: stageColor.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    module.usesModel
                                        ? 'ONNX • ${module.scoringDerivation ?? 'EEG'}'
                                        : (module.pipelineError != null
                                              ? 'MODEL ERROR'
                                              : 'MODEL LOADING'),
                                    style: TextStyle(
                                      color: stageColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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
                                poorSignal
                                    ? 'POOR SIGNAL'
                                    : (score?.stage.label ?? 'WAITING'),
                                style: TextStyle(
                                  color: stageColor,
                                  fontSize: poorSignal ? 27 : 38,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  score != null
                                      ? (poorSignal
                                            ? '${(score.artifactRatio * 100).round()}% artifact'
                                            : '${(score.confidence * 100).toStringAsFixed(1)}% conf')
                                      : 'Waiting for epochs...',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.7),
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _buildStageProbabilities(score),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(width: compact ? 0 : 16, height: compact ? 12 : 0),
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
            );
          },
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
                  children: [
                    Text(
                      _chartMode == 'hypnogram'
                          ? 'HYPNOGRAM'
                          : 'STAGE PROBABILITY TREND',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (module.scores.isNotEmpty) ...[
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          _hypnogramProgressText(module),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ] else
                      const Spacer(),
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
                const SizedBox(height: 6),
                Wrap(
                  spacing: 7,
                  runSpacing: 5,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ChoiceChip(
                      label: const Text('Hypnogram'),
                      selected: _chartMode == 'hypnogram',
                      onSelected: (_) => _setChartMode(settings, 'hypnogram'),
                    ),
                    ChoiceChip(
                      label: const Text('Probabilities'),
                      selected: _chartMode == 'probabilities',
                      onSelected: (_) =>
                          _setChartMode(settings, 'probabilities'),
                    ),
                    if (_chartMode == 'probabilities')
                      ...SleepStage.values.map(
                        (stage) => FilterChip(
                          label: Text(stage.label),
                          selected: _probabilityStages.contains(stage),
                          selectedColor: _getStageColor(
                            stage,
                          ).withOpacity(0.35),
                          checkmarkColor: _getStageColor(stage),
                          onSelected: (selected) => _toggleProbabilityStage(
                            settings,
                            stage,
                            selected,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: module.scores.isNotEmpty
                      ? CustomPaint(
                          painter: _chartMode == 'hypnogram'
                              ? _HypnogramPainter(
                                  scores: module.scores,
                                  recordingStart:
                                      module.sessionManager.sessionStart,
                                )
                              : _StageProbabilityPainter(
                                  scores: module.scores,
                                  stages: _probabilityStages,
                                  recordingStart:
                                      module.sessionManager.sessionStart,
                                  colors: {
                                    for (final stage in SleepStage.values)
                                      stage: _getStageColor(stage),
                                  },
                                ),
                          size: Size.infinite,
                        )
                      : const Center(
                          child: Text(
                            'Waiting for sleep data...',
                            style: TextStyle(
                              color: Colors.white38,
                              fontSize: 13,
                            ),
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

  void _setChartMode(SettingsService settings, String mode) {
    if (_chartMode == mode) return;
    setState(() => _chartMode = mode);
    settings.update((settings) => settings.nidraChartMode = mode);
  }

  void _toggleProbabilityStage(
    SettingsService settings,
    SleepStage stage,
    bool selected,
  ) {
    if (!selected && _probabilityStages.length == 1) return;
    setState(() {
      if (selected) {
        _probabilityStages.add(stage);
      } else {
        _probabilityStages.remove(stage);
      }
    });
    settings.update(
      (settings) => settings.nidraProbabilityStages = _probabilityStages
          .map((stage) => stage.name)
          .toList(growable: false),
    );
  }

  String _hypnogramProgressText(NidraModule module) {
    final scored = Duration(seconds: module.scores.length * 30);
    final unscored = module.scores.where((score) => !score.isReliable).length;
    final elapsed = module.sessionManager.currentDuration;
    final secondsIntoEpoch = elapsed.inSeconds % 30;
    final nextIn = secondsIntoEpoch == 0 && elapsed.inSeconds > 0
        ? 30
        : 30 - secondsIntoEpoch;
    return 'Epoch ${module.scores.length} • '
        '${_formatDuration(scored)} scored • '
        '${unscored > 0 ? '$unscored artifact gap${unscored == 1 ? '' : 's'} • ' : ''}'
        'next in ${nextIn}s';
  }

  String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  Widget _buildScoringMontageSelector({
    required SettingsService settings,
    required List<String> signalLabels,
    required List<String> referenceLabels,
    required String? selectedSignal,
    required String? selectedReference,
    required bool isRecording,
    required Color activeColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF172033),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: activeColor.withValues(alpha: 0.35)),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          Icon(Icons.account_tree_outlined, color: activeColor, size: 20),
          const Text(
            'SCORING MONTAGE',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Text('Signal', style: TextStyle(color: Colors.white54)),
          DropdownButton<String>(
            value: signalLabels.contains(selectedSignal)
                ? selectedSignal
                : null,
            hint: const Text(
              'No enabled EEG',
              style: TextStyle(color: Colors.redAccent),
            ),
            dropdownColor: const Color(0xFF1E293B),
            style: const TextStyle(color: Colors.white),
            items: signalLabels
                .map(
                  (label) => DropdownMenuItem(value: label, child: Text(label)),
                )
                .toList(growable: false),
            onChanged: (value) {
              if (value == null) return;
              settings.update((settings) {
                settings.nidraScoringSignalLabel = value;
                if (settings.nidraScoringReferenceLabel == value) {
                  settings.nidraScoringReferenceLabel = '__none__';
                }
              });
              _module.stimService.resetForScoringMontageChange();
              if (isRecording) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Scoring montage changed. Prior epochs are retained; '
                      'the next score begins after a fresh 30-second buffer.',
                    ),
                  ),
                );
              }
            },
          ),
          const Text('Reference', style: TextStyle(color: Colors.white54)),
          DropdownButton<String>(
            value:
                selectedReference != null &&
                    referenceLabels.contains(selectedReference)
                ? selectedReference
                : '__none__',
            dropdownColor: const Color(0xFF1E293B),
            style: const TextStyle(color: Colors.white),
            items: [
              const DropdownMenuItem(value: '__none__', child: Text('None')),
              ...referenceLabels.map(
                (label) => DropdownMenuItem(value: label, child: Text(label)),
              ),
            ],
            onChanged: (value) {
              if (value == null) return;
              settings.update(
                (settings) => settings.nidraScoringReferenceLabel = value,
              );
              _module.stimService.resetForScoringMontageChange();
              if (isRecording) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Reference changed. Prior epochs are retained; '
                      'the scorer is restarting its 30-second buffer.',
                    ),
                  ),
                );
              }
            },
          ),
          Text(
            isRecording
                ? 'May be changed now; prior scores remain on the timeline'
                : 'Only capture-enabled EEG channels are listed',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildStageProbabilities(SleepScoreResult? score) {
    if (score != null && !score.isReliable) {
      return const Text(
        'Artifact epoch — no sleep stage or probability assigned',
        style: TextStyle(
          color: Colors.orangeAccent,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    final values = <(String, double, SleepStage)>[
      ('W', score?.probWake ?? 0, SleepStage.wake),
      ('N1', score?.probN1 ?? 0, SleepStage.n1),
      ('N2', score?.probN2 ?? 0, SleepStage.n2),
      ('N3', score?.probN3 ?? 0, SleepStage.n3),
      ('R', score?.probREM ?? 0, SleepStage.rem),
    ];
    return Row(
      children: values
          .map(
            (entry) => Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Tooltip(
                  message:
                      '${entry.$1}: ${(entry.$2 * 100).toStringAsFixed(1)}%',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${entry.$1} ${(entry.$2 * 100).round()}%',
                        style: TextStyle(
                          color: score?.stage == entry.$3
                              ? _getStageColor(entry.$3)
                              : Colors.white54,
                          fontSize: 10,
                          fontWeight: score?.stage == entry.$3
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      const SizedBox(height: 2),
                      LinearProgressIndicator(
                        value: entry.$2.clamp(0.0, 1.0),
                        minHeight: 3,
                        color: _getStageColor(entry.$3),
                        backgroundColor: Colors.white10,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
          .toList(growable: false),
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
    return ListenableBuilder(
      listenable: stim,
      builder: (context, _) {
        Widget numberSetting(
          String label,
          int value,
          int minimum,
          int maximum,
          ValueChanged<int> onChanged, {
          String suffix = 's',
        }) {
          return SizedBox(
            width: 190,
            child: TextFormField(
              key: ValueKey('$label:$value'),
              initialValue: value.toString(),
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(labelText: label, suffixText: suffix),
              onFieldSubmitted: (text) {
                final parsed = int.tryParse(text);
                if (parsed == null) return;
                onChanged(parsed.clamp(minimum, maximum));
                _persistStimSettings(stim);
              },
            ),
          );
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: stim.enabled ? lightTeal : Colors.white12,
                    width: stim.enabled ? 2 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.volume_up,
                      color: stim.enabled ? lightTeal : Colors.white54,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Auditory Closed-Loop Stimulation',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'Enable monitoring and configure the stimulus below.',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: stim.enabled,
                      activeThumbColor: lightTeal,
                      onChanged: (value) {
                        stim.setEnabled(value);
                        _persistStimSettings(stim);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: stim.flashOn
                      ? const Color(0xFF7C2D12)
                      : const Color(0xFF111827),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: stim.notificationActive
                        ? Colors.orangeAccent
                        : Colors.white12,
                    width: stim.notificationActive ? 3 : 1,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          stim.isStimulating
                              ? Icons.graphic_eq
                              : stim.notificationActive
                              ? Icons.notifications_active
                              : Icons.monitor_heart_outlined,
                          color: stim.isStimulating
                              ? const Color(0xFF10B981)
                              : stim.notificationActive
                              ? Colors.orangeAccent
                              : Colors.white54,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            stim.statusText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${stim.totalStimBursts} burst(s)',
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ],
                    ),
                    if (stim.conditionActive) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text(
                            _formatDuration(
                              Duration(seconds: stim.conditionElapsedSecs),
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              fontFeatures: [ui.FontFeature.tabularFigures()],
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: LinearProgressIndicator(
                              value:
                                  (stim.conditionElapsedSecs /
                                          stim.stableDurationSecs)
                                      .clamp(0.0, 1.0),
                              minHeight: 8,
                              color: stim.conditionMet
                                  ? Colors.orangeAccent
                                  : lightTeal,
                              backgroundColor: Colors.white12,
                            ),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: stim.snooze,
                            icon: const Icon(Icons.snooze),
                            label: Text(
                              'Snooze ${stim.refractorySecs ~/ 60} min',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Trigger & stimulus',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 190,
                          child: DropdownButtonFormField<String>(
                            initialValue: stim.mode,
                            dropdownColor: const Color(0xFF111827),
                            decoration: const InputDecoration(
                              labelText: 'Trigger mode',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'automatic',
                                child: Text('Automatic stimulus'),
                              ),
                              DropdownMenuItem(
                                value: 'manual',
                                child: Text('Manual guidance'),
                              ),
                            ],
                            onChanged: (mode) {
                              if (mode == null) return;
                              stim.setMode(mode);
                              _persistStimSettings(stim);
                            },
                          ),
                        ),
                        SizedBox(
                          width: 190,
                          child: DropdownButtonFormField<SleepStage>(
                            initialValue: stim.targetStage,
                            dropdownColor: const Color(0xFF111827),
                            decoration: const InputDecoration(
                              labelText: 'Target sleep stage',
                            ),
                            items: SleepStage.values
                                .map(
                                  (stage) => DropdownMenuItem(
                                    value: stage,
                                    child: Text(stage.label),
                                  ),
                                )
                                .toList(),
                            onChanged: (stage) {
                              if (stage == null) return;
                              stim.setTargetStage(stage);
                              _persistStimSettings(stim);
                            },
                          ),
                        ),
                        FilterChip(
                          label: const Text('Notification beep'),
                          avatar: const Icon(Icons.volume_up, size: 18),
                          selected: stim.notifyBeep,
                          onSelected: (value) {
                            stim.setNotifyBeep(value);
                            _persistStimSettings(stim);
                          },
                        ),
                        FilterChip(
                          label: const Text('Screen flash'),
                          avatar: const Icon(Icons.flash_on, size: 18),
                          selected: stim.notifyFlash,
                          onSelected: (value) {
                            stim.setNotifyFlash(value);
                            _persistStimSettings(stim);
                          },
                        ),
                        if (stim.notifyBeep)
                          numberSetting(
                            'Notification interval',
                            stim.notificationIntervalSecs,
                            1,
                            60,
                            stim.setNotificationInterval,
                          ),
                        SizedBox(
                          width: 220,
                          child: DropdownButtonFormField<String>(
                            initialValue: stim.stimType,
                            dropdownColor: const Color(0xFF111827),
                            decoration: const InputDecoration(
                              labelText: 'Stimulus type',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'beep',
                                child: Text('System beep'),
                              ),
                              DropdownMenuItem(
                                value: 'tone',
                                child: Text('Pure tone'),
                              ),
                              DropdownMenuItem(
                                value: 'audio',
                                child: Text('Custom audio file'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value == null) return;
                              stim.setStimType(value);
                              _persistStimSettings(stim);
                            },
                          ),
                        ),
                        if (stim.stimType == 'tone') ...[
                          SizedBox(
                            width: 190,
                            child: TextFormField(
                              key: ValueKey(
                                'frequency:${stim.toneFrequencyHz}',
                              ),
                              initialValue: stim.toneFrequencyHz
                                  .toStringAsFixed(0),
                              keyboardType: TextInputType.number,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                labelText: 'Tone frequency',
                                suffixText: 'Hz',
                              ),
                              onFieldSubmitted: (text) {
                                final value = double.tryParse(text);
                                if (value == null) return;
                                stim.setToneFrequency(value);
                                _persistStimSettings(stim);
                              },
                            ),
                          ),
                          numberSetting(
                            'Tone duration',
                            stim.toneDurationMs,
                            20,
                            5000,
                            stim.setToneDuration,
                            suffix: 'ms',
                          ),
                        ],
                      ],
                    ),
                    if (stim.stimType == 'audio') ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              stim.audioFilePath.isEmpty
                                  ? 'No audio file selected'
                                  : stim.audioFilePath,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: stim.audioFilePath.isEmpty
                                    ? Colors.white38
                                    : Colors.white70,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: () => _pickStimAudio(stim),
                            icon: const Icon(Icons.audio_file),
                            label: const Text('Choose audio'),
                          ),
                        ],
                      ),
                      const Text(
                        'The path is saved in the shared JSON. Copy the same audio '
                        'file to each tablet and choose it once if its local path differs.',
                        style: TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Text(
                      'Volume ${(stim.volume * 100).round()}%',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    Slider(
                      value: stim.volume,
                      activeColor: lightTeal,
                      onChanged: stim.setVolume,
                      onChangeEnd: (_) => _persistStimSettings(stim),
                    ),
                    Text(
                      'Minimum stage probability '
                      '${(stim.minProbability * 100).round()}%',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    Slider(
                      value: stim.minProbability,
                      min: 0.1,
                      max: 1,
                      divisions: 18,
                      activeColor: lightTeal,
                      onChanged: stim.setMinProbability,
                      onChangeEnd: (_) => _persistStimSettings(stim),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      children: [
                        numberSetting(
                          'Stable stage duration',
                          stim.stableDurationSecs,
                          5,
                          300,
                          stim.setStableDuration,
                        ),
                        numberSetting(
                          'Burst duration',
                          stim.maxDurationSecs,
                          2,
                          60,
                          stim.setMaxDuration,
                        ),
                        numberSetting(
                          'Stimulus interval',
                          stim.intervalSecs,
                          1,
                          10,
                          stim.setInterval,
                        ),
                        numberSetting(
                          'Post-stim / snooze period',
                          stim.refractorySecs,
                          10,
                          3600,
                          stim.setRefractory,
                        ),
                        numberSetting(
                          'EDF stimulus marker',
                          _module.stimulusMarkerCode,
                          1,
                          32767,
                          (value) {
                            _module.stimulusMarkerCode = value;
                            _persistStimSettings(stim);
                          },
                          suffix: 'code',
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: () async {
                        await stim.sendStimulus();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(stim.statusText)),
                        );
                      },
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Send Stimulus'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickStimAudio(AuditoryStimService stim) async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose Train NIDRA stimulus audio',
      type: FileType.custom,
      allowedExtensions: const ['wav', 'mp3', 'm4a', 'aac', 'ogg'],
    );
    final path = picked?.files.single.path;
    if (path == null) return;
    stim.setAudioFilePath(path);
    _persistStimSettings(stim);
  }

  void _persistStimSettings(AuditoryStimService stim) {
    context.read<SettingsService>().update((settings) {
      settings.nidraStimEnabled = stim.enabled;
      settings.nidraStimTargetStage = stim.targetStage.name;
      settings.nidraStimType = stim.stimType;
      settings.nidraStimToneFrequencyHz = stim.toneFrequencyHz;
      settings.nidraStimToneDurationMs = stim.toneDurationMs;
      settings.nidraStimAudioFilePath = stim.audioFilePath;
      settings.nidraStimVolume = stim.volume;
      settings.nidraStimMinProbability = stim.minProbability;
      settings.nidraStimStableDurationSecs = stim.stableDurationSecs;
      settings.nidraStimMaxDurationSecs = stim.maxDurationSecs;
      settings.nidraStimIntervalSecs = stim.intervalSecs;
      settings.nidraStimRefractorySecs = stim.refractorySecs;
      settings.nidraStimMode = stim.mode;
      settings.nidraStimNotifyBeep = stim.notifyBeep;
      settings.nidraStimNotifyFlash = stim.notifyFlash;
      settings.nidraStimNotificationIntervalSecs =
          stim.notificationIntervalSecs;
      settings.nidraStimMarkerCode = _module.stimulusMarkerCode;
    });
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
  _HypnogramPainter({required this.scores, required this.recordingStart});

  final List<SleepScoreResult> scores;
  final DateTime? recordingStart;
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

    const leftMargin = 42.0;
    const bottomMargin = 22.0;
    final plotWidth = math.max(1.0, size.width - leftMargin);
    final plotHeight = math.max(1.0, size.height - bottomMargin);
    final rowH = plotHeight / stages.length;
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..strokeWidth = 1;

    for (var i = 0; i <= stages.length; i++) {
      final y = i * rowH;
      canvas.drawLine(Offset(leftMargin, y), Offset(size.width, y), gridPaint);
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

    final elapsedSeconds = math.max(30, scores.length * 30);
    for (var tick = 0; tick <= 4; tick++) {
      final fraction = tick / 4;
      final x = leftMargin + plotWidth * fraction;
      canvas.drawLine(Offset(x, 0), Offset(x, plotHeight), gridPaint);
      final seconds = (elapsedSeconds * fraction).round();
      final time = recordingStart?.add(Duration(seconds: seconds));
      final text = time == null
          ? _elapsedLabel(seconds)
          : '${time.hour.toString().padLeft(2, '0')}:'
                '${time.minute.toString().padLeft(2, '0')}';
      final label = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(color: Colors.white54, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(
          (x - label.width / 2).clamp(leftMargin, size.width - label.width),
          plotHeight + 5,
        ),
      );
    }

    final stepX = plotWidth / math.max(1, scores.length - 1);
    final path = Path();
    final paint = Paint()
      ..color = const Color(0xFF14B8A6)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final artifactPaint = Paint()
      ..color = const Color(0xFFF59E0B).withOpacity(0.32)
      ..strokeWidth = math.max(2, stepX * 0.55);

    var drawing = false;
    for (var i = 0; i < scores.length; i++) {
      final x = leftMargin + i * stepX;
      if (!scores[i].isReliable) {
        canvas.drawLine(Offset(x, 0), Offset(x, plotHeight), artifactPaint);
        drawing = false;
        continue;
      }
      final stageIdx = stages.indexOf(scores[i].stage);
      final y = (stageIdx + 0.5) * rowH;
      if (!drawing) {
        path.moveTo(x, y);
        drawing = true;
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
      old.scores.length != scores.length ||
      old.recordingStart != recordingStart;

  static String _elapsedLabel(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return hours > 0
        ? '${hours}h${minutes.toString().padLeft(2, '0')}'
        : '${minutes}m';
  }
}

class _StageProbabilityPainter extends CustomPainter {
  _StageProbabilityPainter({
    required this.scores,
    required this.stages,
    required this.recordingStart,
    required this.colors,
  });

  final List<SleepScoreResult> scores;
  final Set<SleepStage> stages;
  final DateTime? recordingStart;
  final Map<SleepStage, Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (scores.isEmpty || stages.isEmpty) return;
    const leftMargin = 40.0;
    const bottomMargin = 22.0;
    final plotWidth = math.max(1.0, size.width - leftMargin);
    final plotHeight = math.max(1.0, size.height - bottomMargin);
    final grid = Paint()
      ..color = Colors.white.withOpacity(0.08)
      ..strokeWidth = 1;

    for (var tick = 0; tick <= 4; tick++) {
      final probability = tick / 4;
      final y = plotHeight * (1 - probability);
      canvas.drawLine(Offset(leftMargin, y), Offset(size.width, y), grid);
      final label = TextPainter(
        text: TextSpan(
          text: '${(probability * 100).round()}%',
          style: const TextStyle(color: Colors.white54, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(2, y - label.height / 2));
    }

    final elapsedSeconds = math.max(30, scores.length * 30);
    for (var tick = 0; tick <= 4; tick++) {
      final fraction = tick / 4;
      final x = leftMargin + plotWidth * fraction;
      canvas.drawLine(Offset(x, 0), Offset(x, plotHeight), grid);
      final seconds = (elapsedSeconds * fraction).round();
      final time = recordingStart?.add(Duration(seconds: seconds));
      final text = time == null
          ? _HypnogramPainter._elapsedLabel(seconds)
          : '${time.hour.toString().padLeft(2, '0')}:'
                '${time.minute.toString().padLeft(2, '0')}';
      final label = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(color: Colors.white54, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(
          (x - label.width / 2).clamp(leftMargin, size.width - label.width),
          plotHeight + 5,
        ),
      );
    }

    final stepX = plotWidth / math.max(1, scores.length - 1);
    final artifactPaint = Paint()
      ..color = const Color(0xFFF59E0B).withOpacity(0.28)
      ..strokeWidth = math.max(2, stepX * 0.55);
    for (var index = 0; index < scores.length; index++) {
      if (!scores[index].isReliable) {
        final x = leftMargin + index * stepX;
        canvas.drawLine(Offset(x, 0), Offset(x, plotHeight), artifactPaint);
      }
    }

    for (final stage in SleepStage.values.where(stages.contains)) {
      final paint = Paint()
        ..color = colors[stage] ?? Colors.white
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      var drawing = false;
      for (var index = 0; index < scores.length; index++) {
        if (!scores[index].isReliable) {
          drawing = false;
          continue;
        }
        final x = leftMargin + index * stepX;
        final y =
            plotHeight *
            (1 - _probabilityForStage(scores[index], stage).clamp(0.0, 1.0));
        if (!drawing) {
          path.moveTo(x, y);
          drawing = true;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
      if (scores.length == 1 && scores.first.isReliable) {
        final y =
            plotHeight *
            (1 - _probabilityForStage(scores.first, stage).clamp(0.0, 1.0));
        canvas.drawCircle(
          Offset(leftMargin, y),
          3,
          Paint()..color = colors[stage] ?? Colors.white,
        );
      }
    }
  }

  static double _probabilityForStage(
    SleepScoreResult score,
    SleepStage stage,
  ) => switch (stage) {
    SleepStage.wake => score.probWake,
    SleepStage.n1 => score.probN1,
    SleepStage.n2 => score.probN2,
    SleepStage.n3 => score.probN3,
    SleepStage.rem => score.probREM,
  };

  @override
  bool shouldRepaint(_StageProbabilityPainter old) =>
      old.scores.length != scores.length ||
      old.recordingStart != recordingStart ||
      old.stages.length != stages.length ||
      !old.stages.containsAll(stages);
}
