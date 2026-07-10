import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/lsl_config.dart';
import '../models/module_type.dart';

const List<String> kDefaultEpiDomeLabels = [
  'Fp1', 'Fp2', 'F3', 'F4', 'C3', 'Cz', 'C4',
  'P3', 'Pz', 'P4', 'O1', 'Oz', 'O2', 'F7', 'F8', 'T3',
];
const List<String> kDefaultOrbitLabels = ['Fp1', 'Fp2', 'PPG'];

/// Unified settings for the entire CCS Mobile Studio app.
///
/// Persisted to `app_config.json` in the app support directory.
class SettingsService extends ChangeNotifier {
  // ── Device ─────────────────────────────────────────────────────────────────
  String xampPrefix = 'AXXSPU00002'; // default to user's actual device
  String orbitPrefix = 'ORBIT_';

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

  // ── LSL ────────────────────────────────────────────────────────────────────
  LslConfig lslConfig = const LslConfig();

  // ── Session / file naming ──────────────────────────────────────────────────
  String subjectCode = 'S001';

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
    ModuleType.wm,
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

  int wmTotalTrials = 60;
  int wmFixationDurationMs = 500;
  int wmCueDurationMs = 300;
  int wmEncodingDurationMs = 300;
  int wmDelayDurationMs = 1000;
  bool wmRecordEeg = true;

  // ── EEG Channel Custom Config ──────────────────────────────────────────────
  List<String> channelLabels = List.from(kDefaultEpiDomeLabels);
  List<bool> channelEnabled = List.filled(16, true);

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
      maxReconnectAttempts = (json['maxReconnectAttempts'] as int?) ?? 0;
      disconnectionTimeoutSeconds =
          (json['disconnectionTimeoutSeconds'] as int?) ?? 5;
      reconnectIntervalSec = (json['reconnectIntervalSec'] as int?) ?? 5;
      autoResumeRecordingAfterReconnect =
          (json['autoResumeRecordingAfterReconnect'] as bool?) ?? true;
      waveformGain = (json['waveformGain'] as num?)?.toDouble() ?? 1.0;
      waveformDurationSeconds = (json['waveformDurationSeconds'] as int?) ?? 10;
      notchEnabled = (json['notchEnabled'] as bool?) ?? true;
      bandpassEnabled = (json['bandpassEnabled'] as bool?) ?? true;
      autoscaleEnabled = (json['autoscaleEnabled'] as bool?) ?? false;
      stackedChannels = (json['stackedChannels'] as bool?) ?? true;
      visibleChannels = List<int>.from(json['visibleChannels'] as List? ?? []);
      final loadedCode = json['subjectCode'] as String?;
      subjectCode = (loadedCode != null && loadedCode.isNotEmpty)
          ? loadedCode
          : 'S001';
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
      notifyListeners();
    } catch (e) {
      debugPrint('[Settings] Load failed: $e');
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
    'xampPrefix': xampPrefix,
    'orbitPrefix': orbitPrefix,
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
    'subjectCode': subjectCode,
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
    'wmTotalTrials': wmTotalTrials,
    'wmFixationDurationMs': wmFixationDurationMs,
    'wmCueDurationMs': wmCueDurationMs,
    'wmEncodingDurationMs': wmEncodingDurationMs,
    'wmDelayDurationMs': wmDelayDurationMs,
    'wmRecordEeg': wmRecordEeg,
    'channelLabels': channelLabels,
    'channelEnabled': channelEnabled,
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
        final dir = Directory('/storage/emulated/0/Download/CCS_MobileStudio');
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
    xampPrefix = (json['xampPrefix'] as String?) ?? xampPrefix;
    orbitPrefix = (json['orbitPrefix'] as String?) ?? orbitPrefix;
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
    waveformDurationSeconds =
        (json['waveformDurationSeconds'] as int?) ?? waveformDurationSeconds;
    notchEnabled = (json['notchEnabled'] as bool?) ?? notchEnabled;
    bandpassEnabled = (json['bandpassEnabled'] as bool?) ?? bandpassEnabled;
    autoscaleEnabled = (json['autoscaleEnabled'] as bool?) ?? autoscaleEnabled;
    stackedChannels = (json['stackedChannels'] as bool?) ?? stackedChannels;
    visibleChannels = List<int>.from(
      json['visibleChannels'] as List? ?? visibleChannels,
    );
    final loadedCode = json['subjectCode'] as String?;
    subjectCode = (loadedCode != null && loadedCode.isNotEmpty)
        ? loadedCode
        : subjectCode;
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

    wmTotalTrials = (json['wmTotalTrials'] as int?) ?? wmTotalTrials;
    wmFixationDurationMs =
        (json['wmFixationDurationMs'] as int?) ?? wmFixationDurationMs;
    wmCueDurationMs = (json['wmCueDurationMs'] as int?) ?? wmCueDurationMs;
    wmEncodingDurationMs =
        (json['wmEncodingDurationMs'] as int?) ?? wmEncodingDurationMs;
    wmDelayDurationMs =
        (json['wmDelayDurationMs'] as int?) ?? wmDelayDurationMs;
    wmRecordEeg = (json['wmRecordEeg'] as bool?) ?? wmRecordEeg;
    channelLabels = List<String>.from(json['channelLabels'] as List? ?? channelLabels);
    channelEnabled = List<bool>.from(json['channelEnabled'] as List? ?? channelEnabled);
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
            ModuleType.wm,
          ]
        : parsed;
  }

  void setStudySequence(List<ModuleType> modules) {
    studySequence = modules.isEmpty
        ? [
            ModuleType.standalone,
            ModuleType.nidra,
            ModuleType.angel,
            ModuleType.wm,
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
