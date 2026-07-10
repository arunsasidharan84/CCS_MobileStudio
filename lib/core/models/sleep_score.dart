/// Sleep stage classification results from the native ONNX scorer.
enum SleepStage {
  wake,
  n1,
  n2,
  n3,
  rem;

  static SleepStage fromIndex(int index) {
    return switch (index) {
      0 => SleepStage.wake,
      1 => SleepStage.n1,
      2 => SleepStage.n2,
      3 => SleepStage.n3,
      4 => SleepStage.rem,
      _ => SleepStage.wake,
    };
  }

  String get label => switch (this) {
    SleepStage.wake => 'Wake',
    SleepStage.n1 => 'N1',
    SleepStage.n2 => 'N2',
    SleepStage.n3 => 'N3',
    SleepStage.rem => 'REM',
  };
}

class SleepScoreResult {
  const SleepScoreResult({
    required this.stage,
    required this.confidence,
    required this.epochIndex,
    required this.deltaPower,
    required this.thetaPower,
    required this.alphaPower,
    required this.betaPower,
    required this.artifactRatio,
    required this.probWake,
    required this.probN1,
    required this.probN2,
    required this.probN3,
    required this.probREM,
  });

  final SleepStage stage;
  final double confidence;
  final int epochIndex;
  final double deltaPower;
  final double thetaPower;
  final double alphaPower;
  final double betaPower;
  final double artifactRatio;
  final double probWake;
  final double probN1;
  final double probN2;
  final double probN3;
  final double probREM;

  Map<String, dynamic> toJson() => {
    'epochIndex': epochIndex,
    'stage': stage.label,
    'confidence': confidence,
    'deltaPower': deltaPower,
    'thetaPower': thetaPower,
    'alphaPower': alphaPower,
    'betaPower': betaPower,
    'artifactRatio': artifactRatio,
    'probWake': probWake,
    'probN1': probN1,
    'probN2': probN2,
    'probN3': probN3,
    'probREM': probREM,
  };
}
