import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import '../../core/models/device_profile.dart';
import '../../core/models/module_type.dart';
import '../../core/models/signal_stream_sample.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/services/session_manager.dart';
import 'hrd_models.dart';
import 'hrd_native.dart';
import 'hrd_report.dart';

enum HrdPhase {
  ready,
  fixation,
  collecting,
  processing,
  response,
  rating,
  complete,
  stopped,
  error,
}

class HrdEngine extends ChangeNotifier {
  HrdEngine({
    required this.config,
    required this.subject,
    required this.sessions,
    required List<Stream<SignalStreamSample>> streams,
  }) {
    config.validate();
    catches = hrdCatchPlan(config.trials, config.catchTrials, random);
    for (final stream in streams) {
      subscriptions.add(stream.listen(_sample));
    }
  }
  final HrdConfig config;
  final String subject;
  final SessionManager sessions;
  final random = Random();
  final startedAt = DateTime.now();
  final player = AudioPlayer();
  final subscriptions = <StreamSubscription<SignalStreamSample>>[];
  final rows = <Map<String, Object?>>[];
  final history = <List<double>>[];
  final samples = <double>[];
  final sampleTimes = <String>[];
  final paths = <String>[];
  late final List<bool> catches;
  HrdPhase phase = HrdPhase.ready;
  String message =
      'Compare the feedback with your own heart rate. Choose faster (1/left) or slower (0/right).';
  List<double> cleaned = [],
      peakMask = [],
      estimate = List.filled(4, double.nan);
  double sampleRate = 0, hr = double.nan, delta = 0, presented = 0;
  String? lockedSource;
  String? processingMethod;
  DateTime? firstSample, lastSample;
  Timer? deadline, progressTicker;
  final reactionClock = Stopwatch();
  bool disposed = false, ownsRecording = false, saveFailed = false;
  Future<void>? activeAnalysis;
  int generation = 0;
  int? response, rating;
  double? rt, sliderPosition;
  double progress = 0;
  String? csvPath;
  Future<void>? pendingWrite, pendingExport;
  int get trial => rows.length + 1;
  void _set(HrdPhase value, String text) {
    if (disposed) return;
    if (value != HrdPhase.collecting) {
      progressTicker?.cancel();
    }
    phase = value;
    message = text;
    notifyListeners();
  }

  void _sample(SignalStreamSample s) {
    if (phase != HrdPhase.collecting || config.simulation) return;
    final type = config.ecg ? SignalType.ecg : SignalType.ppg;
    final i = s.channelLabels.indexWhere(
      (v) => v.trim().toLowerCase() == config.channel.trim().toLowerCase(),
    );
    if (i < 0 || i >= s.channels.length) return;
    final actual = i < s.channelTypes.length ? s.channelTypes[i] : s.signalType;
    if (actual != type) return;
    final source = '${s.deviceProfileId}/${s.streamId}';
    if (config.source.isNotEmpty && source != config.source) return;
    if (lockedSource != null && lockedSource != source) return;
    if (!s.channels[i].isFinite ||
        !s.sampleRate.isFinite ||
        s.sampleRate <= 22) {
      return;
    }
    lockedSource ??= source;
    if (lastSample != null) {
      final dt = s.timestamp.difference(lastSample!).inMicroseconds / 1e6;
      if (dt <= 0) return;
      if (dt > max(0.1, 3 / s.sampleRate) || s.sampleRate != sampleRate) {
        samples.clear();
        sampleTimes.clear();
        firstSample = null;
      }
    }
    sampleRate = s.sampleRate;
    firstSample ??= s.timestamp;
    lastSample = s.timestamp;
    samples.add(s.channels[i]);
    sampleTimes.add(s.timestamp.toIso8601String());
    final elapsed = s.timestamp.difference(firstSample!).inMicroseconds / 1e6;
    progress = (elapsed / config.epochSeconds).clamp(0.0, 1.0);
    if (elapsed >= config.epochSeconds) {
      deadline?.cancel();
      activeAnalysis = _analyze();
      unawaited(activeAnalysis!);
    } else if (samples.length % max(1, (sampleRate / 5).round()) == 0) {
      notifyListeners();
    }
  }

  Future<void> start() async {
    if (phase != HrdPhase.ready) return;
    csvPath = await FileNamingService.csvPath(
      subject,
      ModuleType.hrd,
      startedAt,
    );
    paths.add(csvPath!);
    await _write();
    if (disposed) return;
    _next();
  }

  void _next() {
    samples.clear();
    sampleTimes.clear();
    firstSample = null;
    lastSample = null;
    progress = 0;
    response = null;
    rating = null;
    rt = null;
    sliderPosition = null;
    _set(HrdPhase.fixation, '+');
    deadline = Timer(const Duration(seconds: 1), () {
      _set(
        HrdPhase.collecting,
        config.simulation
            ? 'DEMO: simulated heartbeat'
            : 'Focus on your heartbeat',
      );
      if (config.simulation) {
        final clock = Stopwatch()..start();
        progressTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
          if (disposed || phase != HrdPhase.collecting) {
            progressTicker?.cancel();
            return;
          }
          progress = (clock.elapsedMicroseconds / (config.epochSeconds * 1e6))
              .clamp(0.0, 1.0);
          notifyListeners();
        });
        deadline = Timer(Duration(seconds: config.epochSeconds), () {
          activeAnalysis = _simulate();
          unawaited(activeAnalysis!);
        });
        return;
      }
      deadline = Timer(Duration(seconds: config.epochSeconds * 3), () {
        _set(
          HrdPhase.error,
          'No continuous ${config.channel} signal. Check connection and channel, then retry.',
        );
      });
    });
  }

  Future<void> retry() async {
    if (phase != HrdPhase.error) return;
    if (saveFailed) {
      try {
        await _write();
        if (rows.length >= config.trials) {
          await export();
          _set(HrdPhase.complete, 'Task complete. Data saved.');
        } else {
          _next();
        }
        saveFailed = false;
      } catch (e) {
        _set(HrdPhase.error, 'Saving failed: $e');
      }
      return;
    }
    lockedSource = null;
    _next();
  }

  Future<void> _simulate() async {
    final token = generation;
    try {
      sampleRate = config.ecg ? 250 : 62.5;
      lockedSource = 'simulation';
      final data = await compute(hrdCompute, <String, Object>{
        'simulation': true,
        'sampleRate': sampleRate,
        'seconds': config.epochSeconds.toDouble(),
        'ecg': config.ecg,
        'ecgMethod': config.ecgMethod.name,
      });
      if (disposed || token != generation) return;
      samples.addAll(data['samples'] as List<double>);
      final begin = DateTime.now().subtract(
        Duration(seconds: config.epochSeconds),
      );
      sampleTimes.addAll(
        List.generate(
          samples.length,
          (i) => begin
              .add(Duration(microseconds: (i / sampleRate * 1e6).round()))
              .toIso8601String(),
        ),
      );
      await _analyze();
    } catch (e) {
      if (!disposed && token == generation) {
        _set(HrdPhase.error, 'Simulation failed: $e');
      }
    }
  }

  Future<void> _analyze() async {
    final token = generation;
    _set(HrdPhase.processing, 'Preparing feedback');
    try {
      // Reference uses the last epoch-minus-one seconds, excluding warm-up.
      final n = min(
        samples.length,
        (sampleRate * (config.epochSeconds - 1)).floor(),
      );
      final values = samples.sublist(samples.length - n);
      final result = await compute(hrdCompute, <String, Object>{
        'history': history,
        'samples': values,
        'sampleRate': sampleRate,
        'ecg': config.ecg,
        'ecgMethod': config.ecgMethod.name,
        if (catches[rows.length])
          'catchDelta': (random.nextInt(9) * 10 - 40).toDouble(),
      });
      if (disposed || token != generation) return;
      processingMethod = result['processingMethod'] as String;
      final stats = result['stats'] as List<double>;
      hr = stats[0];
      if (!hr.isFinite || hr <= 0) {
        _set(
          HrdPhase.error,
          'Heart rate not detected. Check the signal and retry this trial.',
        );
        return;
      }
      cleaned = result['cleaned'] as List<double>;
      peakMask = result['peaks'] as List<double>;
      delta = result['delta'] as double;
      presented = hrdPresentedRate(hr, delta);
      final seconds = max(5 * 60 / presented, 8.0);
      final snapshot = {
        'trial': trial,
        'source': lockedSource,
        'signal': config.ecg ? 'ECG' : 'PPG',
        'sampleRate': sampleRate,
        'timestamps': sampleTimes.sublist(sampleTimes.length - n),
        'raw': values,
        'cleaned': cleaned,
        'peaks': peakMask,
        'stats': stats,
        'rates': result['rates'],
        'processingMethod': processingMethod,
      };
      final snapshotPath = csvPath!.replaceFirst(
        '.csv',
        '_trial${trial.toString().padLeft(4, '0')}.json',
      );
      await File(
        snapshotPath,
      ).writeAsString(jsonEncode(_jsonSafe(snapshot)), flush: true);
      paths.add(snapshotPath);
      if (disposed || token != generation) return;
      if (config.audio) {
        final sound = await compute(hrdCompute, <String, Object>{
          'history': <List<double>>[],
          'bpm': presented,
          'seconds': seconds + 1,
        });
        if (disposed || token != generation) return;
        final file = File(
          '${Directory.systemTemp.path}/ccs_hrd_${startedAt.microsecondsSinceEpoch}.wav',
        );
        await file.writeAsBytes(sound['audio'] as Uint8List, flush: true);
        await player.setSource(DeviceFileSource(file.path));
        if (disposed || token != generation) return;
        await player.resume();
      }
      if (!config.audio) {
        await player.setReleaseMode(ReleaseMode.loop);
        await player.play(AssetSource('hrd/bell.wav'));
        await Future<void>.delayed(const Duration(seconds: 2));
        await player.stop();
        await player.setReleaseMode(ReleaseMode.stop);
      }
      if (disposed || token != generation) {
        await player.stop();
        return;
      }
      sessions.recordEvent('HRD feedback trial $trial', 710);
      reactionClock
        ..reset()
        ..start();
      _set(
        HrdPhase.response,
        'Is the feedback faster or slower than your heart?',
      );
      deadline = Timer(
        Duration(microseconds: (seconds * 1e6).round()),
        () => unawaited(answer(null)),
      );
    } catch (e) {
      if (!disposed && token == generation) {
        await player.stop();
        _set(HrdPhase.error, 'Unable to prepare trial: $e');
      }
    }
  }

  Future<void> answer(
    int? value, {
    int? combinedConfidence,
    double? position,
  }) async {
    if (value != null && value != 0 && value != 1) {
      throw ArgumentError('Invalid response');
    }
    if (combinedConfidence != null &&
        (combinedConfidence < 1 || combinedConfidence > 9)) {
      throw ArgumentError('Invalid slider confidence');
    }
    if (config.responseMode == HrdResponseMode.combinedSlider &&
        value != null) {
      final selected = HrdSliderAnswer(position ?? 0);
      if (selected.response != value ||
          selected.confidence != combinedConfidence) {
        throw ArgumentError('Slider response and confidence disagree');
      }
    }
    if (phase != HrdPhase.response) return;
    deadline?.cancel();
    reactionClock.stop();
    response = value;
    rating = value == null ? null : combinedConfidence;
    sliderPosition = value == null ? null : position;
    rt = value == null ? null : reactionClock.elapsedMicroseconds / 1e6;
    _set(HrdPhase.processing, 'Saving response');
    await player.stop();
    if (disposed || phase == HrdPhase.stopped) return;
    sessions.recordEvent(
      value == null ? 'HRD timeout' : 'HRD response $value',
      value == null ? 713 : 711 + value,
    );
    if (config.responseMode == HrdResponseMode.buttons &&
        config.confidence &&
        value != null) {
      _set(HrdPhase.rating, 'How confident are you? 0–9');
      deadline = Timer(
        const Duration(seconds: 15),
        () => unawaited(rate(null)),
      );
    } else {
      await _finishTrial();
    }
  }

  Future<void> rate(int? value) async {
    if (phase != HrdPhase.rating) return;
    deadline?.cancel();
    rating = value;
    _set(HrdPhase.processing, 'Saving confidence');
    await _finishTrial();
  }

  Future<void> _finishTrial() async {
    final token = generation;
    try {
      final updatedHistory = List<List<double>>.of(history);
      if (!catches[rows.length] && response != null) {
        updatedHistory.add([delta, response!.toDouble()]);
      }
      final result = await compute(hrdCompute, <String, Object>{
        'history': updatedHistory,
      });
      if (disposed || token != generation) return;
      history
        ..clear()
        ..addAll(updatedHistory);
      estimate = result['estimate'] as List<double>;
      rows.add({
        'SubjName': subject,
        'Trial': trial,
        'TrialType': catches[rows.length] ? 'catch' : 'psi',
        'StimType': config.ecg ? 'ecg' : 'ppg',
        'FeatureType': 'HRV_avgHR',
        'HeartRate': hr,
        'EstimatedRateMean': response == null ? null : estimate[0],
        'EstimatedRateLow': response == null ? null : estimate[1],
        'EstimatedRateHigh': response == null ? null : estimate[2],
        'ActualRate': hr,
        'PsiDeltaRate': delta,
        'PresentedRate': presented,
        'SubjResponse': response,
        'SubjRating': rating,
        'SubjAccuracy': response == null
            ? null
            : ((delta > 0 && response == 1) || (delta <= 0 && response == 0)
                  ? 1
                  : 0),
        'ResponseTime': rt,
        'PsiThreshold': estimate[0],
        'PsiSlope': estimate[3],
        'ResponseMode': config.responseMode.name,
        'SliderPosition': sliderPosition,
        'DeliveredDeltaRate': presented - hr,
        'CardiacProcessing': processingMethod,
      });
      pendingWrite = _write();
      await pendingWrite;
      if (disposed || token != generation) return;
      if (rows.length >= config.trials) {
        await export();
        if (disposed || token != generation) return;
        _set(HrdPhase.complete, 'Task complete. Data saved.');
      } else {
        _next();
      }
    } catch (e) {
      if (!disposed && token == generation) {
        saveFailed = true;
        _set(HrdPhase.error, 'Saving failed: $e');
      }
    }
  }

  Future<void> _write() async {
    if (csvPath == null) return;
    Object? safe(Object? v) => v is double && !v.isFinite ? null : v;
    String cell(Object? v) =>
        '"${(safe(v)?.toString() ?? '').replaceAll('"', '""')}"';
    final columns = [
      ...hrdColumns,
      'ResponseMode',
      'SliderPosition',
      'DeliveredDeltaRate',
      'CardiacProcessing',
    ];
    final csv = [
      columns,
      ...rows.map((r) => columns.map((c) => r[c]).toList()),
    ].map((row) => row.map(cell).join(',')).join('\n');
    await File(csvPath!).writeAsString(csv, flush: true);
    final path = csvPath!.replaceFirst('.csv', '.json');
    await File(path).writeAsString(
      jsonEncode(
        _jsonSafe({
          'config': config.toJson(),
          'subject': subject,
          'startedAt': startedAt.toIso8601String(),
          'source': lockedSource,
          'history': history,
          'catchPlan': catches,
          'estimate': estimate,
          'trials': rows,
          'complete': rows.length == config.trials,
        }),
      ),
      flush: true,
    );
    if (!paths.contains(path)) paths.add(path);
  }

  Future<void> export() {
    if (pendingExport != null) return pendingExport!;
    final future = _export();
    pendingExport = future;
    return future.whenComplete(() => pendingExport = null);
  }

  Future<void> _export() async {
    if (ownsRecording) {
      await sessions.stopSession();
      ownsRecording = false;
    }
    if (pendingWrite != null) await pendingWrite!;
    await _write();
    if (csvPath == null) return;
    final reports = await compute(writeHrdReportRequest, <String, Object>{
      'csvPath': csvPath!,
      'rows': rows,
      'snapshots': paths
          .where((p) => RegExp(r'_trial\d+\.json$').hasMatch(p))
          .toList(),
      'subject': subject,
    });
    for (final report in reports) {
      if (!paths.contains(report)) paths.add(report);
    }
    final stem = FileNamingService.stem(subject, ModuleType.hrd, startedAt);
    for (final path in List<String>.of(paths)) {
      await FileNamingService.exportToDownloads(
        path,
        subject: subject,
        sessionStem: stem,
      );
    }
    if (ownsRecording) {
      await sessions.stopSession();
      ownsRecording = false;
    }
  }

  Future<void> stop() async {
    if (phase == HrdPhase.complete) {
      _set(HrdPhase.stopped, 'Task complete. Data saved.');
      return;
    }
    generation++;
    deadline?.cancel();
    _set(HrdPhase.stopped, 'Stopped. Partial results saved.');
    await player.stop();
    if (activeAnalysis != null) await activeAnalysis!;
    await export();
  }

  @override
  void dispose() {
    progressTicker?.cancel();
    disposed = true;
    generation++;
    deadline?.cancel();
    for (final s in subscriptions) {
      unawaited(s.cancel());
    }
    if (ownsRecording) {
      unawaited(sessions.stopSession());
      ownsRecording = false;
    }
    unawaited(player.dispose());
    final file = File(
      '${Directory.systemTemp.path}/ccs_hrd_${startedAt.microsecondsSinceEpoch}.wav',
    );
    unawaited(() async {
      if (await file.exists()) {
        await file.delete();
      }
    }());
    super.dispose();
  }
}

Object? _jsonSafe(Object? v) {
  if (v is double && !v.isFinite) return null;
  if (v is Map) return v.map((k, v) => MapEntry(k, _jsonSafe(v)));
  if (v is List) return v.map(_jsonSafe).toList();
  return v;
}
