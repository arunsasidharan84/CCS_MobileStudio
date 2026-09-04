import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models/eeg_sample.dart';
import '../../core/models/module_type.dart';
import '../../core/models/sleep_score.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/alert_service.dart';
import '../../core/services/file_naming_service.dart';
import 'auditory_stim_service.dart';
import 'sleep_channel_selection.dart';
import 'sleep_pipeline.dart';

/// Module controller for Train NIDRA (Sleep staging & Auditory Stimulation).
class NidraModule extends ChangeNotifier {
  NidraModule({required this.sessionManager, required this.alertService})
    : stimService = AuditoryStimService(alertService: alertService);

  final SessionManager sessionManager;
  final AlertService alertService;
  final AuditoryStimService stimService;

  SleepPipeline? _pipeline;
  int _pipelineGeneration = 0;
  bool _usesModel = false;
  bool _isPipelineReady = false;
  String? _pipelineError;
  String? _scoringDerivation;

  final List<SleepScoreResult> _scores = [];
  final List<String> _scoreDerivations = [];
  SleepScoreResult? _latestScore;
  Future<void> _checkpointQueue = Future<void>.value();

  bool get isPipelineReady => _isPipelineReady;
  bool get usesModel => _usesModel;
  String? get pipelineError => _pipelineError;
  String? get scoringDerivation => _scoringDerivation;
  List<SleepScoreResult> get scores => List.unmodifiable(_scores);
  List<String> get scoreDerivations => List.unmodifiable(_scoreDerivations);
  SleepScoreResult? get latestScore => _latestScore;

  Future<void> initPipeline(
    double sampleRate, {
    List<String> channelLabels = const [],
    List<bool>? enabledChannels,
    String? preferredSignalLabel,
    String? preferredReferenceLabel,
  }) async {
    disposePipeline();
    final generation = _pipelineGeneration;
    _pipelineError = null;
    _scoringDerivation = null;
    late final String modelPath;
    try {
      modelPath = await _deployScoringModel();
    } catch (error, stackTrace) {
      debugPrint(
        '[NidraModule] Could not deploy TinySleepNet: '
        '$error\n$stackTrace',
      );
      if (generation == _pipelineGeneration) {
        _pipelineError = 'TinySleepNet model could not be loaded';
        notifyListeners();
      }
      return;
    }
    if (generation != _pipelineGeneration) return;
    final selection = SleepChannelSelection.fromLabels(
      channelLabels,
      enabledChannels: enabledChannels,
      preferredSignalLabel: preferredSignalLabel,
      preferredReferenceLabel: preferredReferenceLabel,
    );
    if (selection == null) {
      _pipelineError = 'No EEG channel is available for sleep scoring';
      notifyListeners();
      return;
    }
    _scoringDerivation = selection.derivationLabel;
    _pipeline = SleepPipeline(
      sampleRate: sampleRate,
      modelPath: modelPath,
      signalChannelIndex: selection.signalIndex,
      referenceChannelIndex: selection.referenceIndex,
      onInitialized: (usesModel) {
        _usesModel = usesModel;
        _isPipelineReady = usesModel;
        if (!usesModel) {
          _pipelineError = 'TinySleepNet ONNX initialization failed';
        }
        notifyListeners();
      },
    );

    _pipeline!.scores.listen((score) {
      _scores.add(score);
      _scoreDerivations.add(_scoringDerivation ?? 'EEG');
      _latestScore = score;
      stimService.onNewScore(score);
      _queueScoreCheckpoint();
      notifyListeners();
    });
  }

  Future<String> _deployScoringModel() async {
    const assetStem = 'assets/models/tinysleepnet-supratak/model.onnx';
    final support = await getApplicationSupportDirectory();
    final modelDirectory = Directory('${support.path}/sleep_models');
    await modelDirectory.create(recursive: true);
    final modelPath = '${modelDirectory.path}/model.onnx';
    final dataPath = '$modelPath.data';
    await _copyAsset(assetStem, modelPath);
    await _copyAsset('$assetStem.data', dataPath);
    return modelPath;
  }

  Future<void> _copyAsset(String assetPath, String destinationPath) async {
    final data = await rootBundle.load(assetPath);
    final file = File(destinationPath);
    if (await file.exists() && await file.length() == data.lengthInBytes) {
      return;
    }
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }

  void _queueScoreCheckpoint() {
    final start = sessionManager.sessionStart;
    if (!sessionManager.isRecording ||
        sessionManager.activeModule != ModuleType.nidra ||
        start == null ||
        _scores.isEmpty) {
      return;
    }

    final subject = sessionManager.subject;
    final snapshot = jsonEncode(
      _scores.indexed
          .map(
            (entry) => {
              ...entry.$2.toJson(),
              'scoringDerivation': entry.$1 < _scoreDerivations.length
                  ? _scoreDerivations[entry.$1]
                  : _scoringDerivation,
            },
          )
          .toList(),
    );
    _checkpointQueue = _checkpointQueue
        .then((_) async {
          final path = await FileNamingService.jsonPath(
            subject,
            ModuleType.nidra,
            start,
          );
          await File(path).writeAsString(snapshot, flush: true);
          await FileNamingService.exportToDownloads(
            path,
            subject: subject,
            sessionStem: FileNamingService.stem(
              subject,
              ModuleType.nidra,
              start,
            ),
          );
        })
        .onError((error, stackTrace) {
          debugPrint('[NidraModule] Score checkpoint failed: $error');
        });
  }

  void pushSample(EegSample sample) {
    if (_usesModel) _pipeline?.push(sample);
  }

  void setScoringStep(double stepSeconds) {
    _pipeline?.setScoringStep(stepSeconds);
  }

  void clearScores() {
    _scores.clear();
    _scoreDerivations.clear();
    _latestScore = null;
    notifyListeners();
  }

  void disposePipeline() {
    _pipelineGeneration++;
    _pipeline?.dispose();
    _pipeline = null;
    _usesModel = false;
    _isPipelineReady = false;
  }

  @override
  void dispose() {
    disposePipeline();
    stimService.dispose();
    super.dispose();
  }
}
