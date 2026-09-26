import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';

import 'models/trial.dart';

// Marker codes matching angel_paradigm.py
class MarkerCodes {
  static const blockStart = 1;
  static const trialStart = 10;
  static const baselineStart = 11;
  static const pairedStandard = 20;
  static const pairedDeviant = 21;
  static const visualFrequent = 30;
  static const visualRare = 31;
  static const visualOffset = 32;
  static const responseLeft = 40;
  static const responseRight = 41;
  static const responseMiss = 42;
  static const cdImmediate = 50;
  static const cdDelayed = 51;
  static const cdNone = 52;
  static const trialEnd = 90;

  static const labels = {
    blockStart: 'block_start',
    trialStart: 'trial_start',
    baselineStart: 'baseline_start',
    pairedStandard: 'paired_standard',
    pairedDeviant: 'paired_deviant',
    visualFrequent: 'visual_frequent',
    visualRare: 'visual_rare',
    visualOffset: 'visual_offset',
    responseLeft: 'response_left',
    responseRight: 'response_right',
    responseMiss: 'response_miss',
    cdImmediate: 'cd_immediate',
    cdDelayed: 'cd_delayed',
    cdNone: 'cd_none',
    trialEnd: 'trial_end',
  };
}

class ErpEvent {
  ErpEvent({
    required this.code,
    required this.label,
    required this.elapsedMs,
    required this.timestamp,
  });

  final int code;
  final String label;
  final int elapsedMs;
  final DateTime timestamp;
}

enum ErpStage {
  idle,
  instructions,
  mainInstructions,
  practiceEnd,
  trialPreStim,
  trialVisual,
  trialResponseWindow,
  trialPostMask,
  blockFeedback,
  completed,
}

class ErpEngine {
  ErpEngine({
    required this.level,
    required this.language,
    required this.participant,
    required this.blocksCount,
    required this.trialsPerBlockOption,
    required this.practiceCount,
    required this.stimDurationSeconds,
    required this.responseWindowSeconds,
    required this.postMaskMinSeconds,
    required this.postMaskMaxSeconds,
    required this.pairedToneOffsetMin,
    required this.pairedToneOffsetMax,
    this.visualDistractorMode = 'sync',
    this.pairedToneOffsetMode = 'continuous',
    this.tonePlaybackMode = 'async',
    this.categorySet = 'all',
    this.level2Cd = false,
    this.intermixLevelBlocks = false,
    this.cdSchedule = 'by-block',
    this.excludePractice = false,
    this.guideAudioEnabled = true,
    this.visualStimulusFolder = '',
    this.auditoryStimulusFolder = '',
    this.stimulusFiles = const {},
  });

  final String level;
  final String language;
  final String participant;
  final int blocksCount;
  final String trialsPerBlockOption;
  final int practiceCount;
  final bool excludePractice;
  final double stimDurationSeconds;
  final double responseWindowSeconds;
  final double postMaskMinSeconds;
  final double postMaskMaxSeconds;
  final double pairedToneOffsetMin;
  final double pairedToneOffsetMax;
  final String visualDistractorMode;
  final String pairedToneOffsetMode;
  final String tonePlaybackMode;
  final String categorySet;
  final bool level2Cd;
  final bool intermixLevelBlocks;
  final String cdSchedule;
  final bool guideAudioEnabled;
  final String visualStimulusFolder;
  final String auditoryStimulusFolder;
  final Map<String, List<String>> stimulusFiles;
  List<String> _customStandardAudio = [];
  List<String> _customDeviantAudio = [];
  List<String> _customCorollaryAudio = [];
  List<String> _customNoCorollaryAudio = [];

  // State
  ErpStage stage = ErpStage.idle;
  int currentTrialGlobalIndex = 0;
  int currentTrialInBlock = 0;
  int currentBlockIndex = 0;
  bool isPractice = false;

  Trial? currentTrial;
  List<Trial> _trialsList = [];

  // High-precision clocks
  final Stopwatch _stopwatch = Stopwatch();
  final Stopwatch _trialStopwatch = Stopwatch();
  Ticker? _ticker;
  DateTime? _experimentStartTime;

  // Cached assets in-memory
  ui.Image? imgFixation;
  ui.Image? imgCheckerboard;
  ui.Image? imgPractice;
  ui.Image? imgReady;
  ui.Image? imgRelax;

  // Level-specific instruction screens mapping
  final Map<String, ui.Image?> imgWelcomeByLevel = {};
  final Map<String, ui.Image?> imgInstructionsByLevel = {};
  final Map<String, ui.Image?> imgThankYouByLevel = {};
  final Map<String, ui.Image?> imgPracticeEndByLevel = {};

  String get currentStageLevel {
    if (_trialsList.isNotEmpty) {
      final idx = currentTrialGlobalIndex < _trialsList.length
          ? currentTrialGlobalIndex
          : _trialsList.length - 1;
      return _trialsList[idx].level;
    }
    return level == '1,2' ? '1' : level;
  }

  ui.Image? get imgWelcome => imgWelcomeByLevel[currentStageLevel];
  ui.Image? get imgInstructions => imgInstructionsByLevel[currentStageLevel];
  ui.Image? get imgThankYou => imgThankYouByLevel[currentStageLevel];
  ui.Image? get imgPracticeEnd => imgPracticeEndByLevel[currentStageLevel];

  // Category images
  final Map<String, List<ui.Image>> cachedCategoryImages = {};
  ui.Image? currentTargetImage;

  // Audio players
  late final AudioPlayer _audioPlayerTone;
  late final AudioPlayer _audioPlayerCd;
  late final AudioPlayer _audioPlayerGuide;

  // Pre-loaded low-latency tone players map
  final Map<String, AudioPlayer> _cachedTonePlayers = {};

  // Async tone players pool for overlapping tones
  final List<AudioPlayer> _asyncTonePlayers = [];
  int _asyncTonePlayerIndex = 0;

  // Callbacks
  Function(ErpEvent)? onMarkerSent;
  Function()? onStateChanged;

  // Outputs
  final List<Map<String, dynamic>> loggedRows = [];
  final List<ErpEvent> eventLog = [];

  // Timing checkpoints within a trial (in seconds)
  double preStimDuration = 0.0;
  double? toneStartSeconds;
  double? distractorStartSeconds;
  double? distractorEndSeconds;
  double postMaskDuration = 0.0;
  double? delayedCdPlaySeconds;

  // Trial dynamic flags
  bool tonePending = false;
  bool distractorVisible = false;
  bool targetVisible = false;
  bool maskVisible = false;
  bool cdNoneMarkerSent = false;
  bool cdDelayedPending = false;

  // User response values
  String? userResponse;
  double? responseRtSeconds;
  DateTime? responseOnsetGlobal;

  // Global timestamps logged for audit
  DateTime? trialStartGlobal;
  DateTime? visualOnsetGlobal;
  DateTime? visualOffsetGlobal;
  DateTime? toneOnsetGlobal;
  DateTime? cdOnsetGlobal;
  DateTime? postMaskStartGlobal;
  DateTime? postMaskEndGlobal;
  DateTime? trialEndGlobal;

  // Accuracy calculation helper
  int blockCorrectCount = 0;
  int blockTotalResponseCount = 0;
  double blockSumRt = 0.0;

  // Practice metrics
  int practiceActiveCount = 0;
  int practiceCorrectCount = 0;
  int practiceResponseCount = 0;
  double practiceSumRt = 0.0;
  String? lastCompletedPracticeLevel;

  void resetPracticeMetrics() {
    practiceActiveCount = 0;
    practiceCorrectCount = 0;
    practiceResponseCount = 0;
    practiceSumRt = 0.0;
  }

  double get practiceAccuracy {
    if (practiceActiveCount == 0) return 0.0;
    return practiceCorrectCount / practiceActiveCount;
  }

  double get practiceMeanRtMs {
    if (practiceResponseCount == 0) return 0.0;
    return (practiceSumRt / practiceResponseCount) * 1000.0;
  }

  bool isPaused = false;

  String get _languageFolder => language.trim().toLowerCase();

  void pause() {
    if (isPaused) return;
    isPaused = true;
    _stopwatch.stop();
    _trialStopwatch.stop();
    _audioPlayerTone.pause();
    _audioPlayerCd.pause();
    _audioPlayerGuide.pause();
    for (final player in _cachedTonePlayers.values) {
      player.pause();
    }
    for (final player in _asyncTonePlayers) {
      player.pause();
    }
    onStateChanged?.call();
  }

  void resume() {
    if (!isPaused) return;
    isPaused = false;
    _stopwatch.start();
    _trialStopwatch.start();
    _audioPlayerTone.resume();
    _audioPlayerCd.resume();
    _audioPlayerGuide.resume();
    for (final player in _cachedTonePlayers.values) {
      player.resume();
    }
    for (final player in _asyncTonePlayers) {
      player.resume();
    }
    onStateChanged?.call();
  }

  double _nextIndependentToneTimeS = 1.0;

  Future<void> init() async {
    _audioPlayerTone = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _audioPlayerCd = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _audioPlayerGuide = AudioPlayer()..setReleaseMode(ReleaseMode.stop);

    try {
      await _audioPlayerTone.setPlayerMode(PlayerMode.lowLatency);
      await _audioPlayerCd.setPlayerMode(PlayerMode.lowLatency);

      for (int i = 0; i < 3; i++) {
        final p = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
        await p.setPlayerMode(PlayerMode.lowLatency);
        _asyncTonePlayers.add(p);
      }
    } catch (e) {
      // ignore
    }

    const baseTemplate = 'CCS_EEG_ANGELv2_Level2_Template';
    final resourcePath = 'assets/EPrimeFiles/$baseTemplate/resources';

    imgFixation = await _loadUiImage('$resourcePath/plus.png');
    imgCheckerboard = await _loadUiImage('$resourcePath/cb.png');
    imgPractice = await _loadUiImage('$resourcePath/practice.png');
    imgReady = await _loadUiImage('$resourcePath/ready.png');
    imgRelax = await _loadUiImage('$resourcePath/relax.png');

    final levelsToLoad = level == '1,2' ? ['1', '2'] : [level];
    for (final lvl in levelsToLoad) {
      final levelTemplate = lvl == '1'
          ? 'CCS_EEG_ANGELv2_Level2_Template'
          : 'CCS_EEG_ANGELv2_Level3_Template';

      final languagePath = 'assets/EPrimeFiles/$levelTemplate/$_languageFolder';
      final levelResourcePath = 'assets/EPrimeFiles/$levelTemplate/resources';

      imgWelcomeByLevel[lvl] = await _loadUiImageWithExt(
        '$languagePath/WelcomeLevel1',
      );
      imgInstructionsByLevel[lvl] = await _loadUiImageWithExt(
        '$languagePath/InstructionLevel1',
      );
      imgThankYouByLevel[lvl] = await _loadUiImageWithExt(
        '$languagePath/ThankYou',
      );
      imgPracticeEndByLevel[lvl] = await _loadUiImageWithExt(
        '$languagePath/PracticeEnd',
      );

      for (final entry in TrialGenerator.categories.entries) {
        final categoryName = entry.key;
        final fileList = entry.value['files'] as List<String>;
        cachedCategoryImages.putIfAbsent(categoryName, () => []);
        for (final fileName in fileList) {
          final img = await _loadUiImage('$levelResourcePath/$fileName');
          if (img != null) {
            if (!cachedCategoryImages[categoryName]!.contains(img)) {
              cachedCategoryImages[categoryName]!.add(img);
            }
          }
        }
      }

      final sounds = [
        'std1.wav',
        'std2.wav',
        'std3.wav',
        'deviant1.wav',
        'deviant2.wav',
        'deviant3.wav',
        'corollary.wav',
        'nocorollary.wav',
        'bellStart.wav',
        'bellEnd.wav',
      ];

      for (final sound in sounds) {
        final path = 'EPrimeFiles/$levelTemplate/resources/$sound';
        final player = AudioPlayer();
        try {
          await player.setPlayerMode(PlayerMode.lowLatency);
          await player.setVolume(1.0);
          await player.setSource(AssetSource(path));
          _cachedTonePlayers[path] = player;
        } catch (e) {
          debugPrint('Failed to preload $path: $e');
        }
      }
    }
    await _loadCustomStimuli();
  }

  Future<void> _loadCustomStimuli() async {
    const visualKeys = <String, String>{
      'visual_salient_1': 'face_present',
      'visual_control_1': 'face_absent',
      'visual_salient_2': 'shape_present',
      'visual_control_2': 'shape_absent',
    };
    for (final entry in visualKeys.entries) {
      final decoded = await _decodeImages(stimulusFiles[entry.key] ?? const []);
      if (decoded.isNotEmpty) cachedCategoryImages[entry.value] = decoded;
    }

    // A selected folder can be used as a bulk source when its images are
    // organised into stimulus-type subfolders. Explicit mappings above win.
    final visualDir = Directory(visualStimulusFolder);
    if (visualStimulusFolder.isNotEmpty && await visualDir.exists()) {
      final files = await visualDir
          .list(recursive: true)
          .where((entry) => entry is File)
          .cast<File>()
          .where(
            (file) => _hasExtension(file.path, const [
              '.png',
              '.jpg',
              '.jpeg',
              '.bmp',
            ]),
          )
          .toList();
      for (final entry in visualKeys.entries) {
        if ((stimulusFiles[entry.key] ?? const []).isNotEmpty) continue;
        final matching =
            files
                .where(
                  (file) =>
                      _matchesVisualType(file.path, entry.key, entry.value),
                )
                .map((file) => file.path)
                .toList()
              ..sort();
        final decoded = await _decodeImages(matching);
        if (decoded.isNotEmpty) cachedCategoryImages[entry.value] = decoded;
      }
    }

    _customStandardAudio = _existingFiles('auditory_standard');
    _customDeviantAudio = _existingFiles('auditory_deviant');
    _customCorollaryAudio = _existingFiles('auditory_corollary');
    _customNoCorollaryAudio = _existingFiles('auditory_no_corollary');

    final audioDir = Directory(auditoryStimulusFolder);
    if (auditoryStimulusFolder.isNotEmpty && await audioDir.exists()) {
      final files = await audioDir
          .list(recursive: true)
          .where((entry) => entry is File)
          .cast<File>()
          .where(
            (file) => const [
              '.wav',
              '.mp3',
              '.m4a',
              '.aac',
            ].any((extension) => file.path.toLowerCase().endsWith(extension)),
          )
          .map((file) => file.path)
          .toList();
      files.sort();
      final deviants = files
          .where(
            (path) =>
                path.toLowerCase().contains('rare') ||
                path.toLowerCase().contains('deviant'),
          )
          .toList();
      final noCorollary = files
          .where((path) => path.toLowerCase().contains('nocorollary'))
          .toList();
      final corollary = files
          .where(
            (path) =>
                path.toLowerCase().contains('corollary') &&
                !path.toLowerCase().contains('nocorollary'),
          )
          .toList();
      final standards = files
          .where(
            (path) =>
                !deviants.contains(path) &&
                !corollary.contains(path) &&
                !noCorollary.contains(path),
          )
          .toList();
      if (_customStandardAudio.isEmpty) _customStandardAudio = standards;
      if (_customDeviantAudio.isEmpty) _customDeviantAudio = deviants;
      if (_customCorollaryAudio.isEmpty) _customCorollaryAudio = corollary;
      if (_customNoCorollaryAudio.isEmpty) {
        _customNoCorollaryAudio = noCorollary;
      }
    }
  }

  List<String> _existingFiles(String key) => (stimulusFiles[key] ?? const [])
      .where((path) => File(path).existsSync())
      .toList();

  bool _hasExtension(String path, List<String> extensions) =>
      extensions.any((extension) => path.toLowerCase().endsWith(extension));

  bool _matchesVisualType(String path, String mappingKey, String engineKey) {
    final normalized = path.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '_',
    );
    final aliases = switch (mappingKey) {
      'visual_salient_1' => ['visual_salient_1', 'salient_1', engineKey],
      'visual_control_1' => ['visual_control_1', 'control_1', engineKey],
      'visual_salient_2' => ['visual_salient_2', 'salient_2', engineKey],
      _ => ['visual_control_2', 'control_2', engineKey],
    };
    return aliases.any(normalized.contains);
  }

  Future<List<ui.Image>> _decodeImages(List<String> paths) async {
    final decoded = <ui.Image>[];
    for (final path in paths) {
      if (!File(path).existsSync()) continue;
      final image = await _loadFileImage(path);
      if (image != null) decoded.add(image);
    }
    return decoded;
  }

  Future<ui.Image?> _loadFileImage(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, completer.complete);
      return completer.future;
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image?> _loadUiImage(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      final list = Uint8List.view(data.buffer);
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(list, (img) => completer.complete(img));
      return await completer.future;
    } catch (e) {
      return null;
    }
  }

  Future<ui.Image?> _loadUiImageWithExt(String assetBasePath) async {
    return await _loadUiImage('$assetBasePath.PNG') ??
        await _loadUiImage('$assetBasePath.png');
  }

  void start() {
    _experimentStartTime = DateTime.now();
    _stopwatch.reset();
    _stopwatch.start();
    resetPracticeMetrics();

    final rng = Random();
    final activeTrials = trialsPerBlockOption.startsWith('25') ? 25 : 20;
    final baselineTrials = 3;

    List<Trial> practiceTrials;
    if (excludePractice) {
      practiceTrials = [];
    } else if (level == '1,2') {
      final p1 = TrialGenerator.generatePractice(
        level: '1',
        trialsCount: practiceCount,
        rng: rng,
      );
      final p2 = TrialGenerator.generatePractice(
        level: '2',
        trialsCount: practiceCount,
        rng: rng,
      );
      practiceTrials = [...p1, ...p2];
    } else {
      practiceTrials = TrialGenerator.generatePractice(
        level: level,
        trialsCount: practiceCount,
        rng: rng,
      );
    }

    List<Trial> mainTrials;
    if (level == '1,2') {
      final halfBlocks = (blocksCount / 2).ceil();
      final remainingBlocks = max(1, blocksCount - halfBlocks);
      final level1Trials = TrialGenerator.generateLevelTrials(
        level: '1',
        blocks: halfBlocks,
        rng: rng,
        categorySetKey: categorySet,
        pairedToneOffsetMode: pairedToneOffsetMode,
        pairedToneOffsetMin: pairedToneOffsetMin,
        pairedToneOffsetMax: pairedToneOffsetMax,
        cdSchedule: cdSchedule,
        activeTrialsPerBlock: activeTrials,
        baselineTrialsPerBlock: baselineTrials,
        level2Cd: level2Cd,
      );
      final level2Trials = TrialGenerator.generateLevelTrials(
        level: '2',
        blocks: remainingBlocks,
        rng: rng,
        categorySetKey: categorySet,
        pairedToneOffsetMode: pairedToneOffsetMode,
        pairedToneOffsetMin: pairedToneOffsetMin,
        pairedToneOffsetMax: pairedToneOffsetMax,
        cdSchedule: cdSchedule,
        activeTrialsPerBlock: activeTrials,
        baselineTrialsPerBlock: baselineTrials,
        level2Cd: level2Cd,
      );

      final l1Blocks = _splitTrialsToBlocks(level1Trials);
      final l2Blocks = _splitTrialsToBlocks(level2Trials);

      final combinedBlocks = <List<Trial>>[...l1Blocks, ...l2Blocks];
      if (intermixLevelBlocks) {
        combinedBlocks.shuffle(rng);
      }

      mainTrials = [];
      for (var blockIdx = 0; blockIdx < combinedBlocks.length; blockIdx++) {
        final blockTrials = combinedBlocks[blockIdx];
        final seqBlockNum = blockIdx + 1;
        for (final trial in blockTrials) {
          mainTrials.add(trial.copyWith(block: seqBlockNum));
        }
      }
    } else {
      mainTrials = TrialGenerator.generateLevelTrials(
        level: level,
        blocks: blocksCount,
        rng: rng,
        categorySetKey: categorySet,
        pairedToneOffsetMode: pairedToneOffsetMode,
        pairedToneOffsetMin: pairedToneOffsetMin,
        pairedToneOffsetMax: pairedToneOffsetMax,
        cdSchedule: cdSchedule,
        activeTrialsPerBlock: activeTrials,
        baselineTrialsPerBlock: baselineTrials,
        level2Cd: level2Cd,
      );
    }

    _trialsList = [...practiceTrials, ...mainTrials];
    currentTrialGlobalIndex = 0;
    _nextIndependentToneTimeS = 1.0;

    if (excludePractice || practiceTrials.isEmpty) {
      stage = ErpStage.mainInstructions;
      playGuideAudio('InstructionLevel1.mp3');
    } else {
      stage = ErpStage.instructions;
      playGuideAudio('WelcomeLevel1.mp3');
    }
    onStateChanged?.call();

    _ticker = Ticker(_tick);
    _ticker!.start();
  }

  List<List<Trial>> _splitTrialsToBlocks(List<Trial> trials) {
    final blocksMap = <int, List<Trial>>{};
    for (final trial in trials) {
      blocksMap.putIfAbsent(trial.block, () => []).add(trial);
    }
    final sortedKeys = blocksMap.keys.toList()..sort();
    return sortedKeys.map((k) => blocksMap[k]!).toList();
  }

  void nextInstructionOrStart() {
    if (stage == ErpStage.instructions || stage == ErpStage.mainInstructions) {
      stage = ErpStage.trialPreStim;
      _audioPlayerGuide.stop();
      _startTrial();
    }
  }

  void dispose() {
    _ticker?.dispose();
    _audioPlayerTone.dispose();
    _audioPlayerCd.dispose();
    _audioPlayerGuide.dispose();
    for (final player in _cachedTonePlayers.values) {
      player.dispose();
    }
    for (final player in _asyncTonePlayers) {
      player.dispose();
    }
    _cachedTonePlayers.clear();
    _asyncTonePlayers.clear();
  }

  void progressSlide() {
    if (stage == ErpStage.instructions) {
      stage = ErpStage.trialPreStim;
      _audioPlayerGuide.stop();
      _startTrial();
    } else if (stage == ErpStage.practiceEnd) {
      stage = ErpStage.mainInstructions;
      playGuideAudio('InstructionLevel1.mp3');
    } else if (stage == ErpStage.mainInstructions) {
      stage = ErpStage.trialPreStim;
      _audioPlayerGuide.stop();
      _startTrial();
    } else if (stage == ErpStage.blockFeedback) {
      stage = ErpStage.trialPreStim;
      _audioPlayerGuide.stop();
      _startTrial();
    }
  }

  void playGuideAudio(String fileName) async {
    if (!guideAudioEnabled) {
      await _audioPlayerGuide.stop();
      return;
    }
    final currentLevel = currentStageLevel;
    final levelTemplate = currentLevel == '1'
        ? 'CCS_EEG_ANGELv2_Level2_Template'
        : 'CCS_EEG_ANGELv2_Level3_Template';
    final audioPath = 'EPrimeFiles/$levelTemplate/$_languageFolder/$fileName';
    try {
      await _audioPlayerGuide.stop();
      await _audioPlayerGuide.setVolume(1.0);
      await _audioPlayerGuide.play(AssetSource(audioPath));
    } catch (e) {
      // ignore
    }
  }

  void _playTone(String category, String toneType, int index) async {
    final custom = switch (category) {
      'corollary' => _customCorollaryAudio,
      'paired' when toneType == 'deviant' => _customDeviantAudio,
      'paired' => _customStandardAudio,
      _ => _customNoCorollaryAudio,
    };
    if (custom.isNotEmpty) {
      try {
        await _audioPlayerTone.stop();
        await _audioPlayerTone.play(
          DeviceFileSource(custom[index % custom.length]),
        );
        return;
      } catch (error) {
        debugPrint('Custom ANGEL audio failed: $error');
      }
    }
    final currentLevel = currentStageLevel;
    final levelTemplate = currentLevel == '1'
        ? 'CCS_EEG_ANGELv2_Level2_Template'
        : 'CCS_EEG_ANGELv2_Level3_Template';

    String tonePath;
    if (category == 'paired') {
      final name = toneType == 'standard'
          ? 'std${index + 1}.wav'
          : 'deviant${index + 1}.wav';
      tonePath = 'EPrimeFiles/$levelTemplate/resources/$name';
    } else if (category == 'corollary') {
      tonePath = 'EPrimeFiles/$levelTemplate/resources/corollary.wav';
    } else {
      tonePath = 'EPrimeFiles/$levelTemplate/resources/nocorollary.wav';
    }

    try {
      final player = _cachedTonePlayers[tonePath];
      if (player != null) {
        await player.stop();
        await player.setVolume(1.0);
        await player.play(AssetSource(tonePath));
      } else {
        if (category == 'paired') {
          if (tonePlaybackMode == 'async') {
            final p = _asyncTonePlayers[_asyncTonePlayerIndex];
            _asyncTonePlayerIndex =
                (_asyncTonePlayerIndex + 1) % _asyncTonePlayers.length;
            await p.stop();
            await p.setVolume(1.0);
            await p.play(AssetSource(tonePath));
          } else {
            await _audioPlayerTone.stop();
            await _audioPlayerTone.setVolume(1.0);
            await _audioPlayerTone.play(AssetSource(tonePath));
          }
        } else {
          await _audioPlayerCd.stop();
          await _audioPlayerCd.setVolume(1.0);
          await _audioPlayerCd.play(AssetSource(tonePath));
        }
      }
    } catch (e) {
      // ignore
    }
  }

  void _sendMarker(String label, int code) {
    final elapsed = _stopwatch.elapsedMilliseconds;
    final event = ErpEvent(
      code: code,
      label: label,
      elapsedMs: elapsed,
      timestamp: DateTime.now(),
    );
    eventLog.add(event);
    onMarkerSent?.call(event);
  }

  void _startTrial() {
    if (currentTrialGlobalIndex >= _trialsList.length) {
      stage = ErpStage.completed;
      _ticker?.stop();
      _stopwatch.stop();
      onStateChanged?.call();
      return;
    }

    currentTrial = _trialsList[currentTrialGlobalIndex];
    isPractice = currentTrial!.block == 0;
    currentTrialInBlock = currentTrial!.trialInBlock;
    currentBlockIndex = currentTrial!.block;

    if (currentTrialInBlock == 1 && !isPractice) {
      _sendMarker('block_start', MarkerCodes.blockStart);
    }

    trialStartGlobal = DateTime.now();
    _sendMarker('trial_start', MarkerCodes.trialStart);

    _trialStopwatch.reset();
    _trialStopwatch.start();

    userResponse = null;
    responseRtSeconds = null;
    responseOnsetGlobal = null;
    visualOnsetGlobal = null;
    visualOffsetGlobal = null;
    toneOnsetGlobal = null;
    cdOnsetGlobal = null;
    postMaskStartGlobal = null;
    postMaskEndGlobal = null;
    trialEndGlobal = null;

    tonePending = false;
    distractorVisible = false;
    targetVisible = false;
    maskVisible = false;
    cdNoneMarkerSent = false;
    cdDelayedPending = false;

    if (currentTrial!.trialType == 'baseline') {
      stage = ErpStage.trialPreStim;
      preStimDuration =
          responseWindowSeconds +
          (postMaskMinSeconds +
              Random().nextDouble() *
                  (postMaskMaxSeconds - postMaskMinSeconds));
      _sendMarker('baseline_start', MarkerCodes.baselineStart);
    } else {
      stage = ErpStage.trialPreStim;
      preStimDuration = max(0.240, -pairedToneOffsetMin);

      final list = cachedCategoryImages[currentTrial!.stimulusCategory] ?? [];
      if (list.isNotEmpty) {
        currentTargetImage = list[Random().nextInt(list.length)];
      }

      bool shouldPlayTone = true;
      if (tonePlaybackMode == 'alternate') {
        shouldPlayTone = (currentTrialGlobalIndex % 2 == 0);
      } else if (tonePlaybackMode == 'skip') {
        if (_audioPlayerTone.state == PlayerState.playing) {
          shouldPlayTone = false;
        }
      } else if (tonePlaybackMode == 'independent') {
        shouldPlayTone = false;
      }

      if (shouldPlayTone &&
          currentTrial!.auditoryClass != 'blank' &&
          currentTrial!.auditoryOffsetS != null) {
        toneStartSeconds = preStimDuration + currentTrial!.auditoryOffsetS!;
        tonePending = true;
      } else {
        toneStartSeconds = null;
      }

      if (visualDistractorMode == 'desync') {
        final offset =
            pairedToneOffsetMin +
            Random().nextDouble() * (pairedToneOffsetMax - pairedToneOffsetMin);
        distractorStartSeconds = preStimDuration + offset;
        distractorEndSeconds = distractorStartSeconds! + stimDurationSeconds;
      } else {
        distractorStartSeconds = null;
        distractorEndSeconds = null;
      }
    }

    onStateChanged?.call();
  }

  void _tick(Duration elapsed) {
    if (isPaused) return;
    if (stage == ErpStage.idle ||
        stage == ErpStage.instructions ||
        stage == ErpStage.mainInstructions ||
        stage == ErpStage.practiceEnd ||
        stage == ErpStage.blockFeedback ||
        stage == ErpStage.completed) {
      return;
    }

    final double t = _trialStopwatch.elapsedMicroseconds / 1000000.0;
    final double globalTimeS = _stopwatch.elapsedMicroseconds / 1000000.0;

    if (tonePlaybackMode == 'independent') {
      if (globalTimeS >= _nextIndependentToneTimeS) {
        _nextIndependentToneTimeS =
            globalTimeS + (1.5 + Random().nextDouble() * 1.0);
        final isDeviant = Random().nextDouble() < 0.2;
        final audClass = isDeviant ? 'deviant' : 'standard';
        _playTone('paired', audClass, Random().nextInt(3));
        toneOnsetGlobal = DateTime.now();
        _sendMarker(
          audClass == 'standard' ? 'paired_standard' : 'paired_deviant',
          audClass == 'standard'
              ? MarkerCodes.pairedStandard
              : MarkerCodes.pairedDeviant,
        );
      }
    }

    if (currentTrial!.trialType == 'baseline') {
      if (t >= preStimDuration) {
        _endTrial();
      }
      return;
    }

    if (tonePending &&
        toneStartSeconds != null &&
        toneStartSeconds! < preStimDuration &&
        t >= toneStartSeconds!) {
      _playTone('paired', currentTrial!.auditoryClass, Random().nextInt(3));
      toneOnsetGlobal = DateTime.now();
      _sendMarker(
        currentTrial!.auditoryClass == 'standard'
            ? 'paired_standard'
            : 'paired_deviant',
        currentTrial!.auditoryClass == 'standard'
            ? MarkerCodes.pairedStandard
            : MarkerCodes.pairedDeviant,
      );
      tonePending = false;
    }

    if (stage == ErpStage.trialPreStim && t >= preStimDuration) {
      stage = ErpStage.trialVisual;
      targetVisible = true;
      maskVisible = true;

      SchedulerBinding.instance.addPostFrameCallback((_) {
        visualOnsetGlobal = DateTime.now();
        _sendMarker(
          currentTrial!.frequencyClass == 'frequent'
              ? 'visual_frequent'
              : 'visual_rare',
          currentTrial!.frequencyClass == 'frequent'
              ? MarkerCodes.visualFrequent
              : MarkerCodes.visualRare,
        );
      });
      onStateChanged?.call();
    }

    if (tonePending && toneStartSeconds != null && t >= toneStartSeconds!) {
      _playTone('paired', currentTrial!.auditoryClass, Random().nextInt(3));
      toneOnsetGlobal = DateTime.now();
      _sendMarker(
        currentTrial!.auditoryClass == 'standard'
            ? 'paired_standard'
            : 'paired_deviant',
        currentTrial!.auditoryClass == 'standard'
            ? MarkerCodes.pairedStandard
            : MarkerCodes.pairedDeviant,
      );
      tonePending = false;
    }

    if (visualDistractorMode == 'desync' &&
        distractorStartSeconds != null &&
        distractorEndSeconds != null) {
      final shouldShow =
          t >= distractorStartSeconds! && t < distractorEndSeconds!;
      if (shouldShow != distractorVisible) {
        distractorVisible = shouldShow;
        onStateChanged?.call();
      }
    } else if (visualDistractorMode == 'sync') {
      distractorVisible = stage == ErpStage.trialVisual;
    }

    if (stage == ErpStage.trialVisual &&
        t >= (preStimDuration + stimDurationSeconds)) {
      stage = ErpStage.trialResponseWindow;
      targetVisible = false;

      SchedulerBinding.instance.addPostFrameCallback((_) {
        visualOffsetGlobal = DateTime.now();
        _sendMarker('visual_offset', MarkerCodes.visualOffset);
      });
      onStateChanged?.call();
    }

    final responseDeadline = preStimDuration + responseWindowSeconds;
    if (stage == ErpStage.trialResponseWindow && t >= responseDeadline) {
      stage = ErpStage.trialPostMask;
      postMaskStartGlobal = DateTime.now();
      postMaskDuration =
          postMaskMinSeconds +
          Random().nextDouble() * (postMaskMaxSeconds - postMaskMinSeconds);

      if (userResponse == null) {
        _sendMarker('response_miss', MarkerCodes.responseMiss);
        if (currentTrial!.corollaryMode == 'none' && !cdNoneMarkerSent) {
          _sendMarker('cd_none', MarkerCodes.cdNone);
          cdNoneMarkerSent = true;
        }
      }

      if (currentTrial!.corollaryMode == 'delayed') {
        final anchor = responseRtSeconds != null
            ? (preStimDuration + responseRtSeconds!)
            : responseDeadline;
        final delay = 0.300 + Random().nextDouble() * 0.200;
        delayedCdPlaySeconds = anchor + delay;
        cdDelayedPending = true;
      }
      onStateChanged?.call();
    }

    if (cdDelayedPending &&
        delayedCdPlaySeconds != null &&
        t >= delayedCdPlaySeconds!) {
      _playTone('corollary', 'delayed', 0);
      cdOnsetGlobal = DateTime.now();
      _sendMarker('cd_delayed', MarkerCodes.cdDelayed);
      cdDelayedPending = false;
    }

    final double trialEndSeconds = responseDeadline + postMaskDuration;
    if (stage == ErpStage.trialPostMask && t >= trialEndSeconds) {
      if (!cdDelayedPending) {
        _endTrial();
      }
    }
  }

  void registerResponse(String side) {
    if (stage != ErpStage.trialVisual &&
        stage != ErpStage.trialResponseWindow) {
      return;
    }
    if (userResponse != null) return;

    userResponse = side;
    responseOnsetGlobal = DateTime.now();
    final double visualOnsetLocal = preStimDuration;
    final double elapsedLocal = _trialStopwatch.elapsedMicroseconds / 1000000.0;
    responseRtSeconds = elapsedLocal - visualOnsetLocal;

    _sendMarker(
      side == 'left' ? 'response_left' : 'response_right',
      side == 'left' ? MarkerCodes.responseLeft : MarkerCodes.responseRight,
    );

    final isCorrect = side == currentTrial!.correctResponse;
    if (!isPractice) {
      blockTotalResponseCount++;
      if (isCorrect) {
        blockCorrectCount++;
      }
      blockSumRt += responseRtSeconds!;
    }

    if (currentTrial!.corollaryMode == 'immediate') {
      _playTone('corollary', 'immediate', 0);
      cdOnsetGlobal = DateTime.now();
      _sendMarker('cd_immediate', MarkerCodes.cdImmediate);
    } else if (currentTrial!.corollaryMode == 'none') {
      _sendMarker('cd_none', MarkerCodes.cdNone);
      cdNoneMarkerSent = true;
    }
    onStateChanged?.call();
  }

  void _endTrial() {
    trialEndGlobal = DateTime.now();
    _sendMarker('trial_end', MarkerCodes.trialEnd);

    if (isPractice && currentTrial!.trialType != 'baseline') {
      practiceActiveCount++;
      final isCorrect = userResponse == currentTrial!.correctResponse;
      if (isCorrect) {
        practiceCorrectCount++;
      }
      if (responseRtSeconds != null) {
        practiceResponseCount++;
        practiceSumRt += responseRtSeconds!;
      }
    }

    final row = <String, dynamic>{};
    row.addAll(currentTrial!.toMap());

    row['trial_global_index'] = currentTrialGlobalIndex + 1;
    row['target_file'] = currentTargetImage != null ? 'target.png' : '';
    row['response'] = userResponse ?? 'miss';

    // Write rt (seconds)
    row['rt'] = responseRtSeconds != null
        ? (responseRtSeconds! * 1000.0).toStringAsFixed(1)
        : '';

    // Write accuracy (1/0)
    row['accuracy'] = currentTrial!.correctResponse == null
        ? ''
        : (userResponse == currentTrial!.correctResponse ? 1 : 0);

    row['trial_start_global'] = trialStartGlobal?.toIso8601String() ?? '';
    row['visual_onset_global'] = visualOnsetGlobal?.toIso8601String() ?? '';
    row['visual_offset_global'] = visualOffsetGlobal?.toIso8601String() ?? '';
    row['tone_onset_global'] = toneOnsetGlobal?.toIso8601String() ?? '';
    row['cd_onset_global'] = cdOnsetGlobal?.toIso8601String() ?? '';
    row['post_mask_start_global'] =
        postMaskStartGlobal?.toIso8601String() ?? '';
    row['post_mask_end_global'] = postMaskEndGlobal?.toIso8601String() ?? '';
    row['trial_end_global'] = trialEndGlobal?.toIso8601String() ?? '';
    row['phase'] = isPractice ? 'practice' : 'main';

    loggedRows.add(row);

    final activeTrials = trialsPerBlockOption.startsWith('25') ? 25 : 20;
    final totalTrialsPerBlock = activeTrials + 3;

    final wasEndOfBlock = isPractice
        ? currentTrialInBlock == practiceCount
        : currentTrialInBlock == totalTrialsPerBlock;

    currentTrialGlobalIndex++;

    if (wasEndOfBlock && isPractice) {
      lastCompletedPracticeLevel = currentTrial!.level;
      stage = ErpStage.practiceEnd;
      playGuideAudio('PracticeEnd.mp3');
      onStateChanged?.call();
    } else if (wasEndOfBlock && !isPractice && currentBlockIndex % 2 == 0) {
      stage = ErpStage.blockFeedback;
      playGuideAudio('FeedbackCongrats.mp3');
      onStateChanged?.call();
    } else {
      _startTrial();
    }
  }

  double get blockAccuracy {
    if (blockTotalResponseCount == 0) return 0.0;
    return blockCorrectCount / blockTotalResponseCount;
  }

  double get blockMeanRtMs {
    if (blockTotalResponseCount == 0) return 0.0;
    return (blockSumRt / blockTotalResponseCount) * 1000.0;
  }

  void resetBlockFeedbackMetrics() {
    blockCorrectCount = 0;
    blockTotalResponseCount = 0;
    blockSumRt = 0.0;
  }

  Future<String?> writeLogFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dataDir = Directory('${dir.path}/data');
      if (!await dataDir.exists()) {
        await dataDir.create(recursive: true);
      }
      final stamp = sessionStartTime.toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final file = File(
        '${dataDir.path}/angel_${participant}_level${level}_$stamp.csv',
      );

      final sink = file.openWrite();
      if (loggedRows.isNotEmpty) {
        final keys = loggedRows.first.keys.toList();
        sink.writeln(keys.join(','));
        for (final row in loggedRows) {
          final values = keys.map((key) {
            final val = row[key];
            return '"$val"';
          });
          sink.writeln(values.join(','));
        }
      }
      await sink.flush();
      await sink.close();
      return file.path;
    } catch (e) {
      return null;
    }
  }

  List<Map<String, dynamic>> get trialLog => List.unmodifiable(loggedRows);

  DateTime get sessionStartTime => _experimentStartTime ?? DateTime.now();
}
