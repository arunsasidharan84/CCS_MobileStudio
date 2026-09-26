import 'dart:convert';
import 'dart:io';

import '../../core/models/module_type.dart';
import '../../core/services/file_naming_service.dart';
import 'models.dart';

class HeartSyncExportService {
  static Future<List<String>> write({
    required String subject,
    required DateTime startedAt,
    required HeartSyncConfig config,
    required List<HeartSyncTrialResult> trials,
    required List<CardiacSample> samples,
    required HeartSyncSummary summary,
  }) async {
    final trialPath = await FileNamingService.csvPath(
      subject,
      ModuleType.heartsync,
      startedAt,
    );
    final trialFile = File(trialPath);
    final rows = <String>[
      'trial,block,stimulus,target_phase,trigger_peak_at,peak_detected_at,detection_latency_ms,target_at,scheduled_at,playback_requested_at,timer_dispatch_error_ms,presented_at,audio_command_latency_ms,response,response_at,rt_ms,correct,estimated_ipi_ms,realtime_offset_percent,posthoc_phase,posthoc_phase_percent',
      for (final trial in trials)
        [
          trial.plan.index + 1,
          trial.plan.block + 1,
          trial.plan.stimulus.name,
          trial.plan.targetPhase.name,
          trial.triggerPeakAt?.toIso8601String() ?? '',
          trial.peakDetectedAt?.toIso8601String() ?? '',
          trial.detectionLatencyMs?.toStringAsFixed(3) ?? '',
          trial.targetAt?.toIso8601String() ?? '',
          trial.scheduledAt.toIso8601String(),
          trial.playbackRequestedAt.toIso8601String(),
          trial.timerDispatchErrorMs?.toStringAsFixed(3) ?? '',
          trial.presentedAt.toIso8601String(),
          trial.audioCommandLatencyMs.toStringAsFixed(3),
          trial.response?.name ?? '',
          trial.responseAt?.toIso8601String() ?? '',
          trial.reactionTimeMs?.toStringAsFixed(3) ?? '',
          trial.isCorrect,
          trial.estimatedIpiMs.toStringAsFixed(3),
          trial.realtimeOffsetPercent.toStringAsFixed(2),
          trial.postHocPhase.name,
          trial.postHocPhasePercent?.toStringAsFixed(3) ?? '',
        ].map(_csv).join(','),
    ];
    await trialFile.writeAsString(rows.join('\n'));

    final stem = trialPath.substring(0, trialPath.lastIndexOf('.'));
    final cardiacFile = File('${stem}_cardiac.csv');
    await cardiacFile.writeAsString(
      [
        'timestamp,value',
        for (final sample in samples)
          '${sample.timestamp.toIso8601String()},${sample.value}',
      ].join('\n'),
    );
    final summaryFile = File('${stem}_summary.json');
    await summaryFile.writeAsString(
      const JsonEncoder.withIndent(' ').convert({
        'rareSystolicMeanMs': summary.rareSystolicMeanMs,
        'rareDiastolicMeanMs': summary.rareDiastolicMeanMs,
        'systolicToDiastolicRatio': summary.ratio,
        'rtMetrics': {
          'rare': {
            'correctOnly': _rtJson(summary.rareCorrect),
            'incorrectOnly': _rtJson(summary.rareIncorrect),
            'allResponded': _rtJson(summary.rareAllResponded),
          },
          'frequent': {
            'correctOnly': _rtJson(summary.frequentCorrect),
            'incorrectOnly': _rtJson(summary.frequentIncorrect),
            'allResponded': _rtJson(summary.frequentAllResponded),
          },
        },
        'bayesianFunctionalBoundaries': {
          for (final entry in summary.adaptiveBoundaries.entries)
            entry.key: _boundaryJson(entry.value),
        },
        'correctResponses': summary.correctResponses,
        'completedTrials': summary.completedTrials,
        'postHocAssignedTrials': summary.postHocAssignedTrials,
        'detectedBeats': summary.detectedBeats,
        'deliveryRate': summary.deliveryRate,
        'configuredDeliveryProbability': config.deliveryProbability,
        'minimumStimulusIntervalMs': config.minimumStimulusIntervalMs,
        'collisionSkippedBeats': summary.collisionSkippedBeats,
        'timingQuality': _timingJson(trials),
        'pulseMode': config.pulseMode.name,
        'inputMode': config.inputMode.name,
        'replayFilePath': config.replayFilePath,
        'channelName': config.channelName,
        'ppgThresholdSigma': config.ppgThresholdSigma,
        'ecgThresholdSigma': config.ecgThresholdSigma,
        'detectionHighPassHz': config.detectionHighPassHz,
        'detectionLowPassHz': config.detectionLowPassHz,
        'postHocSystolicEndPercent': config.postHocSystolicEndPercent,
        'adaptiveBoundarySearch': config.adaptiveOffsets,
        'boundaryStepPercent': config.adaptiveStepPercent,
        'boundaryMinimumTrials': config.adaptiveMinTrials,
      }),
    );
    return [trialFile.path, cardiacFile.path, summaryFile.path];
  }

  static Map<String, Object?> _rtJson(HeartSyncRtSummary metric) => {
    'systolicMeanMs': metric.systolicMeanMs,
    'diastolicMeanMs': metric.diastolicMeanMs,
    'systolicToDiastolicRatio': metric.ratio,
    'systolicCount': metric.systolicCount,
    'diastolicCount': metric.diastolicCount,
  };

  static Map<String, Object?> _timingJson(List<HeartSyncTrialResult> trials) {
    final detection = trials
        .map((trial) => trial.detectionLatencyMs)
        .whereType<double>()
        .toList();
    final dispatch = trials
        .map((trial) => trial.timerDispatchErrorMs?.abs())
        .whereType<double>()
        .toList();
    final audio = trials.map((trial) => trial.audioCommandLatencyMs).toList();
    return {
      'meanDetectionLatencyMs': _mean(detection),
      'meanAbsoluteTimerDispatchErrorMs': _mean(dispatch),
      'p95AbsoluteTimerDispatchErrorMs': _percentile95(dispatch),
      'meanAudioCommandLatencyMs': _mean(audio),
      'p95AudioCommandLatencyMs': _percentile95(audio),
    };
  }

  static double? _mean(List<double> values) => values.isEmpty
      ? null
      : values.reduce((first, second) => first + second) / values.length;

  static double? _percentile95(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    return sorted[((sorted.length - 1) * 0.95).round()];
  }

  static Map<String, Object?>? _boundaryJson(
    HeartSyncBoundarySummary? boundary,
  ) => boundary == null
      ? null
      : {
          'boundaryPercent': boundary.boundaryPercent,
          'boundary95LowPercent': boundary.boundaryLowerPercent,
          'boundary95HighPercent': boundary.boundaryUpperPercent,
          'absoluteLogRatio': boundary.effectMagnitude,
          'probabilityBest': boundary.probabilityBest,
          'probabilityWithinOneStep': boundary.probabilityNearBest,
          'ratio95Low': boundary.ratioLower,
          'ratio95High': boundary.ratioUpper,
          'isEstablished': boundary.isEstablished,
          'status': boundary.status,
          'eligibleTrials': boundary.eligibleTrials,
          'candidatesEvaluated': boundary.candidatesEvaluated,
          ..._rtJson(boundary.metrics),
        };

  static String _csv(Object value) {
    final text = value.toString();
    return '"${text.replaceAll('"', '""')}"';
  }
}
