/// Identifies which research module owns an EEG session.
enum ModuleType {
  nidra,
  angel,
  wm,
  heartsync,
  standalone,
  sleepiness;

  /// Short tag used in file names (e.g. NIDRA, ANGEL, WM, EEG, SSS).
  String get fileTag => switch (this) {
    ModuleType.nidra => 'NIDRA',
    ModuleType.angel => 'ANGEL',
    ModuleType.wm => 'WM',
    ModuleType.heartsync => 'HEARTSYNC',
    ModuleType.standalone => 'EEG',
    ModuleType.sleepiness => 'SSS',
  };

  /// Human-readable label.
  String get displayName => switch (this) {
    ModuleType.nidra => 'Train NIDRA',
    ModuleType.angel => 'ANGEL',
    ModuleType.wm => 'Adaptive WM',
    ModuleType.heartsync => 'HeartSync',
    ModuleType.standalone => 'EEG Recorder',
    ModuleType.sleepiness => 'Sleepiness Scale',
  };

  static ModuleType? fromKey(String key) {
    final normalized = key.trim().toLowerCase();
    for (final module in ModuleType.values) {
      if (module.name == normalized ||
          module.fileTag.toLowerCase() == normalized) {
        return module;
      }
    }
    if (normalized == 'adaptive_wm' || normalized == 'adaptivewm') {
      return ModuleType.wm;
    }
    if (normalized == 'heart_sync' || normalized == 'heart') {
      return ModuleType.heartsync;
    }
    if (normalized == 'recorder' || normalized == 'eeg_recorder') {
      return ModuleType.standalone;
    }
    if (normalized == 'sss' ||
        normalized == 'stanford_sleepiness_scale' ||
        normalized == 'sleepiness_scale') {
      return ModuleType.sleepiness;
    }
    return null;
  }
}
