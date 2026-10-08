import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/eeg/acquisition_service.dart';
import '../../core/models/module_type.dart';
import '../../core/services/multi_device_acquisition_service.dart';
import '../../core/services/multi_stream_lsl_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/settings_service.dart';
import '../../core/widgets/connection_status_bar.dart';
import 'hrd_engine.dart';
import 'hrd_models.dart';

class HrdScreen extends StatefulWidget {
  const HrdScreen({super.key});
  @override
  State<HrdScreen> createState() => _HrdScreenState();
}

class _HrdScreenState extends State<HrdScreen> {
  final trials = TextEditingController(text: '10'),
      catches = TextEditingController(text: '2'),
      seconds = TextEditingController(text: '16'),
      channel = TextEditingController(text: 'PPG'),
      source = TextEditingController();
  bool ecg = false,
      audio = true,
      record = true,
      confidence = false,
      simulation = false;
  bool loaded = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (loaded) return;
    loaded = true;
    final saved = context.read<SettingsService>().hrdSettings;
    trials.text = '${saved["trials"] ?? 10}';
    catches.text = '${saved["catchTrials"] ?? 2}';
    seconds.text = '${saved["epochSeconds"] ?? 16}';
    channel.text = saved["channel"] as String? ?? "PPG";
    source.text = saved["source"] as String? ?? "";
    ecg = saved["ecg"] as bool? ?? false;
    audio = saved["audio"] as bool? ?? true;
    record = saved["record"] as bool? ?? true;
    confidence = saved["confidence"] as bool? ?? false;
  }

  String? error;
  @override
  void dispose() {
    for (final c in [trials, catches, seconds, channel, source]) {
      c.dispose();
    }
    super.dispose();
  }

  void start() {
    try {
      final config = HrdConfig(
        trials: int.parse(trials.text),
        catchTrials: int.parse(catches.text),
        epochSeconds: int.parse(seconds.text),
        ecg: ecg,
        channel: channel.text.trim(),
        source: source.text.trim(),
        audio: audio,
        record: record,
        confidence: confidence,
        simulation: simulation,
      );
      config.validate();
      context.read<SettingsService>().update(
        (s) => s.hrdSettings = config.toJson(),
      );
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => HrdExperimentScreen(
            config: config,
            subject: context.read<SettingsService>().subjectCode,
          ),
        ),
      );
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  Widget field(
    String label,
    TextEditingController controller, {
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextField(
      controller: controller,
      keyboardType: numeric ? TextInputType.number : null,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Heart Rate Detection • Bayesian Psi')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        ConnectionStatusBar(
          eegState: context.watch<AcquisitionService>().currentState,
        ),
        const SizedBox(height: 16),
        const Text(
          'Compare your heartbeat with auditory or visual rate feedback. Each trial collects a fresh cardiac epoch, then asks whether the feedback is faster or slower.',
          style: TextStyle(fontSize: 18),
        ),
        field('Trials', trials, numeric: true),
        field('Catch trials', catches, numeric: true),
        field('Acquisition per trial (seconds)', seconds, numeric: true),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Orbit PPG')),
            ButtonSegment(value: true, label: Text('xAMP-L10 ECG')),
          ],
          selected: {ecg},
          onSelectionChanged: (s) => setState(() {
            ecg = s.first;
            channel.text = ecg ? 'ECG' : 'PPG';
          }),
        ),
        field('Exact cardiac channel label', channel),
        field('Optional source ID: deviceProfileId/streamId', source),
        const Text(
          'Configure the ECG channel type in Settings. Connect the device before starting. A session stays on its selected source; signal gaps restart collection.',
        ),
        SwitchListTile(
          title: const Text('Auditory feedback'),
          subtitle: const Text('Turn off for a visual rate bar'),
          value: audio,
          onChanged: (v) => setState(() => audio = v),
        ),
        SwitchListTile(
          title: const Text('Record physiological streams to EDF'),
          value: record,
          onChanged: (v) => setState(() => record = v),
        ),
        SwitchListTile(
          title: const Text('Simulation / demonstration'),
          subtitle: const Text('Synthetic 72 BPM input; no hardware recording'),
          value: simulation,
          onChanged: (v) => setState(() => simulation = v),
        ),
        SwitchListTile(
          title: const Text('Collect confidence (0–9)'),
          subtitle: const Text(
            'Optional extension; disabled to match the source UI runner',
          ),
          value: confidence,
          onChanged: (v) => setState(() => confidence = v),
        ),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        FilledButton.icon(
          onPressed: start,
          icon: const Icon(Icons.favorite_border),
          label: const Text('Start heart rate detection'),
        ),
      ],
    ),
  );
}

class HrdExperimentScreen extends StatefulWidget {
  const HrdExperimentScreen({
    super.key,
    required this.config,
    required this.subject,
  });
  final HrdConfig config;
  final String subject;
  @override
  State<HrdExperimentScreen> createState() => _HrdExperimentScreenState();
}

class _HrdExperimentScreenState extends State<HrdExperimentScreen> {
  late final HrdEngine engine;
  bool leaving = false;
  @override
  void initState() {
    super.initState();
    engine = HrdEngine(
      config: widget.config,
      subject: widget.subject,
      sessions: context.read<SessionManager>(),
      streams: [
        context.read<AcquisitionService>().streamSamples,
        context.read<MultiDeviceAcquisitionService>().samples,
        context.read<MultiStreamLslService>().samples,
      ],
    )..addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> begin() async {
    final sessions = context.read<SessionManager>();
    final acq = context.read<AcquisitionService>();
    try {
      if (widget.config.record && !widget.config.simulation) {
        if (sessions.isRecording) {
          throw StateError('Finish the active recording before starting HRD.');
        }
        if (!sessions.isStreaming) {
          throw StateError('Connect and stream a device before recording.');
        }
        await sessions.startSession(
          subject: widget.subject,
          module: ModuleType.hrd,
          channelCount: acq.channelCount,
          sampleRate: acq.sampleRate.round(),
          channelLabels: acq.recordingChannelLabels(null),
          enabledChannels: acq.recordingEnabledChannels(null),
        );
        engine.ownsRecording = sessions.activeModule == ModuleType.hrd;
      }
      await engine.start();
    } catch (e) {
      if (engine.ownsRecording) {
        await sessions.stopSession();
        engine.ownsRecording = false;
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> leave() async {
    if (leaving) return;
    leaving = true;
    try {
      await engine.stop();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      leaving = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e. Retry Stop.')),
        );
      }
    }
  }

  @override
  void dispose() {
    engine.removeListener(changed);
    engine.dispose();
    focus.dispose();
    super.dispose();
  }

  void key(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      unawaited(leave());
      return;
    }
    if (engine.phase == HrdPhase.response) {
      if (k == LogicalKeyboardKey.digit1 || k == LogicalKeyboardKey.arrowLeft) {
        unawaited(engine.answer(1));
      }
      if (k == LogicalKeyboardKey.digit0 ||
          k == LogicalKeyboardKey.arrowRight) {
        unawaited(engine.answer(0));
      }
    } else if (engine.phase == HrdPhase.rating) {
      final digit = int.tryParse(k.keyLabel);
      if (digit != null && digit <= 9) unawaited(engine.rate(digit));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = engine.phase;
    return PopScope(
      canPop: leaving,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(leave());
      },
      child: KeyboardListener(
        focusNode: focus,
        autofocus: true,
        onKeyEvent: key,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              '${widget.config.simulation ? 'DEMO ' : ''}HRD • ${min(engine.trial, widget.config.trials)}/${widget.config.trials}',
            ),
            leading: IconButton(
              onPressed: leave,
              icon: const Icon(Icons.close),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                engine.message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: p == HrdPhase.fixation ? 80 : 26),
              ),
              const SizedBox(height: 24),
              if (p == HrdPhase.ready)
                FilledButton(onPressed: begin, child: const Text('Begin')),
              if (p == HrdPhase.collecting)
                LinearProgressIndicator(value: engine.progress),
              if (p == HrdPhase.response) ...[
                if (!widget.config.audio)
                  SizedBox(
                    height: 200,
                    child: CustomPaint(
                      painter: HrdRatePainter(engine.presented),
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () => engine.answer(1),
                        child: const Text('Faster (1 / ←)'),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: FilledButton(
                        onPressed: () => engine.answer(0),
                        child: const Text('Slower (0 / →)'),
                      ),
                    ),
                  ],
                ),
              ],
              if (p == HrdPhase.rating)
                Wrap(
                  spacing: 8,
                  children: List.generate(
                    10,
                    (i) => FilledButton(
                      onPressed: () => engine.rate(i),
                      child: Text('$i'),
                    ),
                  ),
                ),
              if (p == HrdPhase.error)
                FilledButton(
                  onPressed: engine.retry,
                  child: const Text('Retry trial'),
                ),
              if (p == HrdPhase.complete || p == HrdPhase.stopped) ...[
                if (engine.estimate[0].isFinite)
                  Text(
                    'Bias: ${engine.estimate[0].toStringAsFixed(1)} BPM   Slope: ${engine.estimate[3].toStringAsFixed(2)}',
                  ),
                SizedBox(
                  height: 240,
                  child: CustomPaint(painter: HrdSummaryPainter(engine.rows)),
                ),
                const SizedBox(height: 16),
                SelectableText(engine.paths.join('\n')),
              ],
              if (p != HrdPhase.ready &&
                  p != HrdPhase.complete &&
                  p != HrdPhase.stopped)
                TextButton(
                  onPressed: leave,
                  child: const Text('Stop and save partial session'),
                ),
              if (engine.cleaned.isNotEmpty &&
                  p != HrdPhase.response &&
                  p != HrdPhase.rating) ...[
                const Text(
                  'Last trial: cleaned cardiac signal and detected peaks',
                ),
                SizedBox(
                  height: 160,
                  child: CustomPaint(
                    painter: HrdSignalPainter(engine.cleaned, engine.peakMask),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  final focus = FocusNode();
}

class HrdRatePainter extends CustomPainter {
  HrdRatePainter(this.bpm);
  final double bpm;
  @override
  void paint(Canvas c, Size s) {
    final paint = Paint()..color = Colors.blue;
    final h = s.height * bpm / 200;
    c.drawRect(Rect.fromLTWH(s.width / 2 - 35, s.height - h, 70, h), paint);
    final t = TextPainter(
      text: TextSpan(
        text: bpm.toStringAsFixed(1),
        style: const TextStyle(color: Colors.white, fontSize: 24),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    t.paint(c, Offset(s.width / 2 - t.width / 2, max(0, s.height - h - 30)));
  }

  @override
  bool shouldRepaint(HrdRatePainter old) => bpm != old.bpm;
}

class HrdSignalPainter extends CustomPainter {
  HrdSignalPainter(this.values, this.peaks);
  final List<double> values, peaks;
  @override
  void paint(Canvas c, Size s) {
    if (values.isEmpty) return;
    final lo = values.reduce(min), hi = values.reduce(max);
    final range = max(1e-9, hi - lo);
    final p = Path();
    for (var i = 0; i < values.length; i++) {
      final x = s.width * i / max(1, values.length - 1),
          y = s.height * (1 - (values[i] - lo) / range);
      if (i == 0) {
        p.moveTo(x, y);
      } else {
        p.lineTo(x, y);
      }
      if (peaks[i] > 0) {
        c.drawCircle(Offset(x, y), 3, Paint()..color = Colors.red);
      }
    }
    c.drawPath(
      p,
      Paint()
        ..color = Colors.tealAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(HrdSignalPainter old) => values != old.values;
}

class HrdSummaryPainter extends CustomPainter {
  HrdSummaryPainter(this.rows);
  final List<Map<String, Object?>> rows;
  @override
  void paint(Canvas c, Size s) {
    if (rows.isEmpty) return;
    final estimatePath = Path();
    bool begun = false;
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i], x = 20 + (s.width - 40) * (i + 0.5) / rows.length;
      double y(double v) => s.height / 2 - v * s.height / 120;
      final d = r['PsiDeltaRate'] as double;
      final response = r['SubjResponse'];
      c.drawCircle(
        Offset(x, y(d)),
        4,
        Paint()
          ..color = (r['TrialType'] == 'catch'
              ? Colors.grey
              : response == 1
              ? Colors.redAccent
              : Colors.blueAccent),
      );
      final a = r['EstimatedRateMean'];
      if (a is double && a.isFinite) {
        final low = r['EstimatedRateLow'] as double,
            high = r['EstimatedRateHigh'] as double;
        c.drawLine(
          Offset(x, y(low)),
          Offset(x, y(high)),
          Paint()
            ..color = Colors.teal
            ..strokeWidth = 3,
        );
        if (!begun) {
          estimatePath.moveTo(x, y(a));
          begun = true;
        } else {
          estimatePath.lineTo(x, y(a));
        }
      }
    }
    c.drawLine(
      Offset(0, s.height / 2),
      Offset(s.width, s.height / 2),
      Paint()..color = Colors.white24,
    );
    c.drawPath(
      estimatePath,
      Paint()
        ..color = Colors.tealAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final t = TextPainter(
      text: const TextSpan(
        text:
            'Delta BPM • red faster / blue slower / grey catch • teal bias ± SD/2',
        style: TextStyle(color: Colors.white, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: s.width);
    t.paint(c, Offset.zero);
  }

  @override
  bool shouldRepaint(HrdSummaryPainter old) => true;
}
