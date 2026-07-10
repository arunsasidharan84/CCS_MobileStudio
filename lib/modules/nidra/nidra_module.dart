import 'package:flutter/foundation.dart';

import '../../core/models/eeg_sample.dart';
import '../../core/models/sleep_score.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/alert_service.dart';
import 'sleep_pipeline.dart';
import 'auditory_stim_service.dart';

/// Module controller for Train NIDRA (Sleep staging & Auditory Stimulation).
class NidraModule extends ChangeNotifier {
  NidraModule({
    required this.sessionManager,
    required this.alertService,
  }) : stimService = AuditoryStimService(alertService: alertService);

  final SessionManager sessionManager;
  final AlertService alertService;
  final AuditoryStimService stimService;

  SleepPipeline? _pipeline;
  bool _usesModel = false;
  bool _isPipelineReady = false;

  final List<SleepScoreResult> _scores = [];
  SleepScoreResult? _latestScore;

  bool get isPipelineReady => _isPipelineReady;
  bool get usesModel => _usesModel;
  List<SleepScoreResult> get scores => List.unmodifiable(_scores);
  SleepScoreResult? get latestScore => _latestScore;

  void initPipeline(double sampleRate) {
    disposePipeline();
    _pipeline = SleepPipeline(
      sampleRate: sampleRate,
      onInitialized: (usesModel) {
        _usesModel = usesModel;
        _isPipelineReady = true;
        notifyListeners();
      },
    );

    _pipeline!.scores.listen((score) {
      _scores.add(score);
      _latestScore = score;
      stimService.onNewScore(score);
      notifyListeners();
    });
  }

  void pushSample(EegSample sample) {
    _pipeline?.push(sample);
  }

  void setScoringStep(double stepSeconds) {
    _pipeline?.setScoringStep(stepSeconds);
  }

  void clearScores() {
    _scores.clear();
    _latestScore = null;
    notifyListeners();
  }

  void disposePipeline() {
    _pipeline?.dispose();
    _pipeline = null;
    _isPipelineReady = false;
  }

  @override
  void dispose() {
    disposePipeline();
    stimService.dispose();
    super.dispose();
  }
}
