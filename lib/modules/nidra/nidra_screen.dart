import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/alert_service.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/models/module_type.dart';
import '../../core/models/sleep_score.dart';
import '../../core/models/eeg_sample.dart';
import '../../core/models/device_profile.dart';
import '../../core/models/stream_marker.dart';
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
    final savedPlaylist = settings.nidraStimPlaylist
        .map((m) => StimulusCueItem.fromJson(m))
        .toList();
    if (savedPlaylist.isNotEmpty) {
      _module.stimService.setPlaylist(
        savedPlaylist,
        selectedIndex: settings.nidraStimSelectedCueIndex,
        orderMode: settings.nidraStimOrderMode,
      );
    }

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
                          if (isRecording) ...[
                            const SizedBox(height: 8),
                            _buildRecordingQuickActions(
                              sessionManager,
                              stimService,
                              settings,
                            ),
                          ],
                          const SizedBox(height: 12),

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
        _buildSavingChannelsBanner(
          context: context,
          channelConfig: channelConfig,
          eegService: eegService,
          isRecording: isRecording,
          activeColor: lightTeal,
        ),
        const SizedBox(height: 10),
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
              height: compact ? 290 : 165,
              child: Flex(
                direction: compact ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
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
                                    ? 'LEADS OFF'
                                    : (score?.stage.label ?? 'WAITING'),
                                style: TextStyle(
                                  color: stageColor,
                                  fontSize: poorSignal ? 28 : 38,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  score != null
                                      ? (poorSignal
                                            ? 'Poor signal (${(score.artifactRatio * 100).round()}% art) • Check leads'
                                            : '${(score.confidence * 100).toStringAsFixed(1)}% conf')
                                      : 'Waiting for epochs...',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.7),
                                    fontSize: 14,
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
                                  markers: module.sessionManager.markerLog,
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
                                  markers: module.sessionManager.markerLog,
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

  Widget _buildRecordingQuickActions(
    SessionManager sessionManager,
    AuditoryStimService stimService,
    SettingsService settings,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: stimService.isPlayingAudio
                  ? const Color(0xFFDC2626)
                  : const Color(0xFFF59E0B),
              foregroundColor: stimService.isPlayingAudio ? Colors.white : Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () async {
              if (stimService.isPlayingAudio) {
                await stimService.stopPlayback();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Audio stimulus playback stopped'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
                return;
              }
              await stimService.sendStimulus();
              if (mounted) {
                final cue = stimService.currentCueItem;
                final desc = cue != null
                    ? '${cue.name} (Marker ${cue.markerCode})'
                    : stimService.stimType;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Stimulus triggered: $desc'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            icon: Icon(
              stimService.isPlayingAudio ? Icons.stop_circle : Icons.bolt,
              size: 18,
              color: stimService.isPlayingAudio ? Colors.white : Colors.black,
            ),
            label: Text(
              stimService.isPlayingAudio
                  ? 'Stop Audio'
                  : (stimService.currentCueItem != null
                      ? 'Stim: ${stimService.currentCueItem!.name}'
                      : 'Stimulus'),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: stimService.isPlayingAudio ? Colors.white : Colors.black,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Container(height: 24, width: 1, color: Colors.white24),
          const SizedBox(width: 12),
          const Text(
            'Markers:',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: settings.activeManualMarkers.map((markerDef) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: markerDef.color,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(60, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () {
                        sessionManager.recordEvent(
                          markerDef.name,
                          markerDef.code,
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Tagged ${markerDef.name} (${markerDef.code})',
                            ),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Text(
                        '${markerDef.name} (${markerDef.code})',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSavingChannelsBanner({
    required BuildContext context,
    required ChannelConfigService channelConfig,
    required AcquisitionService eegService,
    required bool isRecording,
    required Color activeColor,
  }) {
    final labels = eegService.displayChannelLabels(eegService.channelCount);
    final enabled = eegService.recordingEnabledChannels(channelConfig.enabled);
    final activeCount = enabled.where((b) => b).length;
    final activeLabels = [
      for (var i = 0; i < labels.length; i++)
        if (i < enabled.length && enabled[i]) labels[i],
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF172033),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: activeColor.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.save_outlined, color: activeColor, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text(
                      'SAVING CHANNELS TO EDF',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: activeColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$activeCount of ${labels.length} active @ ${eegService.sampleRate.toInt()} Hz',
                        style: TextStyle(
                          color: activeColor,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  activeLabels.isEmpty
                      ? 'No channels enabled'
                      : activeLabels.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: activeColor,
              side: BorderSide(color: activeColor.withValues(alpha: 0.5)),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: isRecording
                ? null
                : () => _showChannelConfigDialog(
                      context,
                      channelConfig,
                      eegService,
                    ),
            icon: const Icon(Icons.tune, size: 16),
            label: Text(isRecording ? 'Config Locked' : 'Configure Channels'),
          ),
        ],
      ),
    );
  }

  Future<void> _showChannelConfigDialog(
    BuildContext context,
    ChannelConfigService channelConfig,
    AcquisitionService eegService,
  ) async {
    final labels = List<String>.of(channelConfig.labels);
    final enabled = List<bool>.of(channelConfig.enabled);
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final activeCount = enabled.where((b) => b).length;
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: Row(
              children: [
                const Icon(Icons.tune, color: Color(0xFF14B8A6)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'EDF Saving Channels ($activeCount/${labels.length} active)',
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 500,
              height: 400,
              child: Column(
                children: [
                  const Text(
                    'All enabled channels will be saved into the session EDF file. '
                    'TinySleepNet auto-scoring will use the derivation chosen in the Scoring Montage.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const Divider(color: Colors.white24),
                  Expanded(
                    child: ListView.builder(
                      itemCount: labels.length,
                      itemBuilder: (context, index) {
                        final isEnabled =
                            index < enabled.length ? enabled[index] : true;
                        return CheckboxListTile(
                          dense: true,
                          title: Text(
                            'Ch ${index + 1}: ${labels[index]}',
                            style: TextStyle(
                              color: isEnabled ? Colors.white : Colors.white38,
                              fontWeight:
                                  isEnabled ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                          value: isEnabled,
                          activeColor: const Color(0xFF14B8A6),
                          onChanged: (val) {
                            if (val == null) return;
                            channelConfig.setEnabled(index, val);
                            setDialogState(() {
                              if (index < enabled.length) enabled[index] = val;
                            });
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  channelConfig.applyDefaults();
                  Navigator.of(dialogCtx).pop();
                },
                child: const Text(
                  'Reset Defaults',
                  style: TextStyle(color: Colors.orangeAccent),
                ),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF14B8A6),
                  foregroundColor: Colors.black,
                ),
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('Done'),
              ),
            ],
          );
        },
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
                          width: 215,
                          child: DropdownButtonFormField<String>(
                            isExpanded: true,
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
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: lightTeal.withOpacity(0.35),
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.queue_music, color: lightTeal, size: 22),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Stimulus Sound Library (${stim.playlist.length} cues)',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                                // Order mode: Sequential vs Randomized
                                Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E293B),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ChoiceChip(
                                        label: const Text('Sequential 1→2→3'),
                                        selected: stim.orderMode == 'sequential',
                                        onSelected: (val) {
                                          if (val) {
                                            stim.setOrderMode('sequential');
                                            _persistStimSettings(stim);
                                          }
                                        },
                                        selectedColor: lightTeal.withOpacity(0.3),
                                        labelStyle: TextStyle(
                                          color: stim.orderMode == 'sequential'
                                              ? lightTeal
                                              : Colors.white70,
                                          fontSize: 12,
                                          fontWeight: stim.orderMode == 'sequential'
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      ChoiceChip(
                                        label: const Text('Randomized ⚄'),
                                        selected: stim.orderMode == 'random',
                                        onSelected: (val) {
                                          if (val) {
                                            stim.setOrderMode('random');
                                            _persistStimSettings(stim);
                                          }
                                        },
                                        selectedColor: lightTeal.withOpacity(0.3),
                                        labelStyle: TextStyle(
                                          color: stim.orderMode == 'random'
                                              ? lightTeal
                                              : Colors.white70,
                                          fontSize: 12,
                                          fontWeight: stim.orderMode == 'random'
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // Toolbar for library
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: lightTeal,
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                  ),
                                  onPressed: () => _pickPlaylistFiles(stim),
                                  icon: const Icon(Icons.file_upload, size: 16),
                                  label: const Text('Add Sound Files'),
                                ),
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF334155),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                  ),
                                  onPressed: () => _importFolderCues(stim),
                                  icon: const Icon(Icons.folder_open, size: 16),
                                  label: const Text('Import Folder'),
                                ),
                                if (stim.playlist.isNotEmpty)
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFFFCA5A5),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
                                    ),
                                    onPressed: () => _confirmClearPlaylist(stim),
                                    icon: const Icon(Icons.delete_sweep, size: 16),
                                    label: const Text('Clear Library'),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (stim.playlist.isEmpty)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(22),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E293B),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Column(
                                  children: [
                                    const Icon(
                                      Icons.audio_file_outlined,
                                      color: Colors.white38,
                                      size: 38,
                                    ),
                                    const SizedBox(height: 8),
                                    const Text(
                                      'No audio cues in playlist',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Tap "Import Folder" to select a folder of word/sound files, or "Add Sound Files" to select individual audio files.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Colors.white38,
                                        fontSize: 12,
                                      ),
                                    ),
                                    if (stim.audioFilePath.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      Text(
                                        'Default fallback: ${stim.audioFilePath.split(Platform.pathSeparator).last}',
                                        style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              )
                            else ...[
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxHeight: 320),
                                child: ListView.separated(
                                  shrinkWrap: true,
                                  itemCount: stim.playlist.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 6),
                                  itemBuilder: (context, index) {
                                    final cue = stim.playlist[index];
                                    final isSelected =
                                        index == stim.selectedCueIndex;
                                    return Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(10),
                                        onTap: () {
                                          stim.selectCue(index);
                                          _persistStimSettings(stim);
                                        },
                                        child: AnimatedContainer(
                                          duration: const Duration(
                                            milliseconds: 200,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isSelected
                                                ? const Color(0xFF0F766E)
                                                    .withOpacity(0.28)
                                                : const Color(0xFF1E293B),
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            border: Border.all(
                                              color: isSelected
                                                  ? lightTeal
                                                  : Colors.white10,
                                              width: isSelected ? 2 : 1,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              // Up/Down arrows
                                              Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  InkWell(
                                                    onTap: index > 0
                                                        ? () {
                                                            stim.reorderCue(
                                                              index,
                                                              index - 1,
                                                            );
                                                            _persistStimSettings(
                                                              stim,
                                                            );
                                                          }
                                                        : null,
                                                    child: Icon(
                                                      Icons.keyboard_arrow_up,
                                                      size: 18,
                                                      color: index > 0
                                                          ? Colors.white70
                                                          : Colors.white24,
                                                    ),
                                                  ),
                                                  InkWell(
                                                    onTap: index <
                                                            stim.playlist.length -
                                                                1
                                                        ? () {
                                                            stim.reorderCue(
                                                              index,
                                                              index + 2,
                                                            );
                                                            _persistStimSettings(
                                                              stim,
                                                            );
                                                          }
                                                        : null,
                                                    child: Icon(
                                                      Icons.keyboard_arrow_down,
                                                      size: 18,
                                                      color: index <
                                                              stim.playlist
                                                                      .length -
                                                                  1
                                                          ? Colors.white70
                                                          : Colors.white24,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(width: 8),
                                              // Position badge
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 7,
                                                  vertical: 3,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: isSelected
                                                      ? lightTeal
                                                      : const Color(0xFF334155),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  '#${index + 1}',
                                                  style: TextStyle(
                                                    color: isSelected
                                                        ? Colors.black
                                                        : Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              // Name & Details
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Flexible(
                                                          child: Text(
                                                            cue.name,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                              color: isSelected
                                                                  ? lightTeal
                                                                  : Colors.white,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                              fontSize: 13,
                                                            ),
                                                          ),
                                                        ),
                                                        if (isSelected) ...[
                                                          const SizedBox(
                                                            width: 6,
                                                          ),
                                                          Container(
                                                            padding:
                                                                const EdgeInsets
                                                                    .symmetric(
                                                              horizontal: 6,
                                                              vertical: 1.5,
                                                            ),
                                                            decoration:
                                                                BoxDecoration(
                                                              color: stim
                                                                      .isPlayingAudio
                                                                  ? const Color(
                                                                      0xFFDC2626,
                                                                    )
                                                                  : const Color(
                                                                      0xFF10B981,
                                                                    ),
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                        4,
                                                                      ),
                                                            ),
                                                            child: Text(
                                                              stim.isPlayingAudio
                                                                  ? 'PLAYING'
                                                                  : 'QUEUED',
                                                              style:
                                                                  const TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .bold,
                                                                fontSize: 9,
                                                              ),
                                                            ),
                                                          ),
                                                        ],
                                                      ],
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      'Played ${cue.playCount}x • Tap row to manually select for next stim',
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        color: Colors.white38,
                                                        fontSize: 10,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              // Clickable Marker Code Chip
                                              InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                onTap: () => _editCueMarkerCode(
                                                  stim,
                                                  index,
                                                ),
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0xFF1E293B,
                                                    ),
                                                    border: Border.all(
                                                      color: const Color(
                                                        0xFF38BDF8,
                                                      ),
                                                      width: 1,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          6,
                                                        ),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Text(
                                                        'Marker: ${cue.markerCode}',
                                                        style: const TextStyle(
                                                          color: Color(
                                                            0xFF38BDF8,
                                                          ),
                                                          fontSize: 11,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 4),
                                                      const Icon(
                                                        Icons.edit,
                                                        size: 11,
                                                        color: Color(
                                                          0xFF38BDF8,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              // Remove item
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.close,
                                                  size: 16,
                                                  color: Colors.white38,
                                                ),
                                                tooltip: 'Remove cue',
                                                onPressed: () {
                                                  stim.removeCue(index);
                                                  _persistStimSettings(stim);
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ],
                        ),
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
                          'Base stimulus marker',
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
                    const SizedBox(height: 20),
                    // Unified Primary Action Button (transforms to Stop when audio is playing)
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: stim.isPlayingAudio
                          ? ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFDC2626), // Eye-catching Red
                                foregroundColor: Colors.white,
                                elevation: 8,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: () async {
                                await stim.stopPlayback();
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Audio stimulus playback stopped.'),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.stop_circle, size: 26),
                              label: const Text(
                                'STOP AUDIO PLAYBACK',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            )
                          : FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: lightTeal,
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onPressed: () async {
                                await stim.sendStimulus();
                                if (!context.mounted) return;
                                final cue = stim.currentCueItem;
                                final desc = cue != null
                                    ? '${cue.name} (Marker ${cue.markerCode})'
                                    : stim.stimType;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Stimulus triggered: $desc'),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.play_arrow, size: 24),
                              label: Text(
                                stim.currentCueItem != null
                                    ? 'Send Stimulus: "${stim.currentCueItem!.name}" (Marker: ${stim.currentCueItem!.markerCode})'
                                    : 'Send Stimulus (${stim.stimType})',
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
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

  Future<void> _pickPlaylistFiles(AuditoryStimService stim) async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select audio cue files for playlist',
      type: FileType.custom,
      allowMultiple: true,
      allowedExtensions: const ['wav', 'mp3', 'm4a', 'aac', 'ogg'],
    );
    if (picked == null || picked.files.isEmpty) return;

    final docDir = await getApplicationDocumentsDirectory();
    final stimDir = Directory('${docDir.path}/stim_audio');
    if (!await stimDir.exists()) {
      await stimDir.create(recursive: true);
    }

    final newItems = <StimulusCueItem>[];
    var nextMarkerCode = _module.stimulusMarkerCode + stim.playlist.length;

    for (final file in picked.files) {
      final path = file.path;
      if (path == null) continue;
      String destPath = path;
      try {
        final dest = '${stimDir.path}/${file.name}';
        await File(path).copy(dest);
        destPath = dest;
      } catch (e) {
        debugPrint('[NidraScreen] Error copying ${file.name}: $e');
      }
      newItems.add(
        StimulusCueItem(
          id: '${DateTime.now().microsecondsSinceEpoch}_${file.name}',
          name: file.name,
          filePath: destPath,
          markerCode: nextMarkerCode++,
        ),
      );
    }
    stim.addCues(newItems);
    _persistStimSettings(stim);
  }

  Future<void> _importFolderCues(AuditoryStimService stim) async {
    final selectedDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select folder containing audio cue files',
    );
    if (selectedDir == null) return;

    final dir = Directory(selectedDir);
    if (!await dir.exists()) return;

    final docDir = await getApplicationDocumentsDirectory();
    final stimDir = Directory('${docDir.path}/stim_audio');
    if (!await stimDir.exists()) {
      await stimDir.create(recursive: true);
    }

    final audioExtensions = {'.wav', '.mp3', '.m4a', '.aac', '.ogg'};
    final files = dir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) {
          final ext = f.path.contains('.')
              ? f.path.substring(f.path.lastIndexOf('.')).toLowerCase()
              : '';
          return audioExtensions.contains(ext);
        })
        .toList();

    files.sort((a, b) {
      final nameA = a.path.split(Platform.pathSeparator).last;
      final nameB = b.path.split(Platform.pathSeparator).last;
      return nameA.compareTo(nameB);
    });

    if (files.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No audio files (.wav, .mp3, .m4a) found in selected folder.',
            ),
          ),
        );
      }
      return;
    }

    final newItems = <StimulusCueItem>[];
    var nextMarkerCode = _module.stimulusMarkerCode + stim.playlist.length;

    for (final file in files) {
      final name = file.path.split(Platform.pathSeparator).last;
      String destPath = file.path;
      try {
        final dest = '${stimDir.path}/$name';
        await file.copy(dest);
        destPath = dest;
      } catch (e) {
        debugPrint('[NidraScreen] Error copying $name: $e');
      }
      newItems.add(
        StimulusCueItem(
          id: '${DateTime.now().microsecondsSinceEpoch}_$name',
          name: name,
          filePath: destPath,
          markerCode: nextMarkerCode++,
        ),
      );
    }
    stim.addCues(newItems);
    _persistStimSettings(stim);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${newItems.length} audio file(s) into library.',
          ),
        ),
      );
    }
  }

  Future<void> _editCueMarkerCode(AuditoryStimService stim, int index) async {
    final cue = stim.playlist[index];
    final controller = TextEditingController(text: cue.markerCode.toString());
    final newCode = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(
          'Marker Code for "${cue.name}"',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This integer code will be stamped into the EDF marker channel and recorded in the CSV marker log whenever this cue is presented.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'EDF Marker Code (1–32767)',
                hintText: 'e.g. 41',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final val = int.tryParse(controller.text.trim());
              Navigator.of(context).pop(val);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newCode != null && newCode > 0) {
      stim.updateCueMarkerCode(index, newCode);
      _persistStimSettings(stim);
    }
  }

  Future<void> _confirmClearPlaylist(AuditoryStimService stim) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Clear Sound Library?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'This will remove all cues from the active playlist library. Audio files will remain on disk.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      stim.clearPlaylist();
      _persistStimSettings(stim);
    }
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
      settings.nidraStimPlaylist =
          stim.playlist.map((cue) => cue.toJson()).toList();
      settings.nidraStimOrderMode = stim.orderMode;
      settings.nidraStimSelectedCueIndex = stim.selectedCueIndex;
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
  _HypnogramPainter({
    required this.scores,
    required this.recordingStart,
    this.markers = const [],
  });

  final List<SleepScoreResult> scores;
  final DateTime? recordingStart;
  final List<StreamMarker> markers;
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

    // Draw event markers (stimuli and manual markers) along the timeline
    if (recordingStart != null && markers.isNotEmpty) {
      final markerLinePaint = Paint()..strokeWidth = 1.5;
      for (final marker in markers) {
        final elapsed =
            marker.receivedAt.difference(recordingStart!).inMilliseconds /
            1000.0;
        if (elapsed < 0 || elapsed > elapsedSeconds) continue;
        final x = leftMargin + plotWidth * (elapsed / elapsedSeconds);
        final isStim = marker.value.toLowerCase().contains('stim');
        final markerColor =
            isStim ? const Color(0xFFFBBF24) : const Color(0xFF38BDF8);
        markerLinePaint.color = markerColor.withValues(alpha: 0.75);
        canvas.drawLine(Offset(x, 0), Offset(x, plotHeight), markerLinePaint);

        final pin = Path()
          ..moveTo(x, 0)
          ..lineTo(x - 3.5, 6)
          ..lineTo(x + 3.5, 6)
          ..close();
        canvas.drawPath(pin, Paint()..color = markerColor);
      }
    }
  }

  @override
  bool shouldRepaint(_HypnogramPainter old) =>
      old.scores.length != scores.length ||
      old.recordingStart != recordingStart ||
      old.markers.length != markers.length;

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
    this.markers = const [],
  });

  final List<SleepScoreResult> scores;
  final Set<SleepStage> stages;
  final DateTime? recordingStart;
  final Map<SleepStage, Color> colors;
  final List<StreamMarker> markers;

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

    // Draw event markers (stimuli and manual markers) along the probability plot timeline
    if (recordingStart != null && markers.isNotEmpty) {
      final markerLinePaint = Paint()..strokeWidth = 1.5;
      for (final marker in markers) {
        final elapsed =
            marker.receivedAt.difference(recordingStart!).inMilliseconds /
            1000.0;
        if (elapsed < 0 || elapsed > elapsedSeconds) continue;
        final x = leftMargin + plotWidth * (elapsed / elapsedSeconds);
        final isStim = marker.value.toLowerCase().contains('stim');
        final markerColor =
            isStim ? const Color(0xFFFBBF24) : const Color(0xFF38BDF8);
        markerLinePaint.color = markerColor.withValues(alpha: 0.75);
        canvas.drawLine(Offset(x, 0), Offset(x, plotHeight), markerLinePaint);

        final pin = Path()
          ..moveTo(x, 0)
          ..lineTo(x - 3.5, 6)
          ..lineTo(x + 3.5, 6)
          ..close();
        canvas.drawPath(pin, Paint()..color = markerColor);
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
      old.markers.length != markers.length ||
      !old.stages.containsAll(stages);
}
