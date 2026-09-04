import 'package:flutter/foundation.dart';

import '../eeg/acquisition_service.dart';
import '../models/device_profile.dart';
import 'settings_service.dart';

/// Persists EEG channel labels and enable/disable state to JSON by delegating to SettingsService.
class ChannelConfigService extends ChangeNotifier {
  ChannelConfigService();

  SettingsService? _settingsService;
  AcquisitionService? _acquisitionService;

  String get activeProfileKey {
    final connected = _acquisitionService?.connectedDeviceProfile;
    if (connected != null) return connected.id;
    final kind = _acquisitionService?.connectedDeviceKind;
    if (kind == DeviceKind.orbit) return 'orbit';
    if (kind == DeviceKind.synthetic) return 'synthetic';
    if (kind == DeviceKind.epidome) return 'epidome';
    final saved = _settingsService?.lastDeviceKind;
    return saved == 'orbit' ? 'orbit' : 'epidome';
  }

  String get activeProfileTitle {
    final profile = _profile;
    if (profile != null) {
      final stream = _primaryStream;
      return '${profile.name} • ${stream?.channelCount ?? 0} recording channels';
    }
    final acquisition = _acquisitionService;
    if (activeProfileKey == 'epidome') {
      return 'xAMP-L10 / EpiDome • 16 channels';
    }
    if (activeProfileKey == 'synthetic') {
      return 'Synthetic EpiDome • 16 channels';
    }
    final label = acquisition?.connectedDeviceLabel ?? 'Orbit';
    return '$label • ${labels.length} channels';
  }

  List<String> get _defaultLabels {
    final stream = _primaryStream;
    if (stream != null) return List.of(stream.channelLabels);
    if (activeProfileKey == 'epidome' || activeProfileKey == 'synthetic') {
      return List.of(kDefaultEpiDomeLabels);
    }
    final acquisition = _acquisitionService;
    if (acquisition != null && acquisition.connectedDeviceKind != null) {
      return List.of(acquisition.channelLabels);
    }
    return List.of(kDefaultOrbitLabels);
  }

  List<String> get labels {
    final settings = _settingsService;
    if (settings == null) return _defaultLabels;
    final profile = _profile;
    final stream = _primaryStream;
    if (profile != null && stream != null) {
      return List<String>.of(stream.channelLabels);
    }
    if (activeProfileKey == 'epidome' || activeProfileKey == 'synthetic') {
      return settings.channelLabels.length == 16
          ? settings.channelLabels
          : _defaultLabels;
    }
    final configured = settings.amplifierChannelLabels[activeProfileKey];
    return configured != null && configured.length == _defaultLabels.length
        ? configured
        : _defaultLabels;
  }

  List<bool> get enabled {
    final settings = _settingsService;
    if (settings == null) return List.filled(labels.length, true);
    if (_profile != null) {
      final configured = settings.amplifierChannelEnabled[activeProfileKey];
      return configured != null && configured.length == labels.length
          ? configured
          : List<bool>.filled(labels.length, true);
    }
    if (activeProfileKey == 'epidome' || activeProfileKey == 'synthetic') {
      return settings.channelEnabled.length == labels.length
          ? settings.channelEnabled
          : List.filled(labels.length, true);
    }
    final configured = settings.amplifierChannelEnabled[activeProfileKey];
    return configured != null && configured.length == labels.length
        ? configured
        : List.filled(labels.length, true);
  }

  /// Called by ChangeNotifierProxyProvider to inject SettingsService.
  void updateDependencies(
    SettingsService settings,
    AcquisitionService acquisition,
  ) {
    _settingsService = settings;
    _acquisitionService = acquisition;
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
      final stream = _primaryStream;
      if (stream != null) {
        stream.channelLabels[index] = label;
        return;
      }
      if (activeProfileKey == 'epidome' || activeProfileKey == 'synthetic') {
        settings.channelLabels[index] = label;
      } else {
        final values = List<String>.from(labels);
        values[index] = label;
        settings.amplifierChannelLabels[activeProfileKey] = values;
      }
    });
    notifyListeners();
  }

  DeviceProfile? get _profile {
    final settings = _settingsService;
    if (settings == null) return null;
    return settings.profileById(activeProfileKey);
  }

  SignalStreamProfile? get _primaryStream {
    final streams = _profile?.enabledStreams ?? const <SignalStreamProfile>[];
    for (final stream in streams) {
      if (stream.signalType == SignalType.eeg ||
          stream.signalType == SignalType.ecg) {
        return stream;
      }
    }
    return streams.isEmpty ? null : streams.first;
  }

  void setEnabled(int index, bool value) {
    final s = _settingsService;
    if (s == null) return;
    if (index < 0 || index >= enabled.length) return;
    s.update((settings) {
      if (activeProfileKey == 'epidome' || activeProfileKey == 'synthetic') {
        settings.channelEnabled[index] = value;
      } else {
        final values = List<bool>.from(enabled);
        values[index] = value;
        settings.amplifierChannelEnabled[activeProfileKey] = values;
      }
    });
    notifyListeners();
  }

  void applyDefaults([int? channelCount]) {
    final s = _settingsService;
    if (s == null) return;
    s.update((settings) {
      final count = channelCount ?? _defaultLabels.length;
      if (activeProfileKey == 'epidome' || activeProfileKey == 'synthetic') {
        settings.channelLabels = List.of(kDefaultEpiDomeLabels);
        settings.channelEnabled = List.filled(16, true);
      } else {
        final defaults = _defaultLabels.length == count
            ? _defaultLabels
            : List.generate(count, (i) => 'Ch ${i + 1}');
        settings.amplifierChannelLabels[activeProfileKey] = defaults;
        settings.amplifierChannelEnabled[activeProfileKey] = List.filled(
          count,
          true,
        );
      }
    });
    notifyListeners();
  }
}
