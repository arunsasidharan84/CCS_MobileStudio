import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Plays repeated beep tones to alert the user when EEG reconnection fails.
///
/// Uses the `ccs/audio` MethodChannel (same as NIDRA's audio channel).
class AlertService {
  static const _channel = MethodChannel('ccs/audio');
  static const _beepIntervalMs = 2000;

  bool _isBeeping = false;
  Timer? _beepTimer;

  bool get isBeeping => _isBeeping;

  /// Start repeated beeping. Idempotent — calling again while already beeping
  /// has no effect.
  void startBeeping() {
    if (_isBeeping) return;
    _isBeeping = true;
    _beep(); // immediate first beep
    _beepTimer = Timer.periodic(
      const Duration(milliseconds: _beepIntervalMs),
      (_) => _beep(),
    );
  }

  /// Stop beeping.
  void stopBeeping() {
    _isBeeping = false;
    _beepTimer?.cancel();
    _beepTimer = null;
  }

  void dispose() => stopBeeping();

  /// Play a single beep immediately.
  Future<void> playBeep() => _beep();

  Future<void> _beep() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await _channel.invokeMethod('playTone', {
        'volume': 85,
        'durationMs': 300,
      });
    } catch (e) {
      debugPrint('[AlertService] Beep failed: $e');
    }
  }
}
