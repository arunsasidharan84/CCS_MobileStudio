import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/models/eeg_sample.dart';
import '../../core/models/module_type.dart';
import '../../core/services/alert_service.dart';
import '../../core/services/channel_config_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/settings_service.dart';
import '../standalone/standalone_screen.dart';
import 'erp_averager.dart';

const _paradigms = [
  'Visual Oddball',
  'Auditory Oddball',
  'N400',
  'P50',
  'MMN',
  'N170',
];

class GenericErpScreen extends StatefulWidget {
  const GenericErpScreen({super.key});

  @override
  State<GenericErpScreen> createState() => _GenericErpScreenState();
}

class _GenericErpScreenState extends State<GenericErpScreen> {
  Timer? _trialTimer;
  StreamSubscription<EegSample>? _sampleSub;
  final AudioPlayer _player = AudioPlayer();
  ErpAverager? _averager;
  bool _running = false;
  bool _rare = false;
  int _trial = 0;
  bool _ownsRecording = false;
  List<bool> _trialPlan = const [];

  @override
  void initState() {
    super.initState();
    final acquisition = context.read<AcquisitionService>();
    _averager = ErpAverager(sampleRate: acquisition.sampleRate);
    _sampleSub = acquisition.samples.listen((sample) {
      if (_averager?.push(sample) ?? false) {
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _trialTimer?.cancel();
    _sampleSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _pickFile(bool rare) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: rare
          ? 'Choose rare / target stimulus'
          : 'Choose frequent / standard stimulus',
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    context.read<SettingsService>().update((settings) {
      if (rare) {
        settings.genericErpRareFilePath = path;
      } else {
        settings.genericErpFrequentFilePath = path;
      }
    });
  }

  Future<void> _start() async {
    final acquisition = context.read<AcquisitionService>();
    final session = context.read<SessionManager>();
    final settings = context.read<SettingsService>();
    final channels = context.read<ChannelConfigService>();
    _averager = ErpAverager(sampleRate: acquisition.sampleRate);
    _trial = 0;
    final rareCount =
        (settings.genericErpTrials * settings.genericErpRareProbability)
            .round();
    _trialPlan = [
      ...List<bool>.filled(rareCount, true),
      ...List<bool>.filled(settings.genericErpTrials - rareCount, false),
    ]..shuffle(Random());
    _ownsRecording = !session.isRecording;
    if (_ownsRecording) {
      await session.startRecording(
        module: ModuleType.erp,
        subjectId: settings.subjectCode,
        channelCount: acquisition.channelCount,
        sampleRate: acquisition.sampleRate.round(),
        channelLabels: acquisition.recordingChannelLabels(channels.labels),
        enabledChannels: acquisition.recordingEnabledChannels(channels.enabled),
      );
    }
    if (!mounted) return;
    setState(() => _running = true);
    await _presentTrial();
    _trialTimer = Timer.periodic(
      Duration(milliseconds: settings.genericErpIntervalMs),
      (_) => _presentTrial(),
    );
  }

  Future<void> _presentTrial() async {
    if (!_running) return;
    final settings = context.read<SettingsService>();
    if (_trial >= settings.genericErpTrials) {
      await _stop();
      return;
    }
    if (settings.genericErpParadigm == 'P50') {
      _trial++;
      await _presentP50Pair(settings);
      return;
    }
    final rare = _trialPlan[_trial];
    final code = rare
        ? settings.genericErpRareMarker
        : settings.genericErpFrequentMarker;
    final label =
        '${settings.genericErpParadigm}_${rare ? 'rare' : 'frequent'}';
    context.read<SessionManager>().recordEvent(label, code);
    _averager?.mark(rare ? 'Rare' : 'Frequent');
    setState(() {
      _rare = rare;
      _trial++;
    });
    final path = rare
        ? settings.genericErpRareFilePath
        : settings.genericErpFrequentFilePath;
    if (_isAuditory(settings.genericErpParadigm)) {
      await _playAuditory(path);
    }
  }

  Future<void> _presentP50Pair(SettingsService settings) async {
    final session = context.read<SessionManager>();
    session.recordEvent('P50_S1', settings.genericErpFrequentMarker);
    _averager?.mark('S1');
    setState(() => _rare = false);
    await _playAuditory(settings.genericErpFrequentFilePath);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!_running || !mounted) return;
    session.recordEvent('P50_S2', settings.genericErpRareMarker);
    _averager?.mark('S2');
    setState(() => _rare = true);
    await _playAuditory(settings.genericErpRareFilePath);
  }

  Future<void> _playAuditory(String path) async {
    if (path.isNotEmpty && await File(path).exists()) {
      await _player.play(DeviceFileSource(path));
    } else if (mounted) {
      await context.read<AlertService>().playBeep();
    }
  }

  Future<void> _stop() async {
    _trialTimer?.cancel();
    _trialTimer = null;
    if (_ownsRecording) await context.read<SessionManager>().stopRecording();
    if (mounted) setState(() => _running = false);
  }

  bool _isAuditory(String paradigm) =>
      paradigm.contains('Auditory') || paradigm == 'P50' || paradigm == 'MMN';

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final averages = _averager?.averages ?? const <String, List<double>>{};
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        title: const Text('Conventional ERP Laboratory'),
        backgroundColor: const Color(0xFF111827),
        actions: [
          IconButton(
            tooltip: 'Live EEG viewer',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const StandaloneScreen(viewerOnly: true),
              ),
            ),
            icon: const Icon(Icons.waves),
          ),
        ],
      ),
      body: Theme(
        data: Theme.of(context).copyWith(
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0xFF0F172A),
            labelStyle: const TextStyle(color: Colors.white70),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.white24),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.tealAccent),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.white12),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFA7F3D0),
              side: const BorderSide(color: Colors.white24),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
            ),
          ),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(color: Colors.white),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _panel(
                title: 'Task configuration',
                icon: Icons.tune,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: 220,
                          child: DropdownButtonFormField<String>(
                            initialValue: settings.genericErpParadigm,
                            dropdownColor: const Color(0xFF1E293B),
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'ERP paradigm',
                            ),
                            items: _paradigms
                                .map(
                                  (value) => DropdownMenuItem(
                                    value: value,
                                    child: Text(value),
                                  ),
                                )
                                .toList(),
                            onChanged: _running
                                ? null
                                : (value) => settings.update((s) {
                                    s.genericErpParadigm = value!;
                                    s.genericErpComponent = _defaultComponent(
                                      value,
                                    );
                                  }),
                          ),
                        ),
                        SizedBox(
                          width: 180,
                          child: DropdownButtonFormField<String>(
                            initialValue: settings.genericErpComponent,
                            dropdownColor: const Color(0xFF1E293B),
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: 'ERP waveform',
                            ),
                            items: const ['P300', 'N400', 'P50', 'MMN', 'N170']
                                .map(
                                  (value) => DropdownMenuItem(
                                    value: value,
                                    child: Text(value),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) => settings.update(
                              (s) => s.genericErpComponent = value!,
                            ),
                          ),
                        ),
                        _numberField(
                          'Trials',
                          settings.genericErpTrials,
                          (value) => settings.update(
                            (s) => s.genericErpTrials = value.clamp(10, 1000),
                          ),
                        ),
                        _numberField(
                          'Interval (ms)',
                          settings.genericErpIntervalMs,
                          (value) => settings.update(
                            (s) => s.genericErpIntervalMs = value.clamp(
                              200,
                              10000,
                            ),
                          ),
                        ),
                        _numberField(
                          'Standard code',
                          settings.genericErpFrequentMarker,
                          (value) => settings.update(
                            (s) => s.genericErpFrequentMarker = value.clamp(
                              1,
                              32767,
                            ),
                          ),
                        ),
                        _numberField(
                          'Target code',
                          settings.genericErpRareMarker,
                          (value) => settings.update(
                            (s) =>
                                s.genericErpRareMarker = value.clamp(1, 32767),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Target probability ${(settings.genericErpRareProbability * 100).round()}%',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    Slider(
                      value: settings.genericErpRareProbability,
                      min: 0.05,
                      max: 0.5,
                      divisions: 9,
                      onChanged: _running
                          ? null
                          : (value) => settings.update(
                              (s) => s.genericErpRareProbability = value,
                            ),
                    ),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final tiles = [
                          _fileTile(
                            'Standard stimulus',
                            settings.genericErpFrequentFilePath,
                            false,
                          ),
                          _fileTile(
                            'Target stimulus',
                            settings.genericErpRareFilePath,
                            true,
                          ),
                        ];
                        if (constraints.maxWidth < 650) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              tiles.first,
                              const SizedBox(height: 8),
                              tiles.last,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(child: tiles.first),
                            const SizedBox(width: 10),
                            Expanded(child: tiles.last),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _panel(
                title: 'Stimulus preview',
                icon: Icons.visibility_outlined,
                child: SizedBox(
                  height: 190,
                  child: _isAuditory(settings.genericErpParadigm)
                      ? Center(
                          child: Icon(
                            _rare
                                ? Icons.notifications_active
                                : Icons.volume_up,
                            size: _rare ? 110 : 70,
                            color: _rare ? Colors.orange : Colors.tealAccent,
                          ),
                        )
                      : _visualStimulus(settings),
                ),
              ),
              const SizedBox(height: 14),
              _panel(
                title: 'Realtime ERP',
                icon: Icons.show_chart,
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Show waveform while recording',
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        '${settings.genericErpComponent} • baseline −100 to 0 ms • epoch to 800 ms',
                        style: const TextStyle(color: Colors.white60),
                      ),
                      value: settings.genericErpShowRealtime,
                      onChanged: (value) => settings.update(
                        (s) => s.genericErpShowRealtime = value,
                      ),
                    ),
                    if (settings.genericErpShowRealtime)
                      SizedBox(
                        height: 240,
                        child: ErpWaveformPlot(
                          averages: averages,
                          sampleRate: context
                              .read<AcquisitionService>()
                              .sampleRate,
                          component: settings.genericErpComponent,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: _running ? _stop : _start,
                icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                label: Text(
                  _running
                      ? 'Stop • trial $_trial/${settings.genericErpTrials}'
                      : 'Start ERP task',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panel({
    required String title,
    required IconData icon,
    required Widget child,
  }) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF1E293B),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Colors.white12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: Colors.tealAccent, size: 20),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        child,
      ],
    ),
  );

  Widget _numberField(String label, int value, ValueChanged<int> changed) =>
      SizedBox(
        width: 150,
        child: TextFormField(
          key: ValueKey('$label-$value'),
          initialValue: '$value',
          enabled: !_running,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(labelText: label),
          onFieldSubmitted: (text) {
            final parsed = int.tryParse(text);
            if (parsed != null) changed(parsed);
          },
        ),
      );

  Widget _fileTile(String label, String path, bool rare) => OutlinedButton.icon(
    onPressed: _running ? null : () => _pickFile(rare),
    icon: const Icon(Icons.folder_open),
    label: Text(
      path.isEmpty
          ? '$label: use default'
          : '$label: ${path.split(Platform.pathSeparator).last}',
    ),
  );

  Widget _visualStimulus(SettingsService settings) {
    final path = _rare
        ? settings.genericErpRareFilePath
        : settings.genericErpFrequentFilePath;
    if (path.isNotEmpty && File(path).existsSync()) {
      return Image.file(File(path), fit: BoxFit.contain, gaplessPlayback: true);
    }
    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: _rare ? 150 : 90,
        height: _rare ? 150 : 90,
        decoration: BoxDecoration(
          color: _rare ? Colors.orange : Colors.teal,
          shape: _rare ? BoxShape.circle : BoxShape.rectangle,
        ),
      ),
    );
  }

  String _defaultComponent(String paradigm) => switch (paradigm) {
    'N400' => 'N400',
    'P50' => 'P50',
    'MMN' => 'MMN',
    'N170' => 'N170',
    _ => 'P300',
  };
}

class ErpWaveformPlot extends StatelessWidget {
  const ErpWaveformPlot({
    super.key,
    required this.averages,
    required this.sampleRate,
    required this.component,
  });

  final Map<String, List<double>> averages;
  final double sampleRate;
  final String component;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _ErpPainter(
      averages: averages,
      sampleRate: sampleRate,
      component: component,
    ),
  );
}

class _ErpPainter extends CustomPainter {
  const _ErpPainter({
    required this.averages,
    required this.sampleRate,
    required this.component,
  });
  final Map<String, List<double>> averages;
  final double sampleRate;
  final String component;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xFF111827), BlendMode.src);
    final grid = Paint()..color = Colors.white12;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      grid,
    );
    final window = switch (component) {
      'P50' => (40.0, 80.0),
      'N170' => (130.0, 210.0),
      'N400' => (300.0, 500.0),
      'MMN' => (100.0, 250.0),
      _ => (250.0, 500.0),
    };
    double xForMs(double ms) => size.width * (ms + 100) / 900;
    canvas.drawRect(
      Rect.fromLTRB(xForMs(window.$1), 0, xForMs(window.$2), size.height),
      Paint()..color = Colors.amber.withValues(alpha: 0.08),
    );
    final all = averages.values.expand((value) => value);
    final scale = all.isEmpty
        ? 1.0
        : all.map((v) => v.abs()).fold<double>(1, max);
    for (final entry in averages.entries) {
      if (entry.value.length < 2) continue;
      final path = Path();
      for (var index = 0; index < entry.value.length; index++) {
        final x = size.width * index / (entry.value.length - 1);
        final y =
            size.height / 2 - entry.value[index] / scale * size.height * 0.42;
        index == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = entry.key == 'Rare'
              ? Colors.orangeAccent
              : Colors.tealAccent
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
    final text = TextPainter(
      text: TextSpan(
        text: '$component  •  teal standard  •  orange target',
        style: const TextStyle(color: Colors.white70, fontSize: 11),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, const Offset(8, 8));
  }

  @override
  bool shouldRepaint(covariant _ErpPainter oldDelegate) => true;
}
