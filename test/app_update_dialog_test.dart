import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ccs_mobile_studio/core/services/app_update_service.dart';
import 'package:ccs_mobile_studio/core/services/session_manager.dart';

class TestSessions extends SessionManager {
  bool recording = false;
  @override
  bool get isRecording => recording;
  void setRecording(bool value) {
    recording = value;
    notifyListeners();
  }
}

void main() {
  testWidgets('automatic update dialog disables installation while recording', (
    tester,
  ) async {
    final sessions = TestSessions();
    addTearDown(sessions.dispose);
    final info = AppUpdateInfo(
      currentVersion: '1.0.7+8',
      latestVersion: '1.0.8+9',
      hasUpdate: true,
      releaseNotes: 'Update',
      releasePage: Uri.parse('https://example.test/release'),
      asset: ReleaseAsset(
        name: 'macOS.zip',
        downloadUrl: Uri.parse('https://example.test/macOS.zip'),
        sizeBytes: 100,
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<SessionManager>.value(
        value: sessions,
        child: MaterialApp(
          home: Scaffold(body: AppUpdateDialog(info: info)),
        ),
      ),
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    sessions.setRecording(true);
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      find.text('Installation paused while a recording is active.'),
      findsOneWidget,
    );
    sessions.setRecording(false);
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });
}
