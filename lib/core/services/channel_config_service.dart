import 'package:flutter/foundation.dart';
import 'settings_service.dart';

/// Persists EEG channel labels and enable/disable state to JSON by delegating to SettingsService.
class ChannelConfigService extends ChangeNotifier {
  ChannelConfigService();

  SettingsService? _settingsService;

  List<String> get labels => _settingsService?.channelLabels ?? List.of(kDefaultEpiDomeLabels);
  List<bool> get enabled => _settingsService?.channelEnabled ?? List.filled(16, true);

  /// Called by ChangeNotifierProxyProvider to inject SettingsService.
  void updateSettings(SettingsService settings) {
    _settingsService = settings;
    notifyListeners();
  }

  Future<void> load() async {
    // Redundant now, settings are loaded by SettingsService.
  }

  Future<void> save() async {
    // Redundant now, settings are saved by SettingsService.
  }

  void setLabel(int index, String label) {
    final s = _settingsService;
    if (s == null) return;
    if (index < 0 || index >= labels.length) return;
    s.update((settings) {
      settings.channelLabels[index] = label;
    });
    notifyListeners();
  }

  void setEnabled(int index, bool value) {
    final s = _settingsService;
    if (s == null) return;
    if (index < 0 || index >= enabled.length) return;
    s.update((settings) {
      settings.channelEnabled[index] = value;
    });
    notifyListeners();
  }

  void applyDefaults(int channelCount) {
    final s = _settingsService;
    if (s == null) return;
    s.update((settings) {
      if (channelCount == 16) {
        settings.channelLabels = List.of(kDefaultEpiDomeLabels);
        settings.channelEnabled = List.filled(16, true);
      } else if (channelCount == 3) {
        settings.channelLabels = List.of(kDefaultOrbitLabels);
        settings.channelEnabled = List.filled(3, true);
      } else {
        settings.channelLabels = List.generate(channelCount, (i) => 'Ch ${i + 1}');
        settings.channelEnabled = List.filled(channelCount, true);
      }
    });
    notifyListeners();
  }
}
