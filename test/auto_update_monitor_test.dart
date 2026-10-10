import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_mobile_studio/core/services/auto_update_monitor.dart';
import 'package:ccs_mobile_studio/core/services/app_update_service.dart';

AppUpdateInfo release(String version, {bool available = true}) => AppUpdateInfo(
  currentVersion: '1.0.7+8',
  latestVersion: version,
  hasUpdate: available,
  releaseNotes: 'Test release',
  releasePage: Uri.parse('https://example.test/releases'),
  asset: null,
);
void main() {
  test('checks are throttled and offline failures are quiet', () async {
    var now = DateTime(2026);
    var calls = 0;
    final monitor = AutoUpdateMonitor(
      now: () => now,
      check: () async {
        calls++;
        throw StateError('offline');
      },
    );
    await monitor.check();
    await monitor.check();
    expect(calls, 1);
    expect(monitor.hasUpdate, false);
    now = now.add(const Duration(hours: 6));
    await monitor.check();
    expect(calls, 2);
    monitor.dispose();
  });
  test(
    'concurrent checks coalesce and disposed monitor ignores completion',
    () async {
      final pending = Completer<AppUpdateInfo>();
      var calls = 0;
      final monitor = AutoUpdateMonitor(
        check: () {
          calls++;
          return pending.future;
        },
      );
      final first = monitor.check();
      await monitor.check(force: true);
      expect(calls, 1);
      monitor.dispose();
      pending.complete(release('1.0.8+9'));
      await first;
      expect(monitor.info, isNull);
    },
  );
  test(
    'prompts defer for experiments, recording, background and existing dialogs',
    () async {
      final monitor = AutoUpdateMonitor(check: () async => release('1.0.8+9'));
      await monitor.check();
      expect(monitor.hasUpdate, true);
      AppUpdateInfo? prompt({
        bool dashboard = true,
        bool recording = false,
        bool foreground = true,
        bool open = false,
      }) => monitor.takePrompt(
        dashboardVisible: dashboard,
        recording: recording,
        foreground: foreground,
        dialogOpen: open,
      );
      expect(prompt(dashboard: false), isNull);
      expect(prompt(recording: true), isNull);
      expect(prompt(foreground: false), isNull);
      expect(prompt(open: true), isNull);
      expect(prompt()?.latestVersion, '1.0.8+9');
      expect(prompt(), isNull);
      monitor.dispose();
    },
  );
  test(
    'a newer release can prompt again; current versions never prompt',
    () async {
      var info = release('1.0.8+9');
      final monitor = AutoUpdateMonitor(check: () async => info);
      AppUpdateInfo? prompt() => monitor.takePrompt(
        dashboardVisible: true,
        recording: false,
        foreground: true,
        dialogOpen: false,
      );
      await monitor.check();
      expect(prompt(), isNotNull);
      info = release('1.0.9+10');
      await monitor.check(force: true);
      expect(prompt()?.latestVersion, '1.0.9+10');
      info = release('1.0.9+10', available: false);
      await monitor.check(force: true);
      expect(monitor.hasUpdate, false);
      expect(prompt(), isNull);
      monitor.dispose();
    },
  );
}
