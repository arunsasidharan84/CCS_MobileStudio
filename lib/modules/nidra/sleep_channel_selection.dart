class SleepChannelSelection {
  const SleepChannelSelection({
    required this.signalIndex,
    required this.signalLabel,
    this.referenceIndex,
    this.referenceLabel,
  });

  final int signalIndex;
  final String signalLabel;
  final int? referenceIndex;
  final String? referenceLabel;

  String get derivationLabel =>
      referenceLabel == null ? signalLabel : '$signalLabel-$referenceLabel';

  static SleepChannelSelection? fromLabels(
    List<String> labels, {
    List<bool>? enabledChannels,
    String? preferredSignalLabel,
    String? preferredReferenceLabel,
  }) {
    if (labels.isEmpty) return null;
    final normalized = labels.map(_normalize).toList(growable: false);
    bool enabled(int index) =>
        enabledChannels == null ||
        index >= enabledChannels.length ||
        enabledChannels[index];

    int findFirst(List<String> priorities, bool Function(int) allowed) {
      for (final priority in priorities) {
        final index = normalized.indexOf(priority);
        if (index >= 0 && enabled(index) && allowed(index)) return index;
      }
      return -1;
    }

    final requestedSignal = _normalize(preferredSignalLabel ?? '');
    final explicitSignalIndex = requestedSignal.isEmpty
        ? -1
        : findFirst([requestedSignal], (index) {
            return _isEegSignal(normalized[index]);
          });
    final preferredIndex = explicitSignalIndex >= 0
        ? explicitSignalIndex
        : findFirst(const [
            'C3',
            'C4',
            'CZ',
            'FZ',
            'C1',
            'C2',
            'F3',
            'F4',
            // The legacy CCS 16-channel files use generic names. EEG 3 was
            // the best single-channel causal derivation in the supplied SSA3
            // whole-night replay; users can still override this in settings.
            'EEG3',
          ], (index) => _isEegSignal(normalized[index]));
    final signalIndex = preferredIndex >= 0
        ? preferredIndex
        : List<int>.generate(labels.length, (index) => index).firstWhere(
            (index) => enabled(index) && _isEegSignal(normalized[index]),
            orElse: () => -1,
          );
    if (signalIndex < 0) return null;

    final requestedReference = preferredReferenceLabel ?? '';
    final normalizedReference = _normalize(requestedReference);
    final explicitlyUnreferenced = requestedReference == '__none__';
    final referenceIndex = explicitlyUnreferenced
        ? -1
        : normalizedReference.isNotEmpty
        ? findFirst([normalizedReference], (index) => index != signalIndex)
        : findFirst(const [
            'M1',
            'M2',
            'A1',
            'A2',
          ], (index) => index != signalIndex);
    return SleepChannelSelection(
      signalIndex: signalIndex,
      signalLabel: labels[signalIndex],
      referenceIndex: referenceIndex >= 0 ? referenceIndex : null,
      referenceLabel: referenceIndex >= 0 ? labels[referenceIndex] : null,
    );
  }

  static String _normalize(String label) =>
      label.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  static bool _isEegSignal(String label) {
    if (label.isEmpty ||
        const {'M1', 'M2', 'A1', 'A2'}.contains(label) ||
        label.contains('EOG') ||
        label.startsWith('LOC') ||
        label.startsWith('ROC') ||
        label.contains('EMG') ||
        label.contains('ECG') ||
        label.contains('EKG') ||
        label.contains('PPG') ||
        label.contains('PLETH') ||
        label.contains('ANNOT')) {
      return false;
    }
    return true;
  }
}
