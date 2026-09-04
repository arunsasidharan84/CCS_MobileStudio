import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'models/experiment_models.dart';

class TrialRunner extends ChangeNotifier {
  final Random _random = Random();
  final List<TrialRecord> _records = [];

  TrialPhase currentPhase = TrialPhase.idle;
  int currentSetSize = 2;
  int _consecutiveCorrect = 0;
  bool _isRunning = false;
  bool _paused = false;
  Completer<void>? _resumeCompleter;
  Timer? _elapsedTimer;
  int elapsedSeconds = 0;
  int _currentTrialNum = 0;
  DateTime sessionStartTime = DateTime.now();
  int _sessionStartMs = 0;

  int totalTrials = 60;
  int fixationDurationMs = 500;
  int cueDurationMs = 300;
  int encodingDurationMs = 300;
  int delayDurationMs = 1000;

  Function(String label, int code)? onMarkerSent;

  bool get isPaused => _paused;
  bool get isRunning => _isRunning;
  int get currentTrialNumber => _currentTrialNum;
  List<TrialRecord> get records => List.unmodifiable(_records);

  int get accuracyCount => _records.where((r) => r.accuracy == 1).length;
  double get overallAccuracy =>
      _records.isEmpty ? 0 : accuracyCount / _records.length;
  double get meanRtMs {
    final validRts = _records
        .where((r) => r.reactionTimeMs != null)
        .map((r) => r.reactionTimeMs!)
        .toList();
    if (validRts.isEmpty) return 0;
    return validRts.reduce((a, b) => a + b) / validRts.length;
  }

  void pause() {
    if (!_isRunning || _paused) return;
    _paused = true;
    _resumeCompleter = Completer<void>();
    notifyListeners();
  }

  void resume() {
    if (!_isRunning || !_paused) return;
    _paused = false;
    _resumeCompleter?.complete();
    _resumeCompleter = null;
    notifyListeners();
  }

  TrialPlan? currentTrial;
  Hemifield? currentCue;

  Completer<MatchDecision>? _responseCompleter;
  int _retrievalOnsetMs = 0;

  void _pushMarker(String label, int marker) {
    try {
      onMarkerSent?.call(label, marker);
    } catch (e) {
      debugPrint("Failed to push marker $marker ($label): $e");
    }
  }

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    sessionStartTime = DateTime.now();
    _sessionStartMs = sessionStartTime.millisecondsSinceEpoch;
    elapsedSeconds = 0;
    _currentTrialNum = 0;
    _records.clear();

    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isRunning && !_paused) {
        elapsedSeconds++;
        notifyListeners();
      }
    });

    currentSetSize = 2;
    _consecutiveCorrect = 0;

    for (int trialNum = 1; trialNum <= totalTrials; trialNum++) {
      if (!_isRunning) break;
      _currentTrialNum = trialNum;
      final trial = _createTrialPlan(trialNum, currentSetSize);
      await _runTrial(trial);
    }

    _transitionTo(TrialPhase.finished, null);
    _isRunning = false;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    notifyListeners();
  }

  void stop() {
    _isRunning = false;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _responseCompleter?.complete(MatchDecision.noResponse);
    notifyListeners();
  }

  void submitResponse(MatchDecision decision) {
    if (decision == MatchDecision.noResponse) return;
    if (currentPhase != TrialPhase.retrieval ||
        _responseCompleter == null ||
        _responseCompleter!.isCompleted) {
      return;
    }

    _responseCompleter!.complete(decision);
  }

  Future<void> _runTrial(TrialPlan trial) async {
    final trialStartGlobalMs =
        DateTime.now().millisecondsSinceEpoch - _sessionStartMs;
    _transitionTo(TrialPhase.iti, trial);
    await _delay(_random.nextInt(501) + 300); // 300 to 800 ms ITI

    final fixationOnsetGlobalMs =
        DateTime.now().millisecondsSinceEpoch - _sessionStartMs;
    _pushMarker('fixation', 88);
    _transitionTo(TrialPhase.fixation, trial);
    await _delay(fixationDurationMs);

    final cueOnsetGlobalMs =
        DateTime.now().millisecondsSinceEpoch - _sessionStartMs;
    _transitionTo(TrialPhase.cue, trial);
    await _delay(cueDurationMs);

    final encodingOnsetGlobalMs =
        DateTime.now().millisecondsSinceEpoch - _sessionStartMs;
    final encodingMarker =
        (trial.setSize * 10) + (trial.cuedHemifield == Hemifield.left ? 1 : 9);
    _pushMarker(
      'encoding_sz${trial.setSize}_${trial.cuedHemifield.name}',
      encodingMarker,
    );
    _transitionTo(TrialPhase.encoding, trial);
    await _delay(encodingDurationMs);

    final maintenanceOnsetGlobalMs =
        DateTime.now().millisecondsSinceEpoch - _sessionStartMs;
    _transitionTo(TrialPhase.maintenance, trial);
    await _delay(delayDurationMs);

    final retrievalOnsetGlobalMs =
        DateTime.now().millisecondsSinceEpoch - _sessionStartMs;
    final response = await _runRetrieval(trial);
    final userDecision = response ?? MatchDecision.noResponse;

    int responseMarker = 12; // omission
    if (userDecision == MatchDecision.match) {
      responseMarker = 11;
    } else if (userDecision == MatchDecision.mismatch) {
      responseMarker = 10;
    }
    _pushMarker('response_${userDecision.name}', responseMarker);

    final responseOnsetGlobalMs = userDecision != MatchDecision.noResponse
        ? (DateTime.now().millisecondsSinceEpoch - _sessionStartMs)
        : null;

    final isResponseCorrect = _isCorrect(userDecision, trial);
    final accuracy = isResponseCorrect ? 1 : 0;

    int? rt;
    if (userDecision != MatchDecision.noResponse) {
      rt = DateTime.now().millisecondsSinceEpoch - _retrievalOnsetMs;
    }

    final trialEndGlobalMs =
        DateTime.now().millisecondsSinceEpoch - _sessionStartMs;

    _records.add(
      TrialRecord(
        trialNumber: trial.trialNumber,
        setSize: trial.setSize,
        cuedHemifield: trial.cuedHemifield,
        isMatchTrial: trial.isMatchTrial,
        userResponse: userDecision,
        accuracy: accuracy,
        reactionTimeMs: rt,
        trialStartGlobalMs: trialStartGlobalMs,
        fixationOnsetGlobalMs: fixationOnsetGlobalMs,
        cueOnsetGlobalMs: cueOnsetGlobalMs,
        encodingOnsetGlobalMs: encodingOnsetGlobalMs,
        maintenanceOnsetGlobalMs: maintenanceOnsetGlobalMs,
        retrievalOnsetGlobalMs: retrievalOnsetGlobalMs,
        responseOnsetGlobalMs: responseOnsetGlobalMs,
        trialEndGlobalMs: trialEndGlobalMs,
      ),
    );

    _updateStaircase(isResponseCorrect);
  }

  Future<MatchDecision?> _runRetrieval(TrialPlan trial) async {
    _responseCompleter = Completer<MatchDecision>();
    _retrievalOnsetMs = DateTime.now().millisecondsSinceEpoch;
    _transitionTo(TrialPhase.retrieval, trial);

    try {
      final decision = await _responseCompleter!.future.timeout(
        const Duration(milliseconds: 2000),
      );
      return decision;
    } on TimeoutException {
      return MatchDecision.noResponse;
    } finally {
      _responseCompleter = null;
    }
  }

  void _transitionTo(TrialPhase phase, TrialPlan? trial) {
    currentPhase = phase;
    currentTrial = trial;
    if (phase == TrialPhase.cue ||
        phase == TrialPhase.encoding ||
        phase == TrialPhase.retrieval) {
      currentCue = trial?.cuedHemifield;
    } else {
      currentCue = null;
    }
    notifyListeners();
  }

  Future<void> _delay(int milliseconds) async {
    if (!_isRunning) return;
    final endTime = DateTime.now().millisecondsSinceEpoch + milliseconds;
    while (DateTime.now().millisecondsSinceEpoch < endTime) {
      if (!_isRunning) return;
      if (_paused) {
        final remaining = endTime - DateTime.now().millisecondsSinceEpoch;
        await _resumeCompleter?.future;
        if (!_isRunning) return;
        return _delay(remaining);
      }
      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  TrialPlan _createTrialPlan(int trialNumber, int setSize) {
    final cuedHemifield = _random.nextBool() ? Hemifield.left : Hemifield.right;
    final isMatchTrial = _random.nextBool();

    final leftItems = _createHemifieldItems(Hemifield.left, setSize);
    final rightItems = _createHemifieldItems(Hemifield.right, setSize);

    final cuedItems = cuedHemifield == Hemifield.left ? leftItems : rightItems;
    final uncuedItems = cuedHemifield == Hemifield.left
        ? rightItems
        : leftItems;

    final cuedTestItems = isMatchTrial
        ? cuedItems.map((e) => e.copyWith()).toList()
        : _createMismatchItems(cuedItems);

    List<StimulusItem> testItems;
    if (cuedHemifield == Hemifield.left) {
      testItems = [...cuedTestItems, ...uncuedItems.map((e) => e.copyWith())];
    } else {
      testItems = [...uncuedItems.map((e) => e.copyWith()), ...cuedTestItems];
    }

    return TrialPlan(
      trialNumber: trialNumber,
      setSize: setSize,
      cuedHemifield: cuedHemifield,
      isMatchTrial: isMatchTrial,
      memoryItems: [...leftItems, ...rightItems],
      testItems: testItems,
    );
  }

  List<StimulusItem> _createHemifieldItems(Hemifield hemifield, int setSize) {
    final slots = List<StimulusSlot>.from(_slotTemplate)..shuffle(_random);
    final colors = List<Color>.from(_colorPalette)..shuffle(_random);

    final selectedSlots = slots.take(setSize).toList();
    final selectedColors = colors.take(setSize).toList();

    return List.generate(
      setSize,
      (i) => StimulusItem(
        hemifield: hemifield,
        slot: selectedSlots[i],
        color: selectedColors[i],
      ),
    );
  }

  List<StimulusItem> _createMismatchItems(List<StimulusItem> cuedItems) {
    final changedIndex = _random.nextInt(cuedItems.length);
    final usedColors = cuedItems.map((e) => e.color).toSet();
    final availableColors = _colorPalette
        .where((c) => !usedColors.contains(c))
        .toList();
    final replacement =
        availableColors[_random.nextInt(availableColors.length)];

    final newItems = cuedItems.map((e) => e.copyWith()).toList();
    newItems[changedIndex] = newItems[changedIndex].copyWith(
      color: replacement,
    );
    return newItems;
  }

  bool _isCorrect(MatchDecision decision, TrialPlan trial) {
    if (decision == MatchDecision.match) return trial.isMatchTrial;
    if (decision == MatchDecision.mismatch) return !trial.isMatchTrial;
    return false;
  }

  void _updateStaircase(bool wasCorrect) {
    if (wasCorrect) {
      _consecutiveCorrect++;
      if (_consecutiveCorrect >= 2) {
        currentSetSize = (currentSetSize + 1).clamp(3, 8);
        _consecutiveCorrect = 0;
      }
    } else {
      _consecutiveCorrect = 0;
      currentSetSize = (currentSetSize - 1).clamp(3, 8);
    }
  }

  Future<String> writeLogFile(String subjectId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dataDir = Directory('${docs.path}/data');
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }

    final cleanSubject = subjectId.trim().isEmpty
        ? 'unknown'
        : subjectId.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

    final stamp = sessionStartTime.toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final file = File('${dataDir.path}/adaptive_wm_${cleanSubject}_$stamp.csv');

    final rows = <List<dynamic>>[
      TrialRecord.csvHeader,
      ..._records.map((r) => r.toCsvRow()),
    ];

    final csvContent = rows.map((r) => r.join(',')).join('\n');
    await file.writeAsString(csvContent);
    debugPrint('[TrialRunner] Saved CSV log to ${file.path}');
    return file.path;
  }

  static const List<StimulusSlot> _slotTemplate = [
    StimulusSlot(-0.82, -0.58),
    StimulusSlot(0, -0.72),
    StimulusSlot(0.82, -0.58),
    StimulusSlot(-0.82, 0),
    StimulusSlot(0.82, 0),
    StimulusSlot(-0.82, 0.58),
    StimulusSlot(0, 0.72),
    StimulusSlot(0.82, 0.58),
  ];

  static const List<Color> _colorPalette = [
    Color.fromARGB(255, 228, 30, 40),
    Color.fromARGB(255, 242, 128, 20),
    Color.fromARGB(255, 242, 215, 20),
    Color.fromARGB(255, 100, 222, 20),
    Color.fromARGB(255, 20, 188, 90),
    Color.fromARGB(255, 20, 215, 222),
    Color.fromARGB(255, 20, 100, 222),
    Color.fromARGB(255, 138, 20, 222),
    Color.fromARGB(255, 222, 20, 165),
    Colors.white,
  ];
}
