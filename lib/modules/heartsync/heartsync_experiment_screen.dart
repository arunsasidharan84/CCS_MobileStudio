import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/models/module_type.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/services/multi_stream_lsl_service.dart';
import '../../core/services/session_manager.dart';
import 'heartsync_engine.dart';
import 'heartsync_export_service.dart';
import 'heartsync_plots.dart';
import 'models.dart';

class HeartSyncExperimentScreen extends StatefulWidget {
  const HeartSyncExperimentScreen({
    super.key,
    required this.participant,
    required this.config,
  });

  final String participant;
  final HeartSyncConfig config;

  @override
  State<HeartSyncExperimentScreen> createState() =>
      _HeartSyncExperimentScreenState();
}

class _HeartSyncExperimentScreenState extends State<HeartSyncExperimentScreen> {
  late HeartSyncEngine _engine;
  late DateTime _startedAt;
  bool _exported = false;
  bool _ownsRecording = false;
  List<String> _paths = const [];

  @override
  void initState() {
    super.initState();
    _startedAt = DateTime.now();
    _engine = HeartSyncEngine(
      config: widget.config,
      acquisition: context.read<AcquisitionService>(),
      multiLsl: context.read<MultiStreamLslService>(),
      sessionManager: context.read<SessionManager>(),
    )..addListener(_onEngineChanged);
    unawaited(_begin());
  }

  Future<void> _begin() async {
    final acq = context.read<AcquisitionService>();
    final sessions = context.read<SessionManager>();
    if (widget.config.inputMode == HeartSyncInputMode.live &&
        widget.config.recordPhysiology &&
        sessions.isStreaming) {
      try {
        await sessions.startSession(
          subject: widget.participant,
          module: ModuleType.heartsync,
          channelCount: acq.channelCount,
          sampleRate: acq.sampleRate.round(),
          channelLabels: acq.recordingChannelLabels(null),
          enabledChannels: acq.recordingEnabledChannels(null),
        );
        _ownsRecording = sessions.activeModule == ModuleType.heartsync;
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Recording could not start: $error')),
          );
        }
      }
    }
    await _engine.start();
  }

  void _onEngineChanged() {
    if (mounted) setState(() {});
    if (_engine.state == HeartSyncRunState.completed && !_exported) {
      _exported = true;
      unawaited(_finishAndExport());
    }
  }

  Future<void> _finishAndExport() async {
    final summary = _engine.summary;
    if (summary == null) return;
    final sessions = context.read<SessionManager>();
    final paths = await HeartSyncExportService.write(
      subject: widget.participant,
      startedAt: _startedAt,
      config: widget.config,
      trials: _engine.results,
      samples: _engine.cardiacSamples,
      summary: summary,
    );
    if (_ownsRecording) {
      await sessions.stopSession();
      _ownsRecording = false;
    }
    for (final path in paths) {
      await FileNamingService.exportToDownloads(
        path,
        subject: widget.participant,
        sessionStem: FileNamingService.stem(
          widget.participant,
          ModuleType.heartsync,
          _startedAt,
        ),
      );
    }
    if (mounted) setState(() => _paths = paths);
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngineChanged);
    _engine.dispose();
    if (!_exported && _ownsRecording) {
      unawaited(context.read<SessionManager>().stopSession());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _engine.state == HeartSyncRunState.completed,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final stop = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Stop HeartSync?'),
            content: const Text(
              'Completed trials will be post-processed and saved.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Continue task'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Stop and save'),
              ),
            ],
          ),
        );
        if (stop == true) _engine.stopEarly();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF070B12),
        appBar: AppBar(
          title: Text(
            'HeartSync • Block ${_engine.currentBlock}/${widget.config.blocks}',
          ),
          automaticallyImplyLeading:
              _engine.state == HeartSyncRunState.completed,
        ),
        body: SafeArea(child: _body()),
      ),
    );
  }

  Widget _body() {
    if (_engine.state == HeartSyncRunState.completed) return _summary();
    if (_engine.state == HeartSyncRunState.error) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.volume_off, size: 72, color: Colors.redAccent),
              const SizedBox(height: 16),
              Text(
                _engine.error ?? 'Stimulus playback failed.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _engine.stopEarly,
                child: const Text('Stop and save completed trials'),
              ),
            ],
          ),
        ),
      );
    }
    if (_engine.state == HeartSyncRunState.blockBreak) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.pause_circle, size: 72, color: Colors.amber),
            const SizedBox(height: 16),
            Text(
              'Block ${_engine.currentBlock - 1} complete',
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _engine.continueBlock,
              child: const Text('Start next block'),
            ),
          ],
        ),
      );
    }
    final imagePath = _engine.visibleStimulus == HeartSyncStimulusKind.frequent
        ? widget.config.frequentFilePath
        : widget.config.rareFilePath;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: _engine.results.length / _engine.totalTrials,
                ),
              ),
              const SizedBox(width: 12),
              Text('${_engine.results.length}/${_engine.totalTrials}'),
              const SizedBox(width: 18),
              Text('IPI ${_engine.estimatedIpiMs.toStringAsFixed(0)} ms'),
            ],
          ),
        ),
        if (widget.config.showLiveWaveform)
          HeartSyncLivePlot(
            ppg: _engine.visiblePpgTrace,
            ecg: _engine.visibleEcgTrace,
            beats: _engine.beatTrace,
            markers: _engine.markerTrace,
            seconds: widget.config.waveformSeconds,
          ),
        if (widget.config.showLiveWaveform) const SizedBox(height: 8),
        Expanded(
          child: Center(
            child: _engine.state == HeartSyncRunState.calibrating
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 18),
                      Text(
                        'Detecting a stable cardiac rhythm…',
                        style: TextStyle(fontSize: 20),
                      ),
                    ],
                  )
                : widget.config.stimulusMode == HeartSyncStimulusMode.images &&
                      _engine.visibleStimulus != null &&
                      imagePath.isNotEmpty &&
                      File(imagePath).existsSync()
                ? Image.file(File(imagePath), fit: BoxFit.contain)
                : const Icon(Icons.add, size: 72, color: Colors.white30),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Expanded(
                child: _responseButton(
                  label: 'FREQUENT',
                  color: const Color(0xFF2563EB),
                  response: HeartSyncResponse.frequent,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: _responseButton(
                  label: 'RARE',
                  color: const Color(0xFFDC2626),
                  response: HeartSyncResponse.rare,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _responseButton({
    required String label,
    required Color color,
    required HeartSyncResponse response,
  }) => FilledButton(
    style: FilledButton.styleFrom(
      backgroundColor: color,
      minimumSize: const Size.fromHeight(92),
      textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
    ),
    onPressed: _engine.canRespond ? () => _engine.respond(response) : null,
    child: Text(label),
  );

  Widget _summary() {
    final s = _engine.summary!;
    final detectionLatency = _engine.results
        .map((trial) => trial.detectionLatencyMs)
        .whereType<double>()
        .toList();
    final dispatchError = _engine.results
        .map((trial) => trial.timerDispatchErrorMs?.abs())
        .whereType<double>()
        .toList();
    final audioLatency = _engine.results
        .map((trial) => trial.audioCommandLatencyMs)
        .toList();
    String metric(double? value) =>
        value?.toStringAsFixed(1) ?? 'Insufficient valid rare responses';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(
                    Icons.favorite,
                    size: 64,
                    color: Color(0xFFF43F5E),
                  ),
                  const Text(
                    'HeartSync complete',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 22),
                  HeartSyncVerificationPlot(
                    ppg: _engine.ppgSamples,
                    ecg: _engine.ecgSamples,
                    results: _engine.results,
                    config: widget.config,
                  ),
                  const Divider(height: 28),
                  const Text(
                    'Timing quality',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  _metric(
                    'Peak detection latency (mean)',
                    '${_mean(detectionLatency)?.toStringAsFixed(1) ?? 'n/a'} ms',
                  ),
                  _metric(
                    'Timer dispatch error (mean absolute / p95)',
                    '${_mean(dispatchError)?.toStringAsFixed(1) ?? 'n/a'} / '
                        '${_percentile95(dispatchError)?.toStringAsFixed(1) ?? 'n/a'} ms',
                  ),
                  _metric(
                    'Audio command latency (mean / p95)',
                    '${_mean(audioLatency)?.toStringAsFixed(1) ?? 'n/a'} / '
                        '${_percentile95(audioLatency)?.toStringAsFixed(1) ?? 'n/a'} ms',
                  ),
                  const Divider(height: 28),
                  _metric(
                    'Rare RT — post-hoc systole',
                    '${metric(s.rareSystolicMeanMs)} ms',
                  ),
                  _metric(
                    'Rare RT — post-hoc diastole',
                    '${metric(s.rareDiastolicMeanMs)} ms',
                  ),
                  _metric(
                    'Systolic / diastolic RT ratio',
                    s.ratio?.toStringAsFixed(3) ?? 'Insufficient data',
                  ),
                  const Divider(height: 28),
                  const Text(
                    'Comparative RT ratios (systolic / diastolic)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  _rtRatioMetric('Rare — correct only', s.rareCorrect),
                  _rtRatioMetric('Rare — all responded', s.rareAllResponded),
                  _rtRatioMetric('Rare — incorrect only', s.rareIncorrect),
                  _rtRatioMetric('Frequent — correct only', s.frequentCorrect),
                  _rtRatioMetric(
                    'Frequent — all responded',
                    s.frequentAllResponded,
                  ),
                  _rtRatioMetric(
                    'Frequent — incorrect only',
                    s.frequentIncorrect,
                  ),
                  if (s.adaptiveBoundaries.isNotEmpty) ...[
                    const Divider(height: 28),
                    const Text(
                      'Bootstrap functional peri-pulse boundaries',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    for (final entry in s.adaptiveBoundaries.entries)
                      _boundaryMetric(entry.key, entry.value),
                  ],
                  const Divider(height: 28),
                  _metric(
                    'Correct responses',
                    '${s.correctResponses}/${s.completedTrials}',
                  ),
                  _metric(
                    'Post-hoc phase assignments',
                    '${s.postHocAssignedTrials}/${s.completedTrials}',
                  ),
                  _metric(
                    'Stimuli / detected beats',
                    '${s.completedTrials}/${s.detectedBeats} (${s.deliveryRate == null ? 'n/a' : '${(s.deliveryRate! * 100).toStringAsFixed(1)}%'})',
                  ),
                  _metric(
                    'Beats skipped to prevent close stimuli',
                    '${s.collisionSkippedBeats}',
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _paths.isEmpty
                        ? 'Finalizing files…'
                        : 'Saved ${_paths.length} files to the output folder configured in Settings.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _metric(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(color: Colors.white70)),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    ),
  );

  double? _mean(List<double> values) => values.isEmpty
      ? null
      : values.reduce((first, second) => first + second) / values.length;

  double? _percentile95(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = [...values]..sort();
    return sorted[((sorted.length - 1) * 0.95).round()];
  }

  Widget _rtRatioMetric(String label, HeartSyncRtSummary metric) {
    final ratio = metric.ratio?.toStringAsFixed(3) ?? 'n/a';
    final systolic = metric.systolicMeanMs?.toStringAsFixed(1) ?? 'n/a';
    final diastolic = metric.diastolicMeanMs?.toStringAsFixed(1) ?? 'n/a';
    return _metric(
      label,
      '$ratio  (S $systolic ms, n=${metric.systolicCount}; '
      'D $diastolic ms, n=${metric.diastolicCount})',
    );
  }

  Widget _boundaryMetric(String key, HeartSyncBoundarySummary? boundary) {
    if (boundary == null) return _metric(key, 'Insufficient trials');
    return _metric(
      key,
      '${boundary.isEstablished ? 'ESTABLISHED' : 'NOT ESTABLISHED'} • '
      '${boundary.boundaryPercent.toStringAsFixed(1)}% '
      '(95% ${boundary.boundaryLowerPercent.toStringAsFixed(1)}–'
      '${boundary.boundaryUpperPercent.toStringAsFixed(1)}%) • '
      'ratio ${boundary.metrics.ratio!.toStringAsFixed(3)} '
      '(95% ${boundary.ratioLower.toStringAsFixed(3)}–'
      '${boundary.ratioUpper.toStringAsFixed(3)}) • '
      'stability ${(boundary.probabilityNearBest * 100).toStringAsFixed(1)}%\n'
      '${boundary.status}',
    );
  }
}
