import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/eeg/acquisition_service.dart';
import '../../core/models/signal_stream_sample.dart';
import '../../core/services/multi_device_acquisition_service.dart';
import '../../core/services/multi_stream_lsl_service.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/services/settings_service.dart';
import '../../core/models/module_type.dart';
import 'hep_engine.dart';

class HepScreen extends StatefulWidget {
  const HepScreen({super.key});
  @override
  State<HepScreen> createState() => _HepScreenState();
}

class _HepScreenState extends State<HepScreen> {
  final Map<String, SignalStreamSample> sources = {};
  final List<StreamSubscription<SignalStreamSample>> subscriptions = [];
  String? source;
  int? eeg, ecg;
  HepEngine? engine;
  bool running = false;
  DateTime? started;
  Timer? timer;
  int seconds = 0;
  String? message;
  @override
  void initState() {
    super.initState();
    for (final stream in [
      context.read<AcquisitionService>().streamSamples,
      context.read<MultiDeviceAcquisitionService>().samples,
      context.read<MultiStreamLslService>().samples,
    ]) {
      subscriptions.add(stream.listen(receive));
    }
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (running) {
        seconds = DateTime.now().difference(started!).inSeconds;
        final last = sources[source];
        if (last == null ||
            DateTime.now().difference(last.timestamp).inSeconds > 3) {
          engine?.quality = 'Signal unavailable: reconnect the selected stream';
          engine?.bpm = 0;
        }
        if (seconds >= 300) stop();
      }
      setState(() {});
    });
  }

  void receive(SignalStreamSample s) {
    final key = '${s.deviceProfileId}/${s.streamId}';
    sources[key] = s;
    if (!running || source != key) return;
    if (s.sampleRate != engine!.sampleRate ||
        eeg! >= s.channels.length ||
        ecg! >= s.channels.length ||
        s.channelLabels.length <= max(eeg!, ecg!) ||
        s.channelLabels[eeg!] != labels.$1 ||
        s.channelLabels[ecg!] != labels.$2) {
      stop();
      message = 'Stream configuration changed. Select channels and restart.';
      return;
    }
    final unit = s.unit.toLowerCase().replaceAll('µ', 'u').replaceAll('μ', 'u');
    final factor = switch (unit) {
      'uv' => 1.0,
      'mv' => 1000.0,
      'v' => 1000000.0,
      _ => null,
    };
    if (factor == null) {
      stop();
      message = 'Unsupported voltage unit: ${s.unit}';
      return;
    }
    engine!.add(
      s.channels[eeg!] * factor,
      s.channels[ecg!] * factor,
      s.timestamp,
    );
  }

  (String, String) labels = ('', '');
  void start() {
    try {
      final s = sources[source];
      if (s == null || eeg == null || ecg == null || eeg == ecg) {
        throw StateError('Select distinct EEG and ECG channels.');
      }
      if (DateTime.now().difference(s.timestamp).inSeconds > 3) {
        throw StateError('The selected stream is stale. Reconnect it.');
      }
      engine = HepEngine(s.sampleRate);
      labels = (s.channelLabels[eeg!], s.channelLabels[ecg!]);
      setState(() {
        running = true;
        started = DateTime.now();
        seconds = 0;
        message = null;
      });
    } catch (e) {
      setState(() => message = '$e');
    }
  }

  void stop() {
    engine?.finish();
    running = false;
  }

  Future<void> export() async {
    try {
      final e = engine!;
      final file = File(
        await FileNamingService.jsonPath(
          context.read<SettingsService>().subjectCode,
          ModuleType.hep,
          started!,
        ),
      );
      await file.writeAsString(
        jsonEncode({
          'source': source,
          'eeg': labels.$1,
          'ecg': labels.$2,
          'sampleRate': e.sampleRate,
          'started': started!.toIso8601String(),
          'durationSeconds': seconds,
          'accepted': e.accepted,
          'rejected': e.rejected,
          'beats': e.beats,
          'gaps': e.gaps,
          'pseudoCount': e.pseudoCount,
          'quality': e.quality,
          'timeMs': List.generate(
            e.length,
            (i) => (i - e.pre) * 1000 / e.sampleRate,
          ),
          'meanUv': e.mean,
          'semUv': e.sem,
          'pseudoUv': e.pseudo,
          'correctedUv': e.corrected,
          'processing':
              'Causal 0.5–40 Hz EEG, 50 Hz notch; 1–45 Hz ECG; local absolute ECG peaks; -200/+800 ms epochs; linear detrend; -200/0 ms baseline; 1–150 uV rejection; midpoint pseudotrials',
          'limitations':
              'Live estimate; causal filter phase delay; no ICA, surrogate significance, or cardiac field artifact removal. SEM assumes independent epochs, although epochs may overlap.',
        }),
      );
      if (mounted) setState(() => message = 'Saved ${file.path}');
    } catch (e) {
      if (mounted) setState(() => message = 'Export failed: $e');
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    for (final s in subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = sources[source], e = engine;
    Widget channels(String title, int? value, void Function(int?) change) =>
        DropdownButtonFormField<int>(
          key: ValueKey('$source:$title'),
          initialValue: value,
          decoration: InputDecoration(labelText: title),
          items: [
            for (var i = 0; i < (s?.channelLabels.length ?? 0); i++)
              DropdownMenuItem(
                value: i,
                child: Text('${i + 1}: ${s!.channelLabels[i]}'),
              ),
          ],
          onChanged: running ? null : change,
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Heartbeat Evoked Potential')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '5-minute resting HEP • synchronized EEG + ECG',
            style: TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 12),
          const Text(
            'Connect a stream containing both channels. Choose one representative EEG channel and ECG. EEG uses the acquisition reference. Sit still during collection.',
          ),
          DropdownButtonFormField<String>(
            initialValue: source,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Source stream'),
            items: [
              for (final k in sources.keys)
                DropdownMenuItem(
                  value: k,
                  child: Text(k, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: running
                ? null
                : (v) => setState(() {
                    source = v;
                    eeg = ecg = null;
                    engine = null;
                  }),
          ),
          channels('EEG channel', eeg, (v) => setState(() => eeg = v)),
          channels('ECG channel', ecg, (v) => setState(() => ecg = v)),
          const SizedBox(height: 16),
          if (running) LinearProgressIndicator(value: min(seconds / 300, 1)),
          Text('$seconds / 300 seconds'),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                onPressed: running ? null : start,
                child: const Text('Start 5-minute session'),
              ),
              OutlinedButton(
                onPressed: running ? () => setState(stop) : null,
                child: const Text('Stop'),
              ),
              OutlinedButton(
                onPressed: !running && e != null ? export : null,
                child: const Text('Export results'),
              ),
            ],
          ),
          if (e != null) ...[
            const SizedBox(height: 20),
            Text(e.quality),
            Text(
              '${e.beats} R-peaks • ${e.accepted} accepted • ${e.rejected} rejected • ${e.gaps} gaps',
            ),
            Text(
              'Heart rate: ${e.bpm.toStringAsFixed(0)} BPM • 200–500 ms mean: ${e.windowAmplitude.toStringAsFixed(2)} µV',
            ),
            SizedBox(height: 240, child: CustomPaint(painter: _HepPlot(e))),
            const Text(
              '−200 ms                 R (0)                  +800 ms\nBlue: HEP ± SEM • orange: midpoint pseudotrials',
            ),
            Text(
              'Pseudotrial epochs: ${e.pseudoCount}. Live estimate; cardiac field artifacts can remain. Causal filters introduce phase delay. Five minutes does not guarantee a stable HEP.',
            ),
          ],
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(message!),
            ),
        ],
      ),
    );
  }
}

class _HepPlot extends CustomPainter {
  _HepPlot(this.e);
  final HepEngine e;
  @override
  void paint(Canvas canvas, Size size) {
    final sem = e.sem;
    final scale = max(
      1.0,
      List.generate(e.length, (i) => e.mean[i].abs() + sem[i]).reduce(max),
    );
    Offset point(int i, double value) => Offset(
      i * size.width / (e.length - 1),
      size.height / 2 - value / scale * size.height * .42,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      Paint()..color = Colors.grey,
    );
    final x = e.pre * size.width / (e.length - 1);
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()..color = Colors.grey,
    );
    final band = Path();
    for (var i = 0; i < e.length; i++) {
      final p = point(i, e.mean[i] + sem[i]);
      if (i == 0) {
        band.moveTo(p.dx, p.dy);
      } else {
        band.lineTo(p.dx, p.dy);
      }
    }
    for (var i = e.length - 1; i >= 0; i--) {
      final p = point(i, e.mean[i] - sem[i]);
      band.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      band..close(),
      Paint()..color = Colors.blue.withValues(alpha: .2),
    );
    for (final series in [(e.mean, Colors.blue), (e.pseudo, Colors.orange)]) {
      final path = Path();
      for (var i = 0; i < e.length; i++) {
        final p = point(i, series.$1[i]);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = series.$2
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    final text = TextPainter(
      text: TextSpan(
        text: '±${scale.toStringAsFixed(1)} µV',
        style: const TextStyle(color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, const Offset(4, 4));
  }

  @override
  bool shouldRepaint(covariant _HepPlot oldDelegate) => true;
}
