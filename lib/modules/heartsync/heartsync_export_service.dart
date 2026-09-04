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
      'trial,block,stimulus,target_phase,scheduled_at,playback_requested_at,presented_at,audio_command_latency_ms,response,response_at,rt_ms,correct,estimated_ipi_ms,realtime_offset_percent,posthoc_phase,posthoc_phase_percent',
      for (final trial in trials)
        [
          trial.plan.index + 1,
          trial.plan.block + 1,
          trial.plan.stimulus.name,
          trial.plan.targetPhase.name,
          trial.scheduledAt.toIso8601String(),
          trial.playbackRequestedAt.toIso8601String(),
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
        'pulseMode': config.pulseMode.name,
        'channelName': config.channelName,
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
