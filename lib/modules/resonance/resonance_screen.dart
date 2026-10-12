import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/eeg/acquisition_service.dart';
import '../../core/models/module_type.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/multi_device_acquisition_service.dart';
import 'resonance_analysis.dart';
import 'resonance_engine.dart';
import 'resonance_method_widgets.dart';

class ResonanceScreen extends StatefulWidget {
  const ResonanceScreen({super.key});
  @override
  State<ResonanceScreen> createState() => _ResonanceScreenState();
}

class _ResonanceScreenState extends State<ResonanceScreen>
    with WidgetsBindingObserver {
  final channel = TextEditingController(text: 'PPG');
  ResonanceMethod method = ResonanceMethod.conventional;
  bool ecg = false, loaded = false, saving = false;
  final fields = <String, TextEditingController>{};
  bool canLeave = false, saveAgain = false;
  String? exportPath, error;
  ResonanceEngine? engine;
  String subject = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (loaded) return;
    loaded = true;
    final saved = context.read<SettingsService>().resonanceSettings;
    ecg = saved['ecg'] == true;
    final defaults = const ResonanceConfig().toJson();
    for (final parameters in resonanceParameterGroups.values) {
      for (final p in parameters) {
        fields[p.key] = TextEditingController(
          text: '${saved[p.key] ?? defaults[p.key]}',
        );
      }
    }
    method = saved['method'] == 'adaptive'
        ? ResonanceMethod.adaptive
        : ResonanceMethod.conventional;
    channel.text = saved['channel'] as String? ?? (ecg ? 'ECG' : 'PPG');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && engine?.active == true) {
      engine!.stop();
      unawaited(save());
    }
  }

  void start() {
    if (channel.text.trim().isEmpty) {
      setState(() => error = 'Choose the cardiac channel label.');
      return;
    }
    final settings = context.read<SettingsService>();
    subject = settings.subjectCode;
    late final ResonanceConfig config;
    try {
      config = readConfig();
      config.validate();
    } catch (ex) {
      setState(() => error = '$ex');
      return;
    }
    settings.update((s) => s.resonanceSettings = config.toJson());
    engine = ResonanceEngine(
      config,
      context.read<AcquisitionService>().streamSamples,
      additionalStreams: [
        context.read<MultiDeviceAcquisitionService>().samples,
      ],
    )..addListener(refresh);
    engine!.start();
    setState(() => error = null);
  }

  ResonanceConfig readConfig() {
    final values = <String, dynamic>{
      'method': method.name,
      'ecg': ecg,
      'channel': channel.text.trim(),
    };
    for (final parameters in resonanceParameterGroups.values) {
      for (final p in parameters) {
        final text = fields[p.key]!.text.trim();
        final num? value = p.integer
            ? int.tryParse(text)
            : double.tryParse(text);
        if (value == null || !value.isFinite) {
          throw FormatException('Enter a valid value for ${p.label}.');
        }
        values[p.key] = value;
      }
    }
    return ResonanceConfig.fromJson(values);
  }

  ResonanceConfig? get draft {
    try {
      final c = readConfig();
      c.validate();
      return c;
    } catch (_) {
      return null;
    }
  }

  void resetParameters() {
    final defaults = const ResonanceConfig().toJson();
    for (final entry in fields.entries) {
      entry.value.text = '${defaults[entry.key]}';
    }
    setState(() => error = null);
  }

  String estimate(ResonanceConfig? c) {
    if (c == null) {
      return 'Complete the parameters below with valid values before starting.';
    }
    final epoch = c.settleSeconds + c.measureSeconds;
    final n = c.method == ResonanceMethod.conventional
        ? c.sweepRates.length
        : c.minTrials;
    final minutes = (n * epoch + (n - 1) * c.restSeconds) / 60;
    final maxMinutes =
        (c.maxTrials * epoch + (c.maxTrials - 1) * c.restSeconds) / 60;
    final timing = c.method == ResonanceMethod.conventional
        ? minutes.toStringAsFixed(1)
        : '${minutes.toStringAsFixed(1)}–${maxMinutes.toStringAsFixed(1)}';
    return '${c.method == ResonanceMethod.conventional ? "Conventional sweep" : "Experimental Bayesian assessment"}: ${c.minRate}–${c.maxRate} breaths/min; ${c.settleSeconds}s settling + ${c.measureSeconds}s measurement per rate. About $timing minutes, plus confirmation, feedback and retries.';
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> save() async {
    final e = engine;
    if (e == null) return;
    if (saving) {
      saveAgain = true;
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    // Snapshot before async filesystem access; practice can continue afterward.
    final summary = e.toJson();
    final beats = e.intervalLog.toList(), samples = e.rawSamples.toList();
    try {
      final path = await FileNamingService.jsonPath(
        subject,
        ModuleType.resonance,
        e.startedAt!,
      );
      await File(path).writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'subject': subject, ...summary}),
      );
      final stem = path.substring(0, path.lastIndexOf('.'));
      await File('${stem}_intervals.csv').writeAsString(
        [
          'at,interval_ms,accepted,phase,rate',
          for (final b in beats)
            '${b['at']},${b['intervalMs']},${b['accepted']},${b['phase']},${b['rate']}',
        ].join('\n'),
      );
      await File('${stem}_cardiac.csv').writeAsString(
        [
          'timestamp,value,sample_rate,source',
          for (final s in samples)
            '${s['at']},${s['value']},${s['sampleRate']},${s['source']}',
        ].join('\n'),
      );
      if (mounted) setState(() => exportPath = path);
    } catch (ex) {
      if (mounted) {
        setState(() => error = 'Export failed: $ex. Retry Save session.');
      }
    } finally {
      if (mounted) {
        setState(() => saving = false);
        if (saveAgain) {
          saveAgain = false;
          unawaited(save());
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    engine?.removeListener(refresh);
    engine?.dispose();
    channel.dispose();
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Widget card(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ...children.map(
            (w) =>
                Padding(padding: const EdgeInsets.only(bottom: 12), child: w),
          ),
        ],
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final e = engine;
    final preview = e?.config ?? draft;
    return PopScope(
      canPop: e == null || canLeave,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || saving || e == null) return;
        e.stop();
        await save();
        if (!mounted || error != null) return;
        setState(() => canLeave = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Individual Resonance Breathing')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (e == null) ...[
                    card('Find your comfortable rhythm', [
                      const Text(
                        'A guided adult assessment of the breathing pace that produces the strongest regular cardiac oscillation. Then confirm and practise at your candidate pace.',
                      ),
                      SegmentedButton<ResonanceMethod>(
                        segments: const [
                          ButtonSegment(
                            value: ResonanceMethod.conventional,
                            label: Text('Quick sweep'),
                          ),
                          ButtonSegment(
                            value: ResonanceMethod.adaptive,
                            label: Text('Adaptive Ψ'),
                          ),
                        ],
                        selected: {method},
                        onSelectionChanged: (v) =>
                            setState(() => method = v.first),
                      ),
                      Text(estimate(preview)),
                    ]),
                    card('Assessment parameters', [
                      const Text(
                        'Researcher controls. Edit before starting; settings remain fixed during acquisition and are included in exports.',
                      ),
                      ResonanceParameterEditor(
                        fields: fields,
                        onChanged: () => setState(() {}),
                        onReset: resetParameters,
                      ),
                    ]),
                    card('Cardiac sensor', [
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            label: Text('Orbit · PPG'),
                          ),
                          ButtonSegment(
                            value: true,
                            label: Text('xAMP-L10 · ECG'),
                          ),
                        ],
                        selected: {ecg},
                        onSelectionChanged: (v) => setState(() {
                          ecg = v.first;
                          channel.text = ecg ? 'ECG' : 'PPG';
                        }),
                      ),
                      TextField(
                        key: const ValueKey('resonance-channel'),
                        controller: channel,
                        decoration: const InputDecoration(
                          labelText: 'Cardiac channel label',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const Text(
                        'Connect hardware from Home. For xAMP-L10, assign the ECG electrode channel label and type in Settings. The assessment locks to one matching device stream.',
                      ),
                    ]),
                    card('Before you begin', [
                      const Text(
                        'Sit comfortably and keep still. Breathe gently, without holds or extra-deep breaths. Stop if you feel dizzy, breathless or uncomfortable.',
                      ),
                      const Text(
                        'PPG measures pulse-rate variability; ECG measures RR variability. No respiration sensor is used: following the pacer and respiration–heart alignment are not verified. Results are provisional research estimates.',
                      ),
                      FilledButton.icon(
                        onPressed: start,
                        icon: const Icon(Icons.air),
                        label: const Text('Start assessment'),
                      ),
                    ]),
                  ] else ...[
                    card(_phaseTitle(e), [
                      Text(e.message),
                      if ([
                        ResonancePhase.settling,
                        ResonancePhase.measuring,
                        ResonancePhase.practice,
                      ].contains(e.phase)) ...[
                        _BreathPacer(
                          phase: e.breathPhase,
                          rate: e.rate,
                          inhaleFraction: e.config.inhaleFraction,
                        ),
                        Center(
                          child: Text(
                            '${e.remaining ~/ 60}:${(e.remaining % 60).toString().padLeft(2, '0')} remaining',
                          ),
                        ),
                        LinearProgressIndicator(
                          value:
                              1 -
                              e.remaining /
                                  (e.phase == ResonancePhase.settling
                                      ? e.config.settleSeconds
                                      : e.phase == ResonancePhase.practice
                                      ? e.config.practiceSeconds
                                      : e.config.measureSeconds),
                        ),
                      ],
                      if (e.phase == ResonancePhase.waiting)
                        const Text(
                          'Waiting for eight clean heartbeat intervals. Keep still. Check that the selected device and channel are streaming.',
                        ),
                      if (e.phase == ResonancePhase.resting)
                        Text(
                          'Breathe naturally • ${e.remaining}s rest • next ${e.rate.toStringAsFixed(1)} breaths/min',
                        ),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          Chip(
                            label: Text(
                              e.fresh ? 'Signal arriving' : 'No fresh signal',
                            ),
                          ),
                          Chip(
                            label: Text(
                              e.fresh && e.heartRate > 0
                                  ? '${e.heartRate.toStringAsFixed(0)} heartbeats/min'
                                  : 'Heart rate —',
                            ),
                          ),
                          Chip(
                            label: Text('${e.acceptedTrials} accepted epochs'),
                          ),
                        ],
                      ),
                      if (e.intervalLog.isNotEmpty) ...[
                        const Text(
                          'Live beat intervals (ms) · larger regular waves indicate stronger cardiac oscillation',
                        ),
                        SizedBox(
                          height: 110,
                          child: CustomPaint(
                            painter: _IntervalPlot(e.intervalLog),
                          ),
                        ),
                      ],
                      if (e.source != null)
                        Text('Source: ${e.source} · ${e.config.channel}'),
                      if (e.phase == ResonancePhase.review) ...[
                        if (e.pending != null && e.pending!.metrics.valid) ...[
                          const Text(
                            'Was this pace comfortable and were you able to follow the circle?',
                          ),
                          FilledButton(
                            onPressed: () => e.review(true),
                            child: const Text('Comfortable · accept epoch'),
                          ),
                          OutlinedButton(
                            onPressed: () => e.review(false),
                            child: const Text('Uncomfortable · discard epoch'),
                          ),
                        ],
                        OutlinedButton(
                          onPressed: e.retry,
                          child: const Text('Rest and retry this rate'),
                        ),
                      ],
                      if (e.active)
                        OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () {
                                  e.stop();
                                  unawaited(save());
                                },
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('Stop & save'),
                        ),
                    ]),
                    if (e.recommendedRate != null)
                      card('Your candidate pace', [
                        Text(
                          '${e.recommendedRate!.toStringAsFixed(1)} breaths/min',
                          style: Theme.of(context).textTheme.headlineLarge,
                        ),
                        Text(
                          '${(60 * e.config.inhaleFraction / e.recommendedRate!).toStringAsFixed(1)}s inhale · ${(60 * (1 - e.config.inhaleFraction) / e.recommendedRate!).toStringAsFixed(1)}s exhale · no holds',
                        ),
                        Text(
                          e.confirmed
                              ? 'Confirmation passed: repeatable cardiac response.'
                              : 'Provisional: confirmation required.',
                        ),
                        if (e.config.method == ResonanceMethod.adaptive)
                          Text(
                            'Model-based 95% credible interval: ${e.posterior.interval95.$1.toStringAsFixed(1)}–${e.posterior.interval95.$2.toStringAsFixed(1)} breaths/min. Experimental; independent validation pending.',
                          ),
                        if (e.recommendedRate! <=
                                e.config.minRate + e.config.adaptiveStep ||
                            e.recommendedRate! >=
                                e.config.maxRate - e.config.adaptiveStep)
                          const Text(
                            'Candidate is near the search boundary. The true optimum may lie outside the tested range; researcher review recommended.',
                          ),
                        if (e.phase == ResonancePhase.results && !e.confirmed)
                          FilledButton(
                            onPressed: e.confirm,
                            child: const Text('Rest, then confirm candidate'),
                          ),
                        if (e.phase == ResonancePhase.results && e.confirmed)
                          FilledButton.icon(
                            onPressed: e.practice,
                            icon: const Icon(Icons.air),
                            label: Text(
                              'Practise for ${(e.config.practiceSeconds / 60).toStringAsFixed(1)} minutes',
                            ),
                          ),
                      ]),
                    if (e.epochs.isNotEmpty)
                      card('Response by breathing pace', [
                        SizedBox(
                          height: 180,
                          child: CustomPaint(
                            painter: _ResponsePlot(
                              e.epochs,
                              e.posterior,
                              e.config.method,
                            ),
                          ),
                        ),
                        const Text(
                          'Bars: fitted interval oscillation amplitude (ms). Cyan: accepted; grey: discarded. Adaptive line: posterior probability of the best rate.',
                        ),
                        ...e.epochs.map(
                          (epoch) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              epoch.used
                                  ? Icons.check_circle
                                  : Icons.info_outline,
                            ),
                            title: Text(
                              '${epoch.metrics.rate.toStringAsFixed(1)} breaths/min${epoch.confirmation ? " · confirmation" : ""}',
                            ),
                            subtitle: Text(
                              '${epoch.metrics.amplitudeMs.toStringAsFixed(1)} ms amplitude · fit ${(100 * epoch.metrics.fitR2).toStringAsFixed(0)}% · coverage ${(100 * epoch.metrics.coverage).toStringAsFixed(0)}%\n${epoch.metrics.reason ?? (epoch.used ? "Accepted" : "Awaiting feedback or discarded")}',
                            ),
                          ),
                        ),
                      ]),
                    FilledButton.tonalIcon(
                      onPressed: saving ? null : save,
                      icon: const Icon(Icons.save_alt),
                      label: Text(saving ? 'Saving…' : 'Save session'),
                    ),
                    if (exportPath != null)
                      SelectableText(
                        'Saved summary, raw cardiac samples and interval CSVs:\n$exportPath',
                      ),
                    if (e.phase == ResonancePhase.stopped)
                      const Text(
                        'Session stopped. Partial data are preserved when export succeeds.',
                      ),
                  ],
                  card('Methods and references', [
                    ResonanceMethodsPanel(
                      config: preview ?? const ResonanceConfig(),
                    ),
                  ]),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _phaseTitle(ResonanceEngine e) => switch (e.phase) {
    ResonancePhase.idle => 'Ready',
    ResonancePhase.waiting => 'Check your signal',
    ResonancePhase.settling => 'Settle into the pace',
    ResonancePhase.measuring => 'Measuring your response',
    ResonancePhase.review => 'Review this epoch',
    ResonancePhase.resting => 'Rest',
    ResonancePhase.results => 'Assessment results',
    ResonancePhase.practice => 'Breathing practice',
    ResonancePhase.stopped => 'Session saved or ready to save',
  };
}

class _BreathPacer extends StatelessWidget {
  const _BreathPacer({
    required this.phase,
    required this.rate,
    required this.inhaleFraction,
  });
  final double phase, rate, inhaleFraction;
  @override
  Widget build(BuildContext context) {
    final expansion = phase < inhaleFraction
        ? (1 - cos(pi * phase / inhaleFraction)) / 2
        : (1 + cos(pi * (phase - inhaleFraction) / (1 - inhaleFraction))) / 2;
    final label = phase < inhaleFraction ? 'Inhale' : 'Exhale';
    return Semantics(
      label: '$label, ${rate.toStringAsFixed(1)} breaths per minute',
      child: SizedBox(
        height: 245,
        child: Center(
          child: Container(
            width: 135 + 85 * expansion,
            height: 135 + 85 * expansion,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [Color(0xFF2DD4BF), Color(0xFF0F766E)],
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.teal.withValues(alpha: 0.2),
                  blurRadius: 24,
                ),
              ],
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 28,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${rate.toStringAsFixed(1)} breaths/min',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ResponsePlot extends CustomPainter {
  _ResponsePlot(this.epochs, this.posterior, this.method);
  final List<ResonanceEpoch> epochs;
  final ResonancePosterior posterior;
  final ResonanceMethod method;
  @override
  void paint(Canvas canvas, Size size) {
    final maximum = max(
      1.0,
      epochs.map((e) => e.metrics.amplitudeMs).reduce(max),
    );
    final bottom = size.height - 24;
    final lo = posterior.rates.first, hi = posterior.rates.last;
    double x(double rate) => 22 + (rate - lo) / (hi - lo) * (size.width - 44);
    for (final e in epochs) {
      final height = e.metrics.amplitudeMs / maximum * (bottom - 12);
      canvas.drawRect(
        Rect.fromLTWH(x(e.metrics.rate) - 6, bottom - height, 12, height),
        Paint()..color = e.used ? Colors.tealAccent : Colors.grey,
      );
    }
    for (final rate in List.generate(5, (i) => lo + (hi - lo) * i / 4)) {
      final text = TextPainter(
        text: TextSpan(
          text: rate.toStringAsFixed(1),
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(x(rate) - 10, bottom + 6));
    }
    if (method == ResonanceMethod.adaptive) {
      final p = posterior.marginal, peak = posterior.marginal.reduce(max);
      final path = Path();
      for (var i = 0; i < p.length; i++) {
        final dx = x(posterior.rates[i]),
            dy = bottom - p[i] / peak * (bottom - 12);
        if (i == 0) {
          path.moveTo(dx, dy);
        } else {
          path.lineTo(dx, dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.amber
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ResponsePlot oldDelegate) => true;
}

class _IntervalPlot extends CustomPainter {
  _IntervalPlot(this.intervals);
  final List<Map<String, Object?>> intervals;
  @override
  void paint(Canvas canvas, Size size) {
    final points = intervals.skip(max(0, intervals.length - 80)).toList();
    final values = points.map((p) => p['intervalMs'] as double).toList();
    if (values.length < 2) return;
    final lo = values.reduce(min), hi = values.reduce(max);
    final first = DateTime.parse(points.first['at'] as String);
    final span = max(
      1,
      DateTime.parse(
        points.last['at'] as String,
      ).difference(first).inMilliseconds,
    );
    var path = Path();
    bool connected = false;
    for (var i = 0; i < values.length; i++) {
      if (points[i]['accepted'] != true) {
        connected = false;
        continue;
      }
      final x =
          DateTime.parse(
            points[i]['at'] as String,
          ).difference(first).inMilliseconds /
          span *
          size.width;
      final y = 8 + (hi - values[i]) / max(20, hi - lo) * (size.height - 24);
      if (!connected) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      connected = true;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.tealAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final label = TextPainter(
      text: TextSpan(
        text: '${lo.toStringAsFixed(0)}–${hi.toStringAsFixed(0)} ms',
        style: const TextStyle(color: Colors.grey, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, Offset(0, size.height - 14));
  }

  @override
  bool shouldRepaint(covariant _IntervalPlot oldDelegate) => true;
}
