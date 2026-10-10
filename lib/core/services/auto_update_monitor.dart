import 'package:flutter/foundation.dart';
import 'app_update_service.dart';

/// Quiet discovery; the UI only prompts on the idle dashboard. Download and
/// installation remain an explicit choice, like SleepStudio.
class AutoUpdateMonitor extends ChangeNotifier {
  AutoUpdateMonitor({
    Future<AppUpdateInfo> Function()? check,
    DateTime Function()? now,
    this.interval = const Duration(hours: 6),
  }) : _check = check ?? AppUpdateService.check,
       _now = now ?? DateTime.now;
  final Future<AppUpdateInfo> Function() _check;
  final DateTime Function() _now;
  final Duration interval;
  AppUpdateInfo? info;
  DateTime? _lastCheck;
  bool _busy = false, _disposed = false;
  final _shown = <String>{};
  bool get hasUpdate => info?.hasUpdate ?? false;
  Future<void> check({bool force = false}) async {
    final now = _now();
    if (_busy ||
        _disposed ||
        (!force &&
            _lastCheck != null &&
            now.difference(_lastCheck!) < interval)) {
      return;
    }
    _busy = true;
    _lastCheck = now;
    try {
      final latest = await _check();
      if (!_disposed) {
        info = latest;
        notifyListeners();
      }
    } catch (_) {
      /* Background discovery must not interrupt offline work. */
    } finally {
      _busy = false;
    }
  }

  AppUpdateInfo? takePrompt({
    required bool dashboardVisible,
    required bool recording,
    required bool foreground,
    required bool dialogOpen,
  }) {
    final candidate = info;
    if (_disposed ||
        !dashboardVisible ||
        recording ||
        !foreground ||
        dialogOpen ||
        candidate == null ||
        !candidate.hasUpdate ||
        _shown.contains(candidate.latestVersion)) {
      return null;
    }
    _shown.add(candidate.latestVersion);
    return candidate;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
