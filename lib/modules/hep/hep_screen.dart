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
import 'orbit_hep_session.dart';
import '../../core/models/device_profile.dart';
import '../../core/models/eeg_sample.dart';

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
  bool orbitMode = false;
  OrbitHepSession? orbit;
  StreamSubscription<EegSample>? orbitSubscription;
  HepEngine? engine;
  bool running = false;
  DateTime? started;
  Timer? timer;
  int seconds = 0;
  String? message;
  @override
  void initState() {
    super.initState();
    orbitMode =
        context.read<AcquisitionService>().connectedDeviceKind ==
        DeviceKind.orbit;
    for (final stream in [
      context.read<AcquisitionService>().streamSamples,
      context.read<MultiDeviceAcquisitionService>().samples,
      context.read<MultiStreamLslService>().samples,
    ]) {
      subscriptions.add(stream.listen(receive));
    }
    final acq = context.read<AcquisitionService>();
    orbitSubscription = acq.samples.listen((s) {
      if (!mounted || !running || !orbitMode) return;
      if (acq.connectedDeviceKind != DeviceKind.orbit ||
          acq.connectedDeviceProfile?.id != orbit?.deviceProfileId) {
        stop();
        message = 'Orbit device changed. Restart the session.';
        return;
      }
      orbit?.addEeg(s);
      if (orbit?.error != null) {
        stop();
        message = orbit!.error;
      }
    });
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (running) {
        seconds = DateTime.now().difference(started!).inSeconds;
        final last = sources[source];
        if (!orbitMode &&
            (last == null ||
                DateTime.now().difference(last.timestamp).inSeconds > 3)) {
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
    if (running && orbitMode) {
      orbit?.addPpg(s);
      if (orbit?.error != null) {
        stop();
        message = orbit!.error;
      }
      return;
    }
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
      if (orbitMode) {
        final acq = context.read<AcquisitionService>();
        final profile = acq.connectedDeviceProfile;
        if (acq.connectedDeviceKind != DeviceKind.orbit ||
            !acq.isStreamReady ||
            profile == null) {
          throw StateError('Connect and stream Orbit before starting.');
        }
        final ppg = profile.enabledStreams
            .where((s) => s.signalType == SignalType.ppg)
            .firstOrNull;
        if (ppg == null) {
          throw StateError('Enable the Orbit PPG stream in Settings.');
        }
        orbit = OrbitHepSession(
          deviceProfileId: profile.id,
          ppgStreamId: ppg.id,
        );
        engine = null;
        setState(() {
          running = true;
          started = DateTime.now();
          seconds = 0;
          message = null;
        });
        return;
      }
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
    orbit?.finish();
    running = false;
  }

  Future<void> export() async {
    try {
      if (orbitMode) {
        final o = orbit!;
        final file = File(
          await FileNamingService.jsonPath(
            context.read<SettingsService>().subjectCode,
            ModuleType.hep,
            started!,
          ),
        );
        await file.writeAsString(
          jsonEncode({
            'mode': 'orbit_ppg',
            'eventReference': 'native PPG pulse peak',
            'deviceProfileId': o.deviceProfileId,
            'ppgStreamId': o.ppgStreamId,
            'eegSampleRate': 250,
            'ppgSampleRate': 62.5,
            'started': started!.toIso8601String(),
            'durationSeconds': seconds,
            'pulseCount': o.pulseCount,
            'pulseTimestamps': o.pulseTimes
                .map((t) => t.toIso8601String())
                .toList(),
            'quality': o.quality(DateTime.now()),
            'channels': [
              for (var i = 0; i < 2; i++)
                {
                  'label': i == 0 ? 'AF7' : 'AF8',
                  'accepted': o.channels[i].accepted,
                  'rejected': o.channels[i].rejected,
                  'gaps': o.channels[i].gaps,
                  'pseudoCount': o.channels[i].pseudoCount,
                  'meanUv': o.channels[i].mean,
                  'semUv': o.channels[i].sem,
                  'pseudoUv': o.channels[i].pseudo,
                  'correctedUv': o.channels[i].corrected,
                },
            ],
            'timeMs': List.generate(
              o.channels.first.length,
              (i) => (i - o.channels.first.pre) * 4,
            ),
            'processing':
                'Native 62.5 Hz PPG; causal 0.5–8 Hz pulse detector, positive local peaks, 450 ms refractory. AF7/AF8 processed independently: 0.5–40 Hz, 50 Hz notch, detrend, -200/0 ms baseline, -200/+800 ms epochs, artifact rejection, midpoint controls.',
            'limitations':
                'PPG pulse-locked estimate, no ECG R-peak timing or pulse transit correction. Device clocks are reconstructed; native PPG resolution is 16 ms. Causal filter delay, pulse transit variability and cardiac field artifacts remain; no ICA or surrogate significance. Overlapping epochs limit SEM interpretation.',
          }),
        );
        if (mounted) setState(() => message = 'Saved ${file.path}');
        return;
      }
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
    orbitSubscription?.cancel();
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
            '5-minute resting HEP • EEG + cardiac events',
            style: TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('EEG + ECG')),
              ButtonSegment(value: true, label: Text('Orbit EEG + PPG')),
            ],
            selected: {orbitMode},
            onSelectionChanged: running
                ? null
                : (v) => setState(() {
                    orbitMode = v.first;
                    engine = null;
                    orbit = null;
                    message = null;
                  }),
          ),
          if (orbitMode) ...[
            const SizedBox(height: 12),
            const Text(
              'Orbit: AF7 and AF8 analyzed separately, using native PPG pulse peaks as cardiac events. Connect Orbit and enable its PPG stream in Settings.',
            ),
            const Text(
              'PPG timing includes pulse transit and filter delay. Results are pulse-locked; no ECG R-peak timing correction is applied.',
            ),
          ],
          if (!orbitMode) ...[
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
          ],
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
                onPressed: !running && (e != null || orbit != null)
                    ? export
                    : null,
                child: const Text('Export results'),
              ),
            ],
          ),
          if (orbitMode && orbit != null) ...[
            const SizedBox(height: 20),
            Text(orbit!.quality(DateTime.now())),
            Text('${orbit!.pulseCount} native PPG pulse peaks'),
            for (var i = 0; i < 2; i++) ...[
              Text(
                '${i == 0 ? "AF7" : "AF8"} • ${orbit!.channels[i].accepted} accepted • ${orbit!.channels[i].rejected} rejected • ${orbit!.channels[i].gaps} gaps',
              ),
              Text(
                '200–500 ms pulse-locked mean: ${orbit!.channels[i].windowAmplitude.toStringAsFixed(2)} µV',
              ),
              SizedBox(
                height: 200,
                child: CustomPaint(painter: _HepPlot(orbit!.channels[i])),
              ),
              const Text(
                '−200 ms              PPG pulse (0)              +800 ms\nBlue: mean ± SEM • orange: midpoint pseudotrials',
              ),
            ],
          ],
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
