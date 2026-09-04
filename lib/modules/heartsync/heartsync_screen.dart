import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/settings_service.dart';
import 'heartsync_experiment_screen.dart';
import 'models.dart';

class HeartSyncScreen extends StatefulWidget {
  const HeartSyncScreen({super.key});

  @override
  State<HeartSyncScreen> createState() => _HeartSyncScreenState();
}

class _HeartSyncScreenState extends State<HeartSyncScreen> {
  final Map<String, TextEditingController> _fields = {};
  late HeartSyncPulseMode _pulseMode;
  late HeartSyncStimulusMode _stimulusMode;
  late bool _adaptive;
  late bool _record;
  bool _loaded = false;

  TextEditingController _field(String key, Object value) =>
      _fields.putIfAbsent(key, () => TextEditingController(text: '$value'));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    final s = context.read<SettingsService>();
    _pulseMode = s.heartSyncPulseMode == 'ecg'
        ? HeartSyncPulseMode.ecg
        : HeartSyncPulseMode.ppg;
    _stimulusMode = s.heartSyncStimulusMode == 'images'
        ? HeartSyncStimulusMode.images
        : HeartSyncStimulusMode.tones;
    _adaptive = s.heartSyncAdaptiveOffsets;
    _record = s.heartSyncRecordPhysiology;
    _loaded = true;
  }

  int _int(String key, int fallback) =>
      int.tryParse(_fields[key]?.text.trim() ?? '') ?? fallback;
  double _double(String key, double fallback) =>
      double.tryParse(_fields[key]?.text.trim() ?? '') ?? fallback;
  String _text(String key, String fallback) =>
      _fields[key]?.text.trim() ?? fallback;

  HeartSyncConfig _config(SettingsService s) => HeartSyncConfig(
    totalStimuli: _int('total', s.heartSyncTotalStimuli),
    rareProportion: _double('rare', s.heartSyncRareProportion * 100) / 100,
    trialsPerBlock: _int('perBlock', s.heartSyncTrialsPerBlock),
    blocks: _int('blocks', s.heartSyncBlocks),
    pulseMode: _pulseMode,
    channelName: _text('channel', s.heartSyncChannelName),
    stimulusMode: _stimulusMode,
    frequentToneHz: _double('freqHz', s.heartSyncFrequentToneHz),
    rareToneHz: _double('rareHz', s.heartSyncRareToneHz),
    toneDurationMs: _int('toneMs', s.heartSyncToneDurationMs),
    frequentFilePath: _text('freqFile', s.heartSyncFrequentFilePath),
    rareFilePath: _text('rareFile', s.heartSyncRareFilePath),
    imageDurationMs: _int('imageMs', s.heartSyncImageDurationMs),
    deliveryProbability:
        _double('deliveryPct', s.heartSyncDeliveryProbability * 100) / 100,
    minSkippedBeats: _int('skipMin', s.heartSyncMinSkippedBeats),
    maxSkippedBeats: _int('skipMax', s.heartSyncMaxSkippedBeats),
    ipiHistoryLength: _int('ipiN', s.heartSyncIpiHistoryLength),
    systolicOffsetPercent: _double(
      'sysOffset',
      s.heartSyncSystolicOffsetPercent,
    ),
    diastolicOffsetPercent: _double(
      'diaOffset',
      s.heartSyncDiastolicOffsetPercent,
    ),
    detectionLagMs: _int('lag', s.heartSyncDetectionLagMs),
    refractoryMs: _int('refractory', s.heartSyncRefractoryMs),
    responseWindowMs: _int('responseMs', s.heartSyncResponseWindowMs),
    minimumStimulusIntervalMs: _int(
      'minimumIntervalMs',
      s.heartSyncMinimumStimulusIntervalMs,
    ),
    postHocSystolicEndPercent: _double(
      'posthoc',
      s.heartSyncPostHocSystolicEndPercent,
    ),
    adaptiveOffsets: _adaptive,
    adaptiveStepPercent: _double(
      'adaptiveStep',
      s.heartSyncAdaptiveStepPercent,
    ),
    adaptiveMinTrials: _int('adaptiveMin', s.heartSyncAdaptiveMinTrials),
    recordPhysiology: _record,
  ).validated();

  void _saveAndStart() {
    final settings = context.read<SettingsService>();
    final config = _config(settings);
    settings.update((s) {
      s.heartSyncTotalStimuli = config.totalStimuli;
      s.heartSyncRareProportion = config.rareProportion;
      s.heartSyncTrialsPerBlock = config.trialsPerBlock;
      s.heartSyncBlocks = config.blocks;
      s.heartSyncPulseMode = config.pulseMode.name;
      s.heartSyncChannelName = config.channelName;
      s.heartSyncStimulusMode = config.stimulusMode.name;
      s.heartSyncFrequentToneHz = config.frequentToneHz;
      s.heartSyncRareToneHz = config.rareToneHz;
      s.heartSyncToneDurationMs = config.toneDurationMs;
      s.heartSyncFrequentFilePath = config.frequentFilePath;
      s.heartSyncRareFilePath = config.rareFilePath;
      s.heartSyncImageDurationMs = config.imageDurationMs;
      s.heartSyncDeliveryProbability = config.deliveryProbability;
      s.heartSyncMinSkippedBeats = config.minSkippedBeats;
      s.heartSyncMaxSkippedBeats = config.maxSkippedBeats;
      s.heartSyncIpiHistoryLength = config.ipiHistoryLength;
      s.heartSyncSystolicOffsetPercent = config.systolicOffsetPercent;
      s.heartSyncDiastolicOffsetPercent = config.diastolicOffsetPercent;
      s.heartSyncDetectionLagMs = config.detectionLagMs;
      s.heartSyncRefractoryMs = config.refractoryMs;
      s.heartSyncResponseWindowMs = config.responseWindowMs;
      s.heartSyncMinimumStimulusIntervalMs = config.minimumStimulusIntervalMs;
      s.heartSyncPostHocSystolicEndPercent = config.postHocSystolicEndPercent;
      s.heartSyncAdaptiveOffsets = config.adaptiveOffsets;
      s.heartSyncAdaptiveStepPercent = config.adaptiveStepPercent;
      s.heartSyncAdaptiveMinTrials = config.adaptiveMinTrials;
      s.heartSyncRecordPhysiology = config.recordPhysiology;
    });
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HeartSyncExperimentScreen(
          participant: settings.subjectCode,
          config: config,
        ),
      ),
    );
  }

  Future<void> _pick(String key, bool audio) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: audio ? 'Choose stimulus sound' : 'Choose stimulus image',
      type: FileType.custom,
      allowedExtensions: audio
          ? const ['wav', 'mp3', 'm4a', 'aac', 'ogg']
          : const ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    );
    final path = result?.files.single.path;
    if (path != null && mounted) setState(() => _fields[key]!.text = path);
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsService>();
    if (!_loaded) return const SizedBox.shrink();
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        title: const Text('HeartSync • Cardiac Oddball'),
        backgroundColor: const Color(0xFF111827),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _section('Task design', [
              _number('Total stimuli', 'total', s.heartSyncTotalStimuli),
              _number(
                'Rare proportion (%)',
                'rare',
                s.heartSyncRareProportion * 100,
              ),
              _number(
                'Trials per block',
                'perBlock',
                s.heartSyncTrialsPerBlock,
              ),
              _number('Number of blocks', 'blocks', s.heartSyncBlocks),
              _number(
                'Response window (ms)',
                'responseMs',
                s.heartSyncResponseWindowMs,
              ),
              _number(
                'Minimum stimulus separation (ms)',
                'minimumIntervalMs',
                s.heartSyncMinimumStimulusIntervalMs,
              ),
              const Text(
                'Effective total is capped at blocks × trials per block. Each stimulus type is split as evenly as possible across systole and diastole.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ]),
            _section('Pulse detection and timing', [
              SegmentedButton<HeartSyncPulseMode>(
                segments: const [
                  ButtonSegment(
                    value: HeartSyncPulseMode.ppg,
                    label: Text('PPG'),
                  ),
                  ButtonSegment(
                    value: HeartSyncPulseMode.ecg,
                    label: Text('ECG'),
                  ),
                ],
                selected: {_pulseMode},
                onSelectionChanged: (value) => setState(() {
                  _pulseMode = value.first;
                  _field('channel', s.heartSyncChannelName).text = _pulseMode
                      .name
                      .toUpperCase();
                }),
              ),
              _textInput(
                'Stream channel name',
                'channel',
                s.heartSyncChannelName,
              ),
              _number('IPI history beats', 'ipiN', s.heartSyncIpiHistoryLength),
              _number(
                'Stimulus delivery (% detected beats)',
                'deliveryPct',
                s.heartSyncDeliveryProbability * 100,
              ),
              const Text(
                'A fresh random decision is made at every detected beat; 75–90% is the recommended range.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              _number(
                'Systolic target offset (% IPI)',
                'sysOffset',
                s.heartSyncSystolicOffsetPercent,
              ),
              _number(
                'Diastolic target offset (% IPI)',
                'diaOffset',
                s.heartSyncDiastolicOffsetPercent,
              ),
              _number(
                'Detection lag compensation (ms)',
                'lag',
                s.heartSyncDetectionLagMs,
              ),
              _number(
                'Detection refractory period (ms)',
                'refractory',
                s.heartSyncRefractoryMs,
              ),
              _number(
                'Post-hoc systolic end (% cycle)',
                'posthoc',
                s.heartSyncPostHocSystolicEndPercent,
              ),
            ]),
            _section('Stimuli', [
              SegmentedButton<HeartSyncStimulusMode>(
                segments: const [
                  ButtonSegment(
                    value: HeartSyncStimulusMode.tones,
                    label: Text('Tones'),
                  ),
                  ButtonSegment(
                    value: HeartSyncStimulusMode.images,
                    label: Text('Images'),
                  ),
                ],
                selected: {_stimulusMode},
                onSelectionChanged: (value) =>
                    setState(() => _stimulusMode = value.first),
              ),
              if (_stimulusMode == HeartSyncStimulusMode.tones) ...[
                _number(
                  'Frequent tone (Hz)',
                  'freqHz',
                  s.heartSyncFrequentToneHz,
                ),
                _number('Rare tone (Hz)', 'rareHz', s.heartSyncRareToneHz),
                _number(
                  'Tone duration (ms)',
                  'toneMs',
                  s.heartSyncToneDurationMs,
                ),
              ] else
                _number(
                  'Image duration (ms)',
                  'imageMs',
                  s.heartSyncImageDurationMs,
                ),
              _fileInput(
                'Frequent ${_stimulusMode == HeartSyncStimulusMode.tones ? 'sound (optional)' : 'image'}',
                'freqFile',
                s.heartSyncFrequentFilePath,
              ),
              _fileInput(
                'Rare ${_stimulusMode == HeartSyncStimulusMode.tones ? 'sound (optional)' : 'image'}',
                'rareFile',
                s.heartSyncRareFilePath,
              ),
            ]),
            _section('Functional phase boundary', [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Bayesian functional boundary search'),
                subtitle: const Text(
                  'Post-hoc participant bootstrap search for a symmetric '
                  'functional peri-pulse boundary maximizing |log(S/D RT '
                  'ratio)|. Reports a boundary only as established when its '
                  'effect and bootstrap stability pass confidence gates. '
                  'Delivery offsets remain fixed.',
                ),
                value: _adaptive,
                onChanged: (value) => setState(() => _adaptive = value),
              ),
              if (_adaptive) ...[
                _number(
                  'Boundary search step (% cycle)',
                  'adaptiveStep',
                  s.heartSyncAdaptiveStepPercent,
                ),
                _number(
                  'Minimum eligible trials',
                  'adaptiveMin',
                  s.heartSyncAdaptiveMinTrials,
                ),
              ],
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Save physiological streams'),
                subtitle: const Text(
                  'Controls continuous EDF saving only. A live PPG or ECG '
                  'signal is still required to time HeartSync stimuli.',
                ),
                value: _record,
                onChanged: (value) => setState(() => _record = value),
              ),
            ]),
            FilledButton.icon(
              onPressed: _saveAndStart,
              icon: const Icon(Icons.favorite),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('Start HeartSync'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF1E293B),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        ...children.expand((child) => [child, const SizedBox(height: 10)]),
      ],
    ),
  );

  Widget _number(String label, String key, Object value) => TextField(
    controller: _field(key, value),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
  );

  Widget _textInput(String label, String key, String value) => TextField(
    controller: _field(key, value),
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
  );

  Widget _fileInput(String label, String key, String value) => Row(
    children: [
      Expanded(child: _textInput(label, key, value)),
      const SizedBox(width: 8),
      IconButton.filledTonal(
        onPressed: () =>
            _pick(key, _stimulusMode == HeartSyncStimulusMode.tones),
        icon: const Icon(Icons.folder_open),
      ),
    ],
  );
}
