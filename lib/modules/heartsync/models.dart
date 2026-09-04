import 'dart:math';

enum HeartSyncPulseMode { ppg, ecg }

enum HeartSyncStimulusMode { tones, images }

enum HeartSyncStimulusKind { frequent, rare }

enum CardiacPhase { systole, diastole, indeterminate }

enum HeartSyncResponse { frequent, rare }

class HeartSyncConfig {
  const HeartSyncConfig({
    this.totalStimuli = 100,
    this.rareProportion = 0.2,
    this.trialsPerBlock = 25,
    this.blocks = 4,
    this.pulseMode = HeartSyncPulseMode.ppg,
    this.channelName = 'PPG',
    this.stimulusMode = HeartSyncStimulusMode.tones,
    this.frequentToneHz = 800,
    this.rareToneHz = 1200,
    this.toneDurationMs = 100,
    this.frequentFilePath = '',
    this.rareFilePath = '',
    this.imageDurationMs = 250,
    this.deliveryProbability = 0.8,
    this.minSkippedBeats = 2,
    this.maxSkippedBeats = 5,
    this.ipiHistoryLength = 5,
    this.systolicOffsetPercent = 0,
    this.diastolicOffsetPercent = 45,
    this.detectionLagMs = 0,
    this.refractoryMs = 450,
    this.responseWindowMs = 2000,
    this.minimumStimulusIntervalMs = 600,
    this.postHocSystolicEndPercent = 35,
    this.adaptiveOffsets = false,
    this.adaptiveStepPercent = 5,
    this.adaptiveMinTrials = 8,
    this.recordPhysiology = true,
  });

  final int totalStimuli;
  final double rareProportion;
  final int trialsPerBlock;
  final int blocks;
  final HeartSyncPulseMode pulseMode;
  final String channelName;
  final HeartSyncStimulusMode stimulusMode;
  final double frequentToneHz;
  final double rareToneHz;
  final int toneDurationMs;
  final String frequentFilePath;
  final String rareFilePath;
  final int imageDurationMs;
  final double deliveryProbability;
  // Retained for backwards-compatible settings migration; scheduling now uses
  // [deliveryProbability] independently on every detected beat.
  final int minSkippedBeats;
  final int maxSkippedBeats;
  final int ipiHistoryLength;
  final double systolicOffsetPercent;
  final double diastolicOffsetPercent;
  final int detectionLagMs;
  final int refractoryMs;
  final int responseWindowMs;
  final int minimumStimulusIntervalMs;
  final double postHocSystolicEndPercent;
  final bool adaptiveOffsets;
  final double adaptiveStepPercent;
  final int adaptiveMinTrials;
  final bool recordPhysiology;

  HeartSyncConfig validated() {
    final safeBlocks = max(1, blocks);
    final safePerBlock = max(1, trialsPerBlock);
    final requested = max(1, totalStimuli);
    return HeartSyncConfig(
      totalStimuli: min(requested, safeBlocks * safePerBlock),
      rareProportion: rareProportion.clamp(0.01, 0.99),
      trialsPerBlock: safePerBlock,
      blocks: safeBlocks,
      pulseMode: pulseMode,
      channelName: channelName.trim().isEmpty
          ? pulseMode.name.toUpperCase()
          : channelName.trim(),
      stimulusMode: stimulusMode,
      frequentToneHz: frequentToneHz.clamp(80, 8000),
      rareToneHz: rareToneHz.clamp(80, 8000),
      toneDurationMs: toneDurationMs.clamp(20, 2000),
      frequentFilePath: frequentFilePath,
      rareFilePath: rareFilePath,
      imageDurationMs: imageDurationMs.clamp(20, 5000),
      deliveryProbability: deliveryProbability.clamp(0.75, 0.90),
      minSkippedBeats: max(0, minSkippedBeats),
      maxSkippedBeats: max(minSkippedBeats, maxSkippedBeats),
      ipiHistoryLength: ipiHistoryLength.clamp(2, 30),
      systolicOffsetPercent: systolicOffsetPercent.clamp(0, 99),
      diastolicOffsetPercent: diastolicOffsetPercent.clamp(0, 99),
      detectionLagMs: detectionLagMs.clamp(0, 1000),
      refractoryMs: refractoryMs.clamp(250, 1500),
      responseWindowMs: responseWindowMs.clamp(200, 10000),
      minimumStimulusIntervalMs: minimumStimulusIntervalMs.clamp(100, 5000),
      postHocSystolicEndPercent: postHocSystolicEndPercent.clamp(5, 80),
      adaptiveOffsets: adaptiveOffsets,
      adaptiveStepPercent: adaptiveStepPercent.clamp(1, 20),
      adaptiveMinTrials: adaptiveMinTrials.clamp(4, 100),
      recordPhysiology: recordPhysiology,
    );
  }
}

class HeartSyncTrialPlan {
  const HeartSyncTrialPlan({
    required this.index,
    required this.block,
    required this.stimulus,
    required this.targetPhase,
  });

  final int index;
  final int block;
  final HeartSyncStimulusKind stimulus;
  final CardiacPhase targetPhase;
}

class CardiacSample {
  const CardiacSample(this.timestamp, this.value);

  final DateTime timestamp;
  final double value;
}

class HeartSyncTrialResult {
  HeartSyncTrialResult({
    required this.plan,
    required this.scheduledAt,
    required this.playbackRequestedAt,
    required this.presentedAt,
    required this.estimatedIpiMs,
    required this.realtimeOffsetPercent,
  });

  final HeartSyncTrialPlan plan;
  final DateTime scheduledAt;

  /// Time at which playback was submitted to the platform audio backend.
  final DateTime playbackRequestedAt;

  /// Time at which the backend acknowledged playback (not acoustic onset).
  final DateTime presentedAt;
  final double estimatedIpiMs;
  final double realtimeOffsetPercent;
  DateTime? responseAt;
  HeartSyncResponse? response;
  CardiacPhase postHocPhase = CardiacPhase.indeterminate;
  double? postHocPhasePercent;

  double? get reactionTimeMs => responseAt == null
      ? null
      : responseAt!.difference(presentedAt).inMicroseconds / 1000;

  double get audioCommandLatencyMs =>
      presentedAt.difference(playbackRequestedAt).inMicroseconds / 1000;

  bool get isCorrect =>
      (plan.stimulus == HeartSyncStimulusKind.frequent &&
          response == HeartSyncResponse.frequent) ||
      (plan.stimulus == HeartSyncStimulusKind.rare &&
          response == HeartSyncResponse.rare);
}

class HeartSyncRtSummary {
  const HeartSyncRtSummary({
    required this.systolicMeanMs,
    required this.diastolicMeanMs,
    required this.ratio,
    required this.systolicCount,
    required this.diastolicCount,
  });

  final double? systolicMeanMs;
  final double? diastolicMeanMs;
  final double? ratio;
  final int systolicCount;
  final int diastolicCount;
}

class HeartSyncBoundarySummary {
  const HeartSyncBoundarySummary({
    required this.boundaryPercent,
    required this.boundaryLowerPercent,
    required this.boundaryUpperPercent,
    required this.effectMagnitude,
    required this.probabilityBest,
    required this.probabilityNearBest,
    required this.ratioLower,
    required this.ratioUpper,
    required this.isEstablished,
    required this.status,
    required this.metrics,
    required this.eligibleTrials,
    required this.candidatesEvaluated,
  });

  final double boundaryPercent;
  final double boundaryLowerPercent;
  final double boundaryUpperPercent;
  final double effectMagnitude;
  final double probabilityBest;
  final double probabilityNearBest;
  final double ratioLower;
  final double ratioUpper;
  final bool isEstablished;
  final String status;
  final HeartSyncRtSummary metrics;
  final int eligibleTrials;
  final int candidatesEvaluated;
}

class HeartSyncSummary {
  const HeartSyncSummary({
    required this.rareCorrect,
    required this.rareIncorrect,
    required this.rareAllResponded,
    required this.frequentCorrect,
    required this.frequentIncorrect,
    required this.frequentAllResponded,
    required this.adaptiveBoundaries,
    required this.correctResponses,
    required this.completedTrials,
    required this.postHocAssignedTrials,
    required this.detectedBeats,
    required this.deliveryRate,
    required this.collisionSkippedBeats,
  });

  final HeartSyncRtSummary rareCorrect;
  final HeartSyncRtSummary rareIncorrect;
  final HeartSyncRtSummary rareAllResponded;
  final HeartSyncRtSummary frequentCorrect;
  final HeartSyncRtSummary frequentIncorrect;
  final HeartSyncRtSummary frequentAllResponded;
  final Map<String, HeartSyncBoundarySummary?> adaptiveBoundaries;
  double? get rareSystolicMeanMs => rareCorrect.systolicMeanMs;
  double? get rareDiastolicMeanMs => rareCorrect.diastolicMeanMs;
  double? get ratio => rareCorrect.ratio;
  final int correctResponses;
  final int completedTrials;
  final int postHocAssignedTrials;
  final int detectedBeats;
  final double? deliveryRate;
  final int collisionSkippedBeats;
}
