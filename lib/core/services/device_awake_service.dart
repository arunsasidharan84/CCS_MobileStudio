import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the device — and, on Android, the app process itself — awake for
/// the duration of a recording session.
///
/// Two independent mechanisms are engaged together:
///  1. `keepScreenOn` (Android/iOS): prevents the screen from dimming/
///     locking due to inactivity while the app is in the foreground.
///  2. A native Android foreground service + partial wake lock: keeps the
///     process alive and the CPU running even if the screen *is* turned off
///     (manual power button), the user switches to another app, or the
///     device enters Doze/App Standby. Without this, long recordings can be
///     silently throttled or killed by the OS once the app leaves the
///     foreground, independent of the screen-on flag.
///
/// Both are reference-counted together via [acquire]/[release] so nested
/// callers (e.g. multiple modules) don't fight over enable/disable state.
class DeviceAwakeService {
  DeviceAwakeService._();

  static const _channel = MethodChannel('ccs/audio');
  static int _holdCount = 0;

  static Future<void> acquire() async {
    _holdCount++;
    if (_holdCount != 1) return;
    await _setKeepScreenOn(true);
    await _setForegroundService(true);
  }

  static Future<void> release() async {
    if (_holdCount == 0) return;
    _holdCount--;
    if (_holdCount != 0) return;
    await _setKeepScreenOn(false);
    await _setForegroundService(false);
  }

  static Future<void> reset() async {
    _holdCount = 0;
    await _setKeepScreenOn(false);
    await _setForegroundService(false);
  }

  static Future<void> _setKeepScreenOn(bool enabled) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await _channel.invokeMethod('keepScreenOn', {'enable': enabled});
    } catch (e) {
      debugPrint('[DeviceAwakeService] keepScreenOn($enabled) failed: $e');
    }
  }

  /// Starts/stops the native RecordingForegroundService (Android only).
  /// Best-effort: if it fails (e.g. background start restrictions on some
  /// OEM skins), keepScreenOn above still covers the foreground case.
  static Future<void> _setForegroundService(bool enabled) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod(
        enabled ? 'startRecordingService' : 'stopRecordingService',
      );
    } catch (e) {
      debugPrint(
        '[DeviceAwakeService] foreground service($enabled) failed: $e',
      );
    }
  }
}
