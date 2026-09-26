import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/lsl_config.dart';
import '../models/module_type.dart';
import '../models/device_profile.dart';
import '../models/manual_marker.dart';
import 'file_naming_service.dart';

const List<String> kDefaultEpiDomeLabels = [
  'Fp1',
  'Fp2',
  'F3',
  'F4',
  'C3',
  'Cz',
  'C4',
  'P3',
  'Pz',
  'P4',
  'O1',
  'Oz',
  'O2',
  'F7',
  'F8',
  'T3',
];
const List<String> kDefaultOrbitLabels = ['AF7', 'AF8', 'PPG'];

/// Unified settings for the entire CCS Mobile Studio app.
///
/// Persisted to `app_config.json` in the app support directory.
class SettingsService extends ChangeNotifier {
  final Completer<void> _ready = Completer<void>();

  Future<void> get ready => _ready.future;

  // ── Display & accessibility ───────────────────────────────────────────────
  double textScaleFactor = 1.0;

  // ── Device ─────────────────────────────────────────────────────────────────
  String xampPrefix = 'AXXSPU00002'; // default to user's actual device
  String orbitPrefix = 'ORBIT_';
  List<DeviceProfile> deviceProfiles = defaultDeviceProfiles();
  bool combineCompatibleStreams = true;

  // ── Reconnection ───────────────────────────────────────────────────────────
  int maxReconnectAttempts = 0; // 0 = unlimited
  int disconnectionTimeoutSeconds = 5; // watchdog timeout in seconds
  int reconnectIntervalSec = 5;
  bool autoResumeRecordingAfterReconnect = true;

  // ── EEG Display ────────────────────────────────────────────────────────────
  double waveformGain = 1.0;
  int waveformDurationSeconds = 10;
  bool notchEnabled = true;
  bool bandpassEnabled = true;
  bool autoscaleEnabled = false;
  bool stackedChannels = true;
  List<int> visibleChannels = [];
  double eegDisplayScaleUv = 150.0;
  double ecgDisplayScaleUv = 2000.0;
  double ppgDisplayScale = 100.0;
  bool waveformAutoscaleV2 = true;
  String waveformViewMode = 'rolling';
  double eegDisplayHighPassHz = 0.3;
  double eegDisplayLowPassHz = 35.0;
  double eogDisplayHighPassHz = 0.3;
  double eogDisplayLowPassHz = 15.0;
  double emgDisplayHighPassHz = 10.0;
  double emgDisplayLowPassHz = 100.0;
  double ecgDisplayHighPassHz = 0.5;
  double ecgDisplayLowPassHz = 40.0;
  double displayNotchFrequencyHz = 50.0;
  Map<String, String> displayMontageReferences = {};
  List<String> displayHiddenChannelLabels = [];
  Map<String, Map<String, dynamic>> viewerDisplayProfiles = {};
  double waveformStrokeWidth = 1.5;
  int waveformColorValue = 0xFF14B8A6;

  // Named marker banks are shared by every live waveform viewer.
  String activeMarkerProfile = 'Default';
  Map<String, List<ManualMarkerDefinition>> markerProfiles = {
    'Default': List<ManualMarkerDefinition>.from(kDefaultManualMarkers),
  };

  // ── Train NIDRA auditory closed-loop stimulation ─────────────────────────
  bool nidraStimEnabled = false;
  String nidraStimTargetStage = 'n3';
  String nidraStimType = 'tone';
  double nidraStimToneFrequencyHz = 1000.0;
  int nidraStimToneDurationMs = 300;
  String nidraStimAudioFilePath = '';
  double nidraStimVolume = 0.85;
  double nidraStimMinProbability = 0.50;
  int nidraStimStableDurationSecs = 30;
  int nidraStimMaxDurationSecs = 10;
  int nidraStimIntervalSecs = 2;
  int nidraStimRefractorySecs = 60;
  String nidraStimMode = 'automatic';
  bool nidraStimNotifyBeep = true;
  bool nidraStimNotifyFlash = true;
  int nidraStimNotificationIntervalSecs = 5;
  int nidraStimMarkerCode = 40;
  String nidraScoringSignalLabel = '';
  String nidraScoringReferenceLabel = '';
  String nidraChartMode = 'hypnogram';
  List<String> nidraProbabilityStages = ['wake', 'n2', 'n3', 'rem'];

  // ── LSL ────────────────────────────────────────────────────────────────────
  LslConfig lslConfig = const LslConfig();

  // ── Session / file naming ──────────────────────────────────────────────────
  String subjectCode = 'S001';
  String outputDirectoryPath = '';

  // ── Module enables (for debug isolation) ───────────────────────────────────
  bool debugBypassBleCoordinator = false;
  bool showSampleRateInViewer = true;
  bool syntheticMode = false;
  bool reconnectBeepEnabled = true;

  // ── Study flow ─────────────────────────────────────────────────────────────
  bool angelAudioInstructionsEnabled = true;
  List<ModuleType> studySequence = [
    ModuleType.standalone,
    ModuleType.nidra,
    ModuleType.angel,
    ModuleType.erp,
    ModuleType.wm,
    ModuleType.heartsync,
  ];

  // ── Paradigm defaults ─────────────────────────────────────────────────────
  String angelLevel = '1,2';
  String angelLanguage = 'English';
  int angelBlocksCount = 2;
  String angelTrialsOption = '25+3';
  int angelPracticeCount = 2;
  String angelCategorySet = 'all';
  String angelCdSchedule = 'by-block';
  String angelToneOffsetMode = 'continuous';
  String angelTonePlaybackMode = 'async';
  bool angelLevel2Cd = true;
  bool angelIntermixLevelBlocks = true;
  bool angelRecordEeg = true;
  String angelVisualStimulusFolder = '';
  String angelAuditoryStimulusFolder = '';
  Map<String, List<String>> angelStimulusFiles = {};
  String angelRealtimeErpComponent = 'N170';

  String genericErpParadigm = 'Visual Oddball';
  String genericErpComponent = 'P300';
  int genericErpTrials = 60;
  int genericErpIntervalMs = 1000;
  double genericErpRareProbability = 0.2;
  String genericErpFrequentFilePath = '';
  String genericErpRareFilePath = '';
  int genericErpFrequentMarker = 101;
  int genericErpRareMarker = 102;
  bool genericErpShowRealtime = true;

  int wmTotalTrials = 60;
  int wmFixationDurationMs = 500;
  int wmCueDurationMs = 300;
  int wmEncodingDurationMs = 300;
  int wmDelayDurationMs = 1000;
  bool wmRecordEeg = true;

  int heartSyncTotalStimuli = 100;
  double heartSyncRareProportion = 0.2;
  int heartSyncTrialsPerBlock = 25;
  int heartSyncBlocks = 4;
  String heartSyncPulseMode = 'ppg';
  String heartSyncInputMode = 'live';
  String heartSyncReplayFilePath = '';
  bool heartSyncShowLiveWaveform = true;
  double heartSyncWaveformSeconds = 10;
  String heartSyncChannelName = 'PPG';
  String heartSyncStimulusMode = 'tones';
  double heartSyncFrequentToneHz = 800;
  double heartSyncRareToneHz = 1200;
  int heartSyncToneDurationMs = 100;
  String heartSyncFrequentFilePath = '';
  String heartSyncRareFilePath = '';
  int heartSyncImageDurationMs = 250;
  double heartSyncDeliveryProbability = 0.8;
  int heartSyncMinSkippedBeats = 2;
  int heartSyncMaxSkippedBeats = 5;
  int heartSyncIpiHistoryLength = 5;
  double heartSyncPpgThresholdSigma = 0.6;
  double heartSyncEcgThresholdSigma = 2.5;
  double heartSyncDetectionHighPassHz = 0.5;
  double heartSyncDetectionLowPassHz = 8;
  double heartSyncSystolicOffsetPercent = 0;
  double heartSyncDiastolicOffsetPercent = 45;
  int heartSyncDetectionLagMs = 0;
  int heartSyncRefractoryMs = 450;
  int heartSyncResponseWindowMs = 2000;
  int heartSyncMinimumStimulusIntervalMs = 600;
  double heartSyncPostHocSystolicEndPercent = 35;
  bool heartSyncAdaptiveOffsets = false;
  double heartSyncAdaptiveStepPercent = 5;
  int heartSyncAdaptiveMinTrials = 8;
  bool heartSyncRecordPhysiology = true;

  // ── EEG Channel Custom Config ──────────────────────────────────────────────
  List<String> channelLabels = List.from(kDefaultEpiDomeLabels);
  List<bool> channelEnabled = List.filled(16, true);
  Map<String, List<String>> amplifierChannelLabels = {
    'orbit': List.from(kDefaultOrbitLabels),
  };
  Map<String, List<bool>> amplifierChannelEnabled = {
    'orbit': List.filled(3, true),
  };

  // ── Last connected device (for auto-reconnect) ─────────────────────────────
  String? lastDeviceId;
  String? lastDeviceName;
  String? lastDeviceKind; // 'orbit', 'epidome', 'synthetic'
  bool lastDeviceIsBle = true;

  static const _filename = 'app_config.json';

  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_filename');
      if (!await file.exists()) return;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      xampPrefix = (json['xampPrefix'] as String?) ?? 'AXXSPU00002';
      orbitPrefix = (json['orbitPrefix'] as String?) ?? 'ORBIT_';
      _loadDeviceProfiles(json);
      maxReconnectAttempts = (json['maxReconnectAttempts'] as int?) ?? 0;
      disconnectionTimeoutSeconds =
          (json['disconnectionTimeoutSeconds'] as int?) ?? 5;
      reconnectIntervalSec = (json['reconnectIntervalSec'] as int?) ?? 5;
      autoResumeRecordingAfterReconnect =
          (json['autoResumeRecordingAfterReconnect'] as bool?) ?? true;
      textScaleFactor = ((json['textScaleFactor'] as num?)?.toDouble() ?? 1.0)
          .clamp(0.8, 1.4);
      waveformGain = (json['waveformGain'] as num?)?.toDouble() ?? 1.0;
      final loadedWaveformDuration =
          (json['waveformDurationSeconds'] as int?) ?? 10;
      waveformDurationSeconds =
          const [2, 4, 8, 10, 20, 30].contains(loadedWaveformDuration)
          ? loadedWaveformDuration
          : 10;
      notchEnabled = (json['notchEnabled'] as bool?) ?? true;
      bandpassEnabled = (json['bandpassEnabled'] as bool?) ?? true;
      autoscaleEnabled = (json['autoscaleEnabled'] as bool?) ?? false;
      stackedChannels = (json['stackedChannels'] as bool?) ?? true;
      visibleChannels = List<int>.from(json['visibleChannels'] as List? ?? []);
      eegDisplayScaleUv =
          ((json['eegDisplayScaleUv'] as num?)?.toDouble() ?? 150.0).clamp(
            10.0,
            15000.0,
          );
      ecgDisplayScaleUv =
          ((json['ecgDisplayScaleUv'] as num?)?.toDouble() ?? 2000.0).clamp(
            100.0,
            30000.0,
          );
      ppgDisplayScale = ((json['ppgDisplayScale'] as num?)?.toDouble() ?? 100.0)
          .clamp(5.0, 32768.0);
      waveformAutoscaleV2 = (json['waveformAutoscaleV2'] as bool?) ?? true;
      waveformViewMode = json['waveformViewMode'] == 'page'
          ? 'page'
          : 'rolling';
      waveformStrokeWidth =
          ((json['waveformStrokeWidth'] as num?)?.toDouble() ?? 1.5).clamp(
            0.5,
            5.0,
          );
      waveformColorValue =
          (json['waveformColorValue'] as num?)?.toInt() ?? 0xFF14B8A6;
      _loadMarkerProfiles(json);
      _loadDisplayFilters(json);
      _loadViewerDisplayProfiles(json);
      _loadNidraStimSettings(json);
      final loadedCode = json['subjectCode'] as String?;
      subjectCode = (loadedCode != null && loadedCode.isNotEmpty)
          ? loadedCode
          : 'S001';
      outputDirectoryPath = (json['outputDirectoryPath'] as String?) ?? '';
      FileNamingService.configureOutputDirectory(outputDirectoryPath);
      debugBypassBleCoordinator =
          (json['debugBypassBleCoordinator'] as bool?) ?? false;
      showSampleRateInViewer =
          (json['showSampleRateInViewer'] as bool?) ?? true;
      syntheticMode = (json['syntheticMode'] as bool?) ?? false;
      reconnectBeepEnabled = (json['reconnectBeepEnabled'] as bool?) ?? true;
      angelAudioInstructionsEnabled =
          (json['angelAudioInstructionsEnabled'] as bool?) ?? true;
      studySequence = _parseStudySequence(json['studySequence']);
      _loadParadigmDefaults(json);
      lastDeviceId = json['lastDeviceId'] as String?;
      lastDeviceName = json['lastDeviceName'] as String?;
      lastDeviceKind = json['lastDeviceKind'] as String?;
      lastDeviceIsBle = (json['lastDeviceIsBle'] as bool?) ?? true;
      if (json['lslConfig'] is Map) {
        lslConfig = LslConfig.fromJson(
          Map<String, dynamic>.from(json['lslConfig'] as Map),
        );
      }
      amplifierChannelLabels = _stringListMap(
        json['amplifierChannelLabels'],
        amplifierChannelLabels,
      );
      amplifierChannelEnabled = _boolListMap(
        json['amplifierChannelEnabled'],
        amplifierChannelEnabled,
      );
      notifyListeners();
    } catch (e) {
      debugPrint('[Settings] Load failed: $e');
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  Future<void> save() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_filename');
      await file.writeAsString(jsonEncode(_toJson()));
    } catch (e) {
      debugPrint('[Settings] Save failed: $e');
    }
  }

  Map<String, dynamic> toJson() => {
    'textScaleFactor': textScaleFactor,
    'xampPrefix': xampPrefix,
    'orbitPrefix': orbitPrefix,
    'deviceProfiles': deviceProfiles
        .map((profile) => profile.toJson())
        .toList(),
    'combineCompatibleStreams': combineCompatibleStreams,
    'maxReconnectAttempts': maxReconnectAttempts,
    'reconnectIntervalSec': reconnectIntervalSec,
    'autoResumeRecordingAfterReconnect': autoResumeRecordingAfterReconnect,
    'waveformGain': waveformGain,
    'waveformDurationSeconds': waveformDurationSeconds,
    'notchEnabled': notchEnabled,
    'bandpassEnabled': bandpassEnabled,
    'autoscaleEnabled': autoscaleEnabled,
    'stackedChannels': stackedChannels,
    'visibleChannels': visibleChannels,
    'eegDisplayScaleUv': eegDisplayScaleUv,
    'ecgDisplayScaleUv': ecgDisplayScaleUv,
    'ppgDisplayScale': ppgDisplayScale,
    'waveformAutoscaleV2': waveformAutoscaleV2,
    'waveformViewMode': waveformViewMode,
    'waveformStrokeWidth': waveformStrokeWidth,
    'waveformColorValue': waveformColorValue,
    'activeMarkerProfile': activeMarkerProfile,
    'markerProfiles': markerProfiles.map(
      (name, markers) =>
          MapEntry(name, markers.map((marker) => marker.toJson()).toList()),
    ),
    'eegDisplayHighPassHz': eegDisplayHighPassHz,
    'eegDisplayLowPassHz': eegDisplayLowPassHz,
    'eogDisplayHighPassHz': eogDisplayHighPassHz,
    'eogDisplayLowPassHz': eogDisplayLowPassHz,
    'emgDisplayHighPassHz': emgDisplayHighPassHz,
    'emgDisplayLowPassHz': emgDisplayLowPassHz,
    'ecgDisplayHighPassHz': ecgDisplayHighPassHz,
    'ecgDisplayLowPassHz': ecgDisplayLowPassHz,
    'displayNotchFrequencyHz': displayNotchFrequencyHz,
    'displayMontageReferences': displayMontageReferences,
    'displayHiddenChannelLabels': displayHiddenChannelLabels,
    'viewerDisplayProfiles': viewerDisplayProfiles,
    'nidraStimEnabled': nidraStimEnabled,
    'nidraStimTargetStage': nidraStimTargetStage,
    'nidraStimType': nidraStimType,
    'nidraStimToneFrequencyHz': nidraStimToneFrequencyHz,
    'nidraStimToneDurationMs': nidraStimToneDurationMs,
    'nidraStimAudioFilePath': nidraStimAudioFilePath,
    'nidraStimVolume': nidraStimVolume,
    'nidraStimMinProbability': nidraStimMinProbability,
    'nidraStimStableDurationSecs': nidraStimStableDurationSecs,
    'nidraStimMaxDurationSecs': nidraStimMaxDurationSecs,
    'nidraStimIntervalSecs': nidraStimIntervalSecs,
    'nidraStimRefractorySecs': nidraStimRefractorySecs,
    'nidraStimMode': nidraStimMode,
    'nidraStimNotifyBeep': nidraStimNotifyBeep,
    'nidraStimNotifyFlash': nidraStimNotifyFlash,
    'nidraStimNotificationIntervalSecs': nidraStimNotificationIntervalSecs,
    'nidraStimMarkerCode': nidraStimMarkerCode,
    'nidraScoringSignalLabel': nidraScoringSignalLabel,
    'nidraScoringReferenceLabel': nidraScoringReferenceLabel,
    'nidraChartMode': nidraChartMode,
    'nidraProbabilityStages': nidraProbabilityStages,
    'subjectCode': subjectCode,
    'outputDirectoryPath': outputDirectoryPath,
    'debugBypassBleCoordinator': debugBypassBleCoordinator,
    'showSampleRateInViewer': showSampleRateInViewer,
    'syntheticMode': syntheticMode,
    'reconnectBeepEnabled': reconnectBeepEnabled,
    'disconnectionTimeoutSeconds': disconnectionTimeoutSeconds,
    'angelAudioInstructionsEnabled': angelAudioInstructionsEnabled,
    'studySequence': studySequence.map((module) => module.name).toList(),
    'angelLevel': angelLevel,
    'angelLanguage': angelLanguage,
    'angelBlocksCount': angelBlocksCount,
    'angelTrialsOption': angelTrialsOption,
    'angelPracticeCount': angelPracticeCount,
    'angelCategorySet': angelCategorySet,
    'angelCdSchedule': angelCdSchedule,
    'angelToneOffsetMode': angelToneOffsetMode,
    'angelTonePlaybackMode': angelTonePlaybackMode,
    'angelLevel2Cd': angelLevel2Cd,
    'angelIntermixLevelBlocks': angelIntermixLevelBlocks,
    'angelRecordEeg': angelRecordEeg,
    'angelVisualStimulusFolder': angelVisualStimulusFolder,
    'angelAuditoryStimulusFolder': angelAuditoryStimulusFolder,
    'angelStimulusFiles': angelStimulusFiles,
    'angelRealtimeErpComponent': angelRealtimeErpComponent,
    'genericErpParadigm': genericErpParadigm,
    'genericErpComponent': genericErpComponent,
    'genericErpTrials': genericErpTrials,
    'genericErpIntervalMs': genericErpIntervalMs,
    'genericErpRareProbability': genericErpRareProbability,
    'genericErpFrequentFilePath': genericErpFrequentFilePath,
    'genericErpRareFilePath': genericErpRareFilePath,
    'genericErpFrequentMarker': genericErpFrequentMarker,
    'genericErpRareMarker': genericErpRareMarker,
    'genericErpShowRealtime': genericErpShowRealtime,
    'wmTotalTrials': wmTotalTrials,
    'wmFixationDurationMs': wmFixationDurationMs,
    'wmCueDurationMs': wmCueDurationMs,
    'wmEncodingDurationMs': wmEncodingDurationMs,
    'wmDelayDurationMs': wmDelayDurationMs,
    'wmRecordEeg': wmRecordEeg,
    'heartSyncTotalStimuli': heartSyncTotalStimuli,
    'heartSyncRareProportion': heartSyncRareProportion,
    'heartSyncTrialsPerBlock': heartSyncTrialsPerBlock,
    'heartSyncBlocks': heartSyncBlocks,
    'heartSyncPulseMode': heartSyncPulseMode,
    'heartSyncInputMode': heartSyncInputMode,
    'heartSyncReplayFilePath': heartSyncReplayFilePath,
    'heartSyncShowLiveWaveform': heartSyncShowLiveWaveform,
    'heartSyncWaveformSeconds': heartSyncWaveformSeconds,
    'heartSyncChannelName': heartSyncChannelName,
    'heartSyncStimulusMode': heartSyncStimulusMode,
    'heartSyncFrequentToneHz': heartSyncFrequentToneHz,
    'heartSyncRareToneHz': heartSyncRareToneHz,
    'heartSyncToneDurationMs': heartSyncToneDurationMs,
    'heartSyncFrequentFilePath': heartSyncFrequentFilePath,
    'heartSyncRareFilePath': heartSyncRareFilePath,
    'heartSyncImageDurationMs': heartSyncImageDurationMs,
    'heartSyncDeliveryProbability': heartSyncDeliveryProbability,
    'heartSyncMinSkippedBeats': heartSyncMinSkippedBeats,
    'heartSyncMaxSkippedBeats': heartSyncMaxSkippedBeats,
    'heartSyncIpiHistoryLength': heartSyncIpiHistoryLength,
    'heartSyncPpgThresholdSigma': heartSyncPpgThresholdSigma,
    'heartSyncEcgThresholdSigma': heartSyncEcgThresholdSigma,
    'heartSyncDetectionHighPassHz': heartSyncDetectionHighPassHz,
    'heartSyncDetectionLowPassHz': heartSyncDetectionLowPassHz,
    'heartSyncSystolicOffsetPercent': heartSyncSystolicOffsetPercent,
    'heartSyncDiastolicOffsetPercent': heartSyncDiastolicOffsetPercent,
    'heartSyncDetectionLagMs': heartSyncDetectionLagMs,
    'heartSyncRefractoryMs': heartSyncRefractoryMs,
    'heartSyncResponseWindowMs': heartSyncResponseWindowMs,
    'heartSyncMinimumStimulusIntervalMs': heartSyncMinimumStimulusIntervalMs,
    'heartSyncPostHocSystolicEndPercent': heartSyncPostHocSystolicEndPercent,
    'heartSyncAdaptiveOffsets': heartSyncAdaptiveOffsets,
    'heartSyncAdaptiveStepPercent': heartSyncAdaptiveStepPercent,
    'heartSyncAdaptiveMinTrials': heartSyncAdaptiveMinTrials,
    'heartSyncRecordPhysiology': heartSyncRecordPhysiology,
    'channelLabels': channelLabels,
    'channelEnabled': channelEnabled,
    'amplifierChannelLabels': amplifierChannelLabels,
    'amplifierChannelEnabled': amplifierChannelEnabled,
    'lastDeviceId': lastDeviceId,
    'lastDeviceName': lastDeviceName,
    'lastDeviceKind': lastDeviceKind,
    'lastDeviceIsBle': lastDeviceIsBle,
    'lslConfig': lslConfig.toJson(),
  };

  Map<String, dynamic> _toJson() => toJson();

  Future<String?> exportJson({String? destinationPath}) async {
    final defaultName =
        'ccs_mobile_studio_settings_${DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}.json';
    String? targetPath = destinationPath;
    if (targetPath == null) {
      if (Platform.isAndroid) {
        final dir = await FileNamingService.outputRootDirectory();
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        targetPath = '${dir.path}/$defaultName';
      } else {
        targetPath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save CCS settings JSON',
          fileName: defaultName,
          type: FileType.custom,
          allowedExtensions: const ['json'],
        );
      }
    }
    if (targetPath == null) return null;

    final file = File(targetPath);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(toJson()));
    return file.path;
  }

  Future<String> effectiveOutputDirectory() async {
    FileNamingService.configureOutputDirectory(outputDirectoryPath);
    return (await FileNamingService.outputRootDirectory()).path;
  }

  Future<bool> chooseOutputDirectory() async {
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose CCS Mobile Studio output folder',
      initialDirectory: outputDirectoryPath.isEmpty
          ? null
          : outputDirectoryPath,
    );
    if (selected == null || selected.trim().isEmpty) return false;
    outputDirectoryPath = selected.trim();
    FileNamingService.configureOutputDirectory(outputDirectoryPath);
    await FileNamingService.outputRootDirectory();
    notifyListeners();
    await save();
    return true;
  }

  Future<void> resetOutputDirectory() async {
    outputDirectoryPath = '';
    FileNamingService.configureOutputDirectory(null);
    await FileNamingService.outputRootDirectory();
    notifyListeners();
    await save();
  }

  Future<bool> openOutputDirectory() async {
    final path = await effectiveOutputDirectory();
    try {
      final result = Platform.isMacOS
          ? await Process.run('open', [path])
          : Platform.isWindows
          ? await Process.run('explorer.exe', [path])
          : Platform.isLinux
          ? await Process.run('xdg-open', [path])
          : null;
      return result != null && result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> importJson({String? sourcePath}) async {
    final pickedPath =
        sourcePath ??
        (await FilePicker.platform.pickFiles(
          dialogTitle: 'Load CCS settings JSON',
          type: FileType.custom,
          allowedExtensions: const ['json'],
        ))?.files.single.path;
    if (pickedPath == null) return false;

    final file = File(pickedPath);
    if (!await file.exists()) return false;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('Settings JSON must contain an object.');
    }
    _applyJson(Map<String, dynamic>.from(decoded));
    notifyListeners();
    await save();
    return true;
  }

  void _applyJson(Map<String, dynamic> json) {
    textScaleFactor =
        ((json['textScaleFactor'] as num?)?.toDouble() ?? textScaleFactor)
            .clamp(0.8, 1.4);
    xampPrefix = (json['xampPrefix'] as String?) ?? xampPrefix;
    orbitPrefix = (json['orbitPrefix'] as String?) ?? orbitPrefix;
    _loadDeviceProfiles(json);
    maxReconnectAttempts =
        (json['maxReconnectAttempts'] as int?) ?? maxReconnectAttempts;
    reconnectIntervalSec =
        (json['reconnectIntervalSec'] as int?) ?? reconnectIntervalSec;
    disconnectionTimeoutSeconds =
        (json['disconnectionTimeoutSeconds'] as int?) ??
        disconnectionTimeoutSeconds;
    autoResumeRecordingAfterReconnect =
        (json['autoResumeRecordingAfterReconnect'] as bool?) ??
        autoResumeRecordingAfterReconnect;
    waveformGain = (json['waveformGain'] as num?)?.toDouble() ?? waveformGain;
    final importedWaveformDuration =
        (json['waveformDurationSeconds'] as int?) ?? waveformDurationSeconds;
    waveformDurationSeconds =
        const [2, 4, 8, 10, 20, 30].contains(importedWaveformDuration)
        ? importedWaveformDuration
        : 10;
    notchEnabled = (json['notchEnabled'] as bool?) ?? notchEnabled;
    bandpassEnabled = (json['bandpassEnabled'] as bool?) ?? bandpassEnabled;
    autoscaleEnabled = (json['autoscaleEnabled'] as bool?) ?? autoscaleEnabled;
    stackedChannels = (json['stackedChannels'] as bool?) ?? stackedChannels;
    visibleChannels = List<int>.from(
      json['visibleChannels'] as List? ?? visibleChannels,
    );
    eegDisplayScaleUv =
        ((json['eegDisplayScaleUv'] as num?)?.toDouble() ?? eegDisplayScaleUv)
            .clamp(10.0, 15000.0);
    ecgDisplayScaleUv =
        ((json['ecgDisplayScaleUv'] as num?)?.toDouble() ?? ecgDisplayScaleUv)
            .clamp(100.0, 30000.0);
    ppgDisplayScale =
        ((json['ppgDisplayScale'] as num?)?.toDouble() ?? ppgDisplayScale)
            .clamp(5.0, 32768.0);
    waveformAutoscaleV2 =
        (json['waveformAutoscaleV2'] as bool?) ?? waveformAutoscaleV2;
    if (json.containsKey('waveformViewMode')) {
      waveformViewMode = json['waveformViewMode'] == 'page'
          ? 'page'
          : 'rolling';
    }
    waveformStrokeWidth =
        ((json['waveformStrokeWidth'] as num?)?.toDouble() ??
                waveformStrokeWidth)
            .clamp(0.5, 5.0);
    waveformColorValue =
        (json['waveformColorValue'] as num?)?.toInt() ?? waveformColorValue;
    _loadMarkerProfiles(json);
    _loadDisplayFilters(json);
    _loadViewerDisplayProfiles(json);
    _loadNidraStimSettings(json);
    final loadedCode = json['subjectCode'] as String?;
    subjectCode = (loadedCode != null && loadedCode.isNotEmpty)
        ? loadedCode
        : subjectCode;
    outputDirectoryPath =
        (json['outputDirectoryPath'] as String?) ?? outputDirectoryPath;
    FileNamingService.configureOutputDirectory(outputDirectoryPath);
    debugBypassBleCoordinator =
        (json['debugBypassBleCoordinator'] as bool?) ??
        debugBypassBleCoordinator;
    showSampleRateInViewer =
        (json['showSampleRateInViewer'] as bool?) ?? showSampleRateInViewer;
    syntheticMode = (json['syntheticMode'] as bool?) ?? syntheticMode;
    reconnectBeepEnabled =
        (json['reconnectBeepEnabled'] as bool?) ?? reconnectBeepEnabled;
    angelAudioInstructionsEnabled =
        (json['angelAudioInstructionsEnabled'] as bool?) ??
        angelAudioInstructionsEnabled;
    studySequence = _parseStudySequence(json['studySequence']);
    _loadParadigmDefaults(json);
    lastDeviceId = json['lastDeviceId'] as String?;
    lastDeviceName = json['lastDeviceName'] as String?;
    lastDeviceKind = json['lastDeviceKind'] as String?;
    lastDeviceIsBle = (json['lastDeviceIsBle'] as bool?) ?? lastDeviceIsBle;
    if (json['lslConfig'] is Map) {
      lslConfig = LslConfig.fromJson(
        Map<String, dynamic>.from(json['lslConfig'] as Map),
      );
    }
  }

  void _loadDisplayFilters(Map<String, dynamic> json) {
    double frequency(String key, double fallback, double minimum) {
      return ((json[key] as num?)?.toDouble() ?? fallback).clamp(
        minimum,
        500.0,
      );
    }

    eegDisplayHighPassHz = frequency(
      'eegDisplayHighPassHz',
      eegDisplayHighPassHz,
      0.01,
    );
    eegDisplayLowPassHz = frequency(
      'eegDisplayLowPassHz',
      eegDisplayLowPassHz,
      eegDisplayHighPassHz + 0.01,
    );
    eogDisplayHighPassHz = frequency(
      'eogDisplayHighPassHz',
      eogDisplayHighPassHz,
      0.01,
    );
    eogDisplayLowPassHz = frequency(
      'eogDisplayLowPassHz',
      eogDisplayLowPassHz,
      eogDisplayHighPassHz + 0.01,
    );
    emgDisplayHighPassHz = frequency(
      'emgDisplayHighPassHz',
      emgDisplayHighPassHz,
      0.01,
    );
    emgDisplayLowPassHz = frequency(
      'emgDisplayLowPassHz',
      emgDisplayLowPassHz,
      emgDisplayHighPassHz + 0.01,
    );
    ecgDisplayHighPassHz = frequency(
      'ecgDisplayHighPassHz',
      ecgDisplayHighPassHz,
      0.01,
    );
    ecgDisplayLowPassHz = frequency(
      'ecgDisplayLowPassHz',
      ecgDisplayLowPassHz,
      ecgDisplayHighPassHz + 0.01,
    );
    displayNotchFrequencyHz = frequency(
      'displayNotchFrequencyHz',
      displayNotchFrequencyHz,
      1.0,
    );
    if (json['displayMontageReferences'] is Map) {
      displayMontageReferences = Map<String, String>.from(
        json['displayMontageReferences'] as Map,
      );
    }
    displayHiddenChannelLabels = List<String>.from(
      json['displayHiddenChannelLabels'] as List? ?? displayHiddenChannelLabels,
    );
  }

  void _loadNidraStimSettings(Map<String, dynamic> json) {
    nidraStimEnabled = (json['nidraStimEnabled'] as bool?) ?? nidraStimEnabled;
    final target = json['nidraStimTargetStage']?.toString();
    if (const ['wake', 'n1', 'n2', 'n3', 'rem'].contains(target)) {
      nidraStimTargetStage = target!;
    }
    final type = json['nidraStimType']?.toString();
    if (const ['beep', 'tone', 'audio'].contains(type)) {
      nidraStimType = type!;
    }
    nidraStimToneFrequencyHz =
        ((json['nidraStimToneFrequencyHz'] as num?)?.toDouble() ??
                nidraStimToneFrequencyHz)
            .clamp(100.0, 8000.0);
    nidraStimToneDurationMs =
        ((json['nidraStimToneDurationMs'] as num?)?.round() ??
                nidraStimToneDurationMs)
            .clamp(20, 5000);
    nidraStimAudioFilePath =
        (json['nidraStimAudioFilePath'] as String?) ?? nidraStimAudioFilePath;
    nidraStimVolume =
        ((json['nidraStimVolume'] as num?)?.toDouble() ?? nidraStimVolume)
            .clamp(0.0, 1.0);
    nidraStimMinProbability =
        ((json['nidraStimMinProbability'] as num?)?.toDouble() ??
                nidraStimMinProbability)
            .clamp(0.1, 1.0);
    nidraStimStableDurationSecs =
        ((json['nidraStimStableDurationSecs'] as num?)?.round() ??
                nidraStimStableDurationSecs)
            .clamp(5, 300);
    nidraStimMaxDurationSecs =
        ((json['nidraStimMaxDurationSecs'] as num?)?.round() ??
                nidraStimMaxDurationSecs)
            .clamp(2, 60);
    nidraStimIntervalSecs =
        ((json['nidraStimIntervalSecs'] as num?)?.round() ??
                nidraStimIntervalSecs)
            .clamp(1, 10);
    nidraStimRefractorySecs =
        ((json['nidraStimRefractorySecs'] as num?)?.round() ??
                nidraStimRefractorySecs)
            .clamp(10, 3600);
    final mode = json['nidraStimMode']?.toString();
    if (const ['automatic', 'manual'].contains(mode)) {
      nidraStimMode = mode!;
    }
    nidraStimNotifyBeep =
        (json['nidraStimNotifyBeep'] as bool?) ?? nidraStimNotifyBeep;
    nidraStimNotifyFlash =
        (json['nidraStimNotifyFlash'] as bool?) ?? nidraStimNotifyFlash;
    nidraStimNotificationIntervalSecs =
        ((json['nidraStimNotificationIntervalSecs'] as num?)?.round() ??
                nidraStimNotificationIntervalSecs)
            .clamp(1, 60);
    nidraStimMarkerCode =
        ((json['nidraStimMarkerCode'] as num?)?.round() ?? nidraStimMarkerCode)
            .clamp(1, 32767);
    nidraScoringSignalLabel =
        (json['nidraScoringSignalLabel'] as String?) ?? nidraScoringSignalLabel;
    nidraScoringReferenceLabel =
        (json['nidraScoringReferenceLabel'] as String?) ??
        nidraScoringReferenceLabel;
    final chartMode = json['nidraChartMode']?.toString();
    if (const ['hypnogram', 'probabilities'].contains(chartMode)) {
      nidraChartMode = chartMode!;
    }
    final probabilityStages = (json['nidraProbabilityStages'] as List?)
        ?.whereType<String>()
        .where(
          (stage) => const ['wake', 'n1', 'n2', 'n3', 'rem'].contains(stage),
        )
        .toSet()
        .toList();
    if (probabilityStages != null && probabilityStages.isNotEmpty) {
      nidraProbabilityStages = probabilityStages;
    }
  }

  void _loadMarkerProfiles(Map<String, dynamic> json) {
    final rawProfiles = json['markerProfiles'];
    if (rawProfiles is Map) {
      final parsed = <String, List<ManualMarkerDefinition>>{};
      for (final entry in rawProfiles.entries) {
        if (entry.value is! List) continue;
        final markers = (entry.value as List)
            .whereType<Map>()
            .map(
              (value) => ManualMarkerDefinition.fromJson(
                Map<String, dynamic>.from(value),
              ),
            )
            .toList();
        if (markers.isNotEmpty) parsed[entry.key.toString()] = markers;
      }
      if (parsed.isNotEmpty) markerProfiles = parsed;
    }
    final selected = json['activeMarkerProfile']?.toString();
    activeMarkerProfile = markerProfiles.containsKey(selected)
        ? selected!
        : markerProfiles.keys.first;
  }

  List<ManualMarkerDefinition> get activeManualMarkers => List.unmodifiable(
    markerProfiles[activeMarkerProfile] ?? kDefaultManualMarkers,
  );

  void saveMarkerProfile(
    String name,
    List<ManualMarkerDefinition> markers, {
    bool makeActive = true,
  }) {
    final cleanName = name.trim().isEmpty ? 'Default' : name.trim();
    markerProfiles[cleanName] = List<ManualMarkerDefinition>.from(markers);
    if (makeActive) activeMarkerProfile = cleanName;
    notifyListeners();
    save();
  }

  void _loadParadigmDefaults(Map<String, dynamic> json) {
    angelLevel = (json['angelLevel'] as String?) ?? angelLevel;
    angelLanguage = (json['angelLanguage'] as String?) ?? angelLanguage;
    angelBlocksCount = (json['angelBlocksCount'] as int?) ?? angelBlocksCount;
    angelTrialsOption =
        (json['angelTrialsOption'] as String?) ?? angelTrialsOption;
    angelPracticeCount =
        (json['angelPracticeCount'] as int?) ?? angelPracticeCount;
    angelCategorySet =
        (json['angelCategorySet'] as String?) ?? angelCategorySet;
    angelCdSchedule = (json['angelCdSchedule'] as String?) ?? angelCdSchedule;
    angelToneOffsetMode =
        (json['angelToneOffsetMode'] as String?) ?? angelToneOffsetMode;
    angelTonePlaybackMode =
        (json['angelTonePlaybackMode'] as String?) ?? angelTonePlaybackMode;
    angelLevel2Cd = (json['angelLevel2Cd'] as bool?) ?? angelLevel2Cd;
    angelIntermixLevelBlocks =
        (json['angelIntermixLevelBlocks'] as bool?) ?? angelIntermixLevelBlocks;
    angelRecordEeg = (json['angelRecordEeg'] as bool?) ?? angelRecordEeg;
    angelVisualStimulusFolder =
        (json['angelVisualStimulusFolder'] as String?) ??
        angelVisualStimulusFolder;
    angelAuditoryStimulusFolder =
        (json['angelAuditoryStimulusFolder'] as String?) ??
        angelAuditoryStimulusFolder;
    angelStimulusFiles = _stringListMap(
      json['angelStimulusFiles'],
      angelStimulusFiles,
    );
    angelRealtimeErpComponent =
        (json['angelRealtimeErpComponent'] as String?) ??
        angelRealtimeErpComponent;
    genericErpParadigm =
        (json['genericErpParadigm'] as String?) ?? genericErpParadigm;
    genericErpComponent =
        (json['genericErpComponent'] as String?) ?? genericErpComponent;
    genericErpTrials =
        ((json['genericErpTrials'] as num?)?.round() ?? genericErpTrials).clamp(
          10,
          1000,
        );
    genericErpIntervalMs =
        ((json['genericErpIntervalMs'] as num?)?.round() ??
                genericErpIntervalMs)
            .clamp(200, 10000);
    genericErpRareProbability =
        ((json['genericErpRareProbability'] as num?)?.toDouble() ??
                genericErpRareProbability)
            .clamp(0.05, 0.5);
    genericErpFrequentFilePath =
        (json['genericErpFrequentFilePath'] as String?) ??
        genericErpFrequentFilePath;
    genericErpRareFilePath =
        (json['genericErpRareFilePath'] as String?) ?? genericErpRareFilePath;
    genericErpFrequentMarker =
        ((json['genericErpFrequentMarker'] as num?)?.round() ??
                genericErpFrequentMarker)
            .clamp(1, 32767);
    genericErpRareMarker =
        ((json['genericErpRareMarker'] as num?)?.round() ??
                genericErpRareMarker)
            .clamp(1, 32767);
    genericErpShowRealtime =
        (json['genericErpShowRealtime'] as bool?) ?? genericErpShowRealtime;

    wmTotalTrials = (json['wmTotalTrials'] as int?) ?? wmTotalTrials;
    wmFixationDurationMs =
        (json['wmFixationDurationMs'] as int?) ?? wmFixationDurationMs;
    wmCueDurationMs = (json['wmCueDurationMs'] as int?) ?? wmCueDurationMs;
    wmEncodingDurationMs =
        (json['wmEncodingDurationMs'] as int?) ?? wmEncodingDurationMs;
    wmDelayDurationMs =
        (json['wmDelayDurationMs'] as int?) ?? wmDelayDurationMs;
    wmRecordEeg = (json['wmRecordEeg'] as bool?) ?? wmRecordEeg;
    heartSyncTotalStimuli =
        (json['heartSyncTotalStimuli'] as int?) ?? heartSyncTotalStimuli;
    heartSyncRareProportion =
        (json['heartSyncRareProportion'] as num?)?.toDouble() ??
        heartSyncRareProportion;
    heartSyncTrialsPerBlock =
        (json['heartSyncTrialsPerBlock'] as int?) ?? heartSyncTrialsPerBlock;
    heartSyncBlocks = (json['heartSyncBlocks'] as int?) ?? heartSyncBlocks;
    heartSyncPulseMode =
        (json['heartSyncPulseMode'] as String?) ?? heartSyncPulseMode;
    heartSyncInputMode =
        (json['heartSyncInputMode'] as String?) ?? heartSyncInputMode;
    heartSyncReplayFilePath =
        (json['heartSyncReplayFilePath'] as String?) ?? heartSyncReplayFilePath;
    heartSyncShowLiveWaveform =
        (json['heartSyncShowLiveWaveform'] as bool?) ??
        heartSyncShowLiveWaveform;
    heartSyncWaveformSeconds =
        (json['heartSyncWaveformSeconds'] as num?)?.toDouble() ??
        heartSyncWaveformSeconds;
    heartSyncChannelName =
        (json['heartSyncChannelName'] as String?) ?? heartSyncChannelName;
    heartSyncStimulusMode =
        (json['heartSyncStimulusMode'] as String?) ?? heartSyncStimulusMode;
    heartSyncFrequentToneHz =
        (json['heartSyncFrequentToneHz'] as num?)?.toDouble() ??
        heartSyncFrequentToneHz;
    heartSyncRareToneHz =
        (json['heartSyncRareToneHz'] as num?)?.toDouble() ??
        heartSyncRareToneHz;
    heartSyncToneDurationMs =
        (json['heartSyncToneDurationMs'] as int?) ?? heartSyncToneDurationMs;
    heartSyncFrequentFilePath =
        (json['heartSyncFrequentFilePath'] as String?) ??
        heartSyncFrequentFilePath;
    heartSyncRareFilePath =
        (json['heartSyncRareFilePath'] as String?) ?? heartSyncRareFilePath;
    heartSyncImageDurationMs =
        (json['heartSyncImageDurationMs'] as int?) ?? heartSyncImageDurationMs;
    heartSyncDeliveryProbability =
        (json['heartSyncDeliveryProbability'] as num?)?.toDouble() ??
        heartSyncDeliveryProbability;
    heartSyncMinSkippedBeats =
        (json['heartSyncMinSkippedBeats'] as int?) ?? heartSyncMinSkippedBeats;
    heartSyncMaxSkippedBeats =
        (json['heartSyncMaxSkippedBeats'] as int?) ?? heartSyncMaxSkippedBeats;
    heartSyncIpiHistoryLength =
        (json['heartSyncIpiHistoryLength'] as int?) ??
        heartSyncIpiHistoryLength;
    heartSyncPpgThresholdSigma =
        (json['heartSyncPpgThresholdSigma'] as num?)?.toDouble() ??
        heartSyncPpgThresholdSigma;
    heartSyncEcgThresholdSigma =
        (json['heartSyncEcgThresholdSigma'] as num?)?.toDouble() ??
        heartSyncEcgThresholdSigma;
    heartSyncDetectionHighPassHz =
        (json['heartSyncDetectionHighPassHz'] as num?)?.toDouble() ??
        heartSyncDetectionHighPassHz;
    heartSyncDetectionLowPassHz =
        (json['heartSyncDetectionLowPassHz'] as num?)?.toDouble() ??
        heartSyncDetectionLowPassHz;
    heartSyncSystolicOffsetPercent =
        (json['heartSyncSystolicOffsetPercent'] as num?)?.toDouble() ??
        heartSyncSystolicOffsetPercent;
    heartSyncDiastolicOffsetPercent =
        (json['heartSyncDiastolicOffsetPercent'] as num?)?.toDouble() ??
        heartSyncDiastolicOffsetPercent;
    heartSyncDetectionLagMs =
        (json['heartSyncDetectionLagMs'] as int?) ?? heartSyncDetectionLagMs;
    heartSyncRefractoryMs =
        (json['heartSyncRefractoryMs'] as int?) ?? heartSyncRefractoryMs;
    heartSyncResponseWindowMs =
        (json['heartSyncResponseWindowMs'] as int?) ??
        heartSyncResponseWindowMs;
    heartSyncMinimumStimulusIntervalMs =
        (json['heartSyncMinimumStimulusIntervalMs'] as int?) ??
        heartSyncMinimumStimulusIntervalMs;
    heartSyncPostHocSystolicEndPercent =
        (json['heartSyncPostHocSystolicEndPercent'] as num?)?.toDouble() ??
        heartSyncPostHocSystolicEndPercent;
    heartSyncAdaptiveOffsets =
        (json['heartSyncAdaptiveOffsets'] as bool?) ?? heartSyncAdaptiveOffsets;
    heartSyncAdaptiveStepPercent =
        (json['heartSyncAdaptiveStepPercent'] as num?)?.toDouble() ??
        heartSyncAdaptiveStepPercent;
    heartSyncAdaptiveMinTrials =
        (json['heartSyncAdaptiveMinTrials'] as int?) ??
        heartSyncAdaptiveMinTrials;
    heartSyncRecordPhysiology =
        (json['heartSyncRecordPhysiology'] as bool?) ??
        heartSyncRecordPhysiology;
    channelLabels = List<String>.from(
      json['channelLabels'] as List? ?? channelLabels,
    );
    channelEnabled = List<bool>.from(
      json['channelEnabled'] as List? ?? channelEnabled,
    );
    amplifierChannelLabels = _stringListMap(
      json['amplifierChannelLabels'],
      amplifierChannelLabels,
    );
    amplifierChannelEnabled = _boolListMap(
      json['amplifierChannelEnabled'],
      amplifierChannelEnabled,
    );
  }

  void _loadDeviceProfiles(Map<String, dynamic> json) {
    final raw = json['deviceProfiles'];
    if (raw is List && raw.isNotEmpty) {
      final parsed = raw
          .whereType<Map>()
          .map(
            (value) => DeviceProfile.fromJson(Map<String, dynamic>.from(value)),
          )
          .where((profile) => profile.streams.isNotEmpty)
          .toList();
      if (parsed.isNotEmpty) deviceProfiles = parsed;
    } else {
      // Preserve target names from configurations created before profiles.
      deviceProfiles = defaultDeviceProfiles();
      profileById('xamp_l10')?.advertisedNamePattern = xampPrefix;
      profileById('orbit')?.advertisedNamePattern = orbitPrefix;
    }
    combineCompatibleStreams =
        json['combineCompatibleStreams'] as bool? ?? true;
  }

  DeviceProfile? profileById(String id) {
    for (final profile in deviceProfiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  void updateDeviceProfile(DeviceProfile profile) {
    final index = deviceProfiles.indexWhere((item) => item.id == profile.id);
    if (index < 0) {
      deviceProfiles.add(profile);
    } else {
      deviceProfiles[index] = profile;
    }
    if (profile.id == 'xamp_l10') {
      xampPrefix = profile.advertisedNamePattern;
    } else if (profile.id == 'orbit') {
      orbitPrefix = profile.advertisedNamePattern;
    }
    notifyListeners();
    save();
  }

  void addDeviceProfile() {
    final sequence = deviceProfiles.length + 1;
    deviceProfiles.add(
      DeviceProfile(
        id: 'device_$sequence',
        name: 'Other device $sequence',
        enabled: false,
        transport: ConnectionTransport.bluetoothLe,
        protocol: DeviceProtocol.delimitedText,
        streams: [
          SignalStreamProfile(
            id: 'device_${sequence}_stream_1',
            name: 'Signal stream',
            signalType: SignalType.eeg,
            sampleRate: 250,
            channelLabels: const ['Ch 1'],
          ),
        ],
      ),
    );
    notifyListeners();
    save();
  }

  void removeDeviceProfile(String id) {
    if (id == 'xamp_l10' || id == 'orbit') return;
    deviceProfiles.removeWhere((profile) => profile.id == id);
    notifyListeners();
    save();
  }

  Map<String, List<String>> _stringListMap(
    Object? raw,
    Map<String, List<String>> fallback,
  ) {
    if (raw is! Map) return fallback;
    return raw.map(
      (key, value) => MapEntry(
        key.toString(),
        List<String>.from(value is List ? value : const <String>[]),
      ),
    );
  }

  Map<String, List<bool>> _boolListMap(
    Object? raw,
    Map<String, List<bool>> fallback,
  ) {
    if (raw is! Map) return fallback;
    return raw.map(
      (key, value) => MapEntry(
        key.toString(),
        List<bool>.from(value is List ? value : const <bool>[]),
      ),
    );
  }

  List<ModuleType> _parseStudySequence(Object? raw) {
    final parsed = <ModuleType>[];
    if (raw is List) {
      for (final item in raw) {
        final module = ModuleType.fromKey(item.toString());
        if (module != null) parsed.add(module);
      }
    }
    return parsed.isEmpty
        ? [
            ModuleType.standalone,
            ModuleType.nidra,
            ModuleType.angel,
            ModuleType.erp,
            ModuleType.wm,
            ModuleType.heartsync,
          ]
        : parsed;
  }

  void setStudySequence(List<ModuleType> modules) {
    studySequence = modules.isEmpty
        ? [
            ModuleType.standalone,
            ModuleType.nidra,
            ModuleType.angel,
            ModuleType.erp,
            ModuleType.wm,
            ModuleType.heartsync,
          ]
        : List<ModuleType>.from(modules);
    notifyListeners();
    save();
  }

  /// Update a field and immediately persist.
  void update(void Function(SettingsService s) fn) {
    fn(this);
    notifyListeners();
    save();
  }

  Map<String, dynamic> viewerDisplayProfile(String? key) {
    if (key == null || key.trim().isEmpty) return const {};
    return Map<String, dynamic>.from(
      viewerDisplayProfiles[key] ?? const <String, dynamic>{},
    );
  }

  void updateViewerDisplayProfile(String key, Map<String, dynamic> profile) {
    viewerDisplayProfiles[key] = Map<String, dynamic>.from(profile);
    notifyListeners();
    save();
  }

  void _loadViewerDisplayProfiles(Map<String, dynamic> json) {
    final raw = json['viewerDisplayProfiles'];
    if (raw is! Map) return;
    viewerDisplayProfiles = {
      for (final entry in raw.entries)
        if (entry.value is Map)
          entry.key.toString(): Map<String, dynamic>.from(entry.value as Map),
    };
  }

  void updateLslConfig(LslConfig newConfig) {
    lslConfig = newConfig;
    notifyListeners();
    save();
  }

  void updateSyntheticMode(bool val) {
    syntheticMode = val;
    notifyListeners();
    save();
  }

  void updateSubjectCode(String code) {
    subjectCode = code.trim().isEmpty ? 'S001' : code.trim();
    notifyListeners();
    save();
  }
}
