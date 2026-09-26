import '../../core/models/eeg_sample.dart';

class ErpAverager {
  ErpAverager({required this.sampleRate, this.channelIndex = 0})
    : preSamples = (sampleRate * 0.1).round(),
      postSamples = (sampleRate * 0.8).round();

  final double sampleRate;
  final int channelIndex;
  final int preSamples;
  final int postSamples;
  final List<double> _history = [];
  final Map<String, List<List<double>>> _epochs = {};
  final List<_ActiveErpEpoch> _active = [];

  Map<String, List<double>> get averages => {
    for (final entry in _epochs.entries) entry.key: _average(entry.value),
  };

  Map<String, int> get counts => {
    for (final entry in _epochs.entries) entry.key: entry.value.length,
  };

  void mark(String stimulusClass) {
    _active.add(_ActiveErpEpoch(stimulusClass, List<double>.from(_history)));
  }

  bool push(EegSample sample) {
    if (channelIndex >= sample.channels.length) return false;
    final value = sample.channels[channelIndex];
    _history.add(value);
    if (_history.length > preSamples) _history.removeAt(0);
    var completed = false;
    for (final active in List<_ActiveErpEpoch>.from(_active)) {
      active.samples.add(value);
      if (active.samples.length < preSamples + postSamples) continue;
      final baselineCount = preSamples.clamp(1, active.samples.length);
      final baseline =
          active.samples.take(baselineCount).reduce((a, b) => a + b) /
          baselineCount;
      final corrected = active.samples
          .map((sample) => sample - baseline)
          .toList();
      _epochs.putIfAbsent(active.stimulusClass, () => []).add(corrected);
      _active.remove(active);
      completed = true;
    }
    return completed;
  }

  List<double> _average(List<List<double>> epochs) {
    if (epochs.isEmpty) return const [];
    final length = epochs
        .map((epoch) => epoch.length)
        .reduce((a, b) => a < b ? a : b);
    return List.generate(
      length,
      (index) =>
          epochs.fold<double>(0, (sum, epoch) => sum + epoch[index]) /
          epochs.length,
    );
  }
}

class _ActiveErpEpoch {
  _ActiveErpEpoch(this.stimulusClass, this.samples);

  final String stimulusClass;
  final List<double> samples;
}
