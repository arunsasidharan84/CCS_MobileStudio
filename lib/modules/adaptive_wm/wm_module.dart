import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/models/module_type.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/services/session_manager.dart';
import 'trial_runner.dart';
import 'wm_summary_service.dart';

class WmModule extends ChangeNotifier {
  WmModule({required this.sessionManager}) {
    runner = TrialRunner();
    runner.onMarkerSent = (label, code) {
      if (_recordEeg && sessionManager.isRecording) {
        sessionManager.recordEvent(label, code);
      }
    };
    runner.addListener(() {
      notifyListeners();
    });
  }

  final SessionManager sessionManager;
  late final TrialRunner runner;
  bool _recordEeg = true;
  bool _isSessionActive = false;

  bool get isSessionActive => _isSessionActive;
  bool get recordEeg => _recordEeg;

  void setRecordEeg(bool value) {
    _recordEeg = value;
    notifyListeners();
  }

  void configure({
    required int totalTrials,
    required int fixationDurationMs,
    required int cueDurationMs,
    required int encodingDurationMs,
    required int delayDurationMs,
  }) {
    runner.totalTrials = totalTrials;
    runner.fixationDurationMs = fixationDurationMs;
    runner.cueDurationMs = cueDurationMs;
    runner.encodingDurationMs = encodingDurationMs;
    runner.delayDurationMs = delayDurationMs;
    notifyListeners();
  }

  Future<void> startSession({
    required String subject,
    required int channelCount,
    required int sampleRate,
    List<String>? channelLabels,
    List<bool>? enabledChannels,
  }) async {
    if (_isSessionActive) return;
    _isSessionActive = true;
    notifyListeners();

    if (_recordEeg) {
      await sessionManager.startSession(
        subject: subject,
        module: ModuleType.wm,
        channelCount: channelCount,
        sampleRate: sampleRate,
        channelLabels: channelLabels,
        enabledChannels: enabledChannels,
      );
    }

    await runner.start();
  }

  Future<void> stopSession(String subject) async {
    if (!_isSessionActive) return;
    final sessionStem = _recordEeg ? sessionManager.currentSessionStem : null;
    runner.stop();
    await sessionManager.stopSession();
    _isSessionActive = false;
    notifyListeners();

    await exportReports(subject, sessionStem: sessionStem);
  }

  Future<void> exportReports(String subject, {String? sessionStem}) async {
    try {
      final csvPath = await runner.writeLogFile(subject);
      String? pdfPath;
      if (runner.records.isNotEmpty) {
        pdfPath = await WmSummaryService.generate(
          participant: subject,
          records: runner.records,
          sessionStart: runner.sessionStartTime,
        );
      }

      if (Platform.isAndroid) {
        if (await Permission.manageExternalStorage.request().isGranted ||
            await Permission.storage.request().isGranted) {
          final stem =
              sessionStem ??
              FileNamingService.stem(
                subject,
                ModuleType.wm,
                runner.sessionStartTime,
              );

          await FileNamingService.exportToDownloads(
            csvPath,
            subject: subject,
            sessionStem: stem,
          );

          if (pdfPath != null) {
            await FileNamingService.exportToDownloads(
              pdfPath,
              subject: subject,
              sessionStem: stem,
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[WmModule] Error exporting reports: $e');
    }
  }

  @override
  void dispose() {
    runner.dispose();
    super.dispose();
  }
}
