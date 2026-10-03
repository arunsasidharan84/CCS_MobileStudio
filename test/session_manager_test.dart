import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccs_mobile_studio/core/eeg/acquisition_service.dart';
import 'package:ccs_mobile_studio/core/eeg/edf_recorder.dart';
import 'package:ccs_mobile_studio/core/models/module_type.dart';
import 'package:ccs_mobile_studio/core/models/device_profile.dart';
import 'package:ccs_mobile_studio/core/services/session_manager.dart';
import 'package:ccs_mobile_studio/core/services/settings_service.dart';
import 'package:ccs_mobile_studio/core/services/file_naming_service.dart';
import 'package:ccs_mobile_studio/core/services/multi_stream_lsl_service.dart';
import 'package:ccs_mobile_studio/core/services/multi_device_acquisition_service.dart';

class TestEdfRecorder extends EdfRecorder {
  final List<Map<String, dynamic>> startedCalls = [];
  bool _mockRecording = false;
  String? _mockPath;

  @override
  bool get isRecording => _mockRecording;

  @override
  String? get path => _mockPath;

  @override
  Future<String> startAtPath({
    required String path,
    required String subject,
    required int channelCount,
    required int sampleRate,
    List<String>? channelLabels,
    List<bool>? enabledChannels,
    bool dcBlockElectrophysiology = false,
  }) async {
    _mockRecording = true;
    _mockPath = path;
    startedCalls.add({
      'path': path,
      'subject': subject,
      'channelCount': channelCount,
      'sampleRate': sampleRate,
      'channelLabels': channelLabels,
      'enabledChannels': enabledChannels,
      'dcBlockElectrophysiology': dcBlockElectrophysiology,
    });
    return path;
  }

  @override
  Future<String?> stop() async {
    _mockRecording = false;
    return _mockPath;
  }
}

class TestAcquisitionService extends AcquisitionService {
  AcquisitionState _testState = AcquisitionState.disconnected;
  DeviceProfile? _testProfile;

  void setTestState(AcquisitionState state) {
    _testState = state;
  }

  void setTestProfile(DeviceProfile? profile) {
    _testProfile = profile;
  }

  @override
  AcquisitionState get currentState => _testState;

  @override
  DeviceProfile? get connectedDeviceProfile => _testProfile;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EdfRecorder default configuration & marker hold', () {
    test('defaults to 16 channels at 250 Hz with standard labels', () {
      final recorder = EdfRecorder();
      expect(recorder.channelCount, 16);
      expect(recorder.sampleRate, 250);
      expect(recorder.channelLabels.length, 16);
      expect(recorder.channelLabels.first, 'Fp1');
    });

    test('selectEnabledChannels correctly filters 9 of 16 channels', () {
      final labels = [
        'Fp1', 'Fp2', 'C1', 'C2', 'TP9( M1)', 'TP10 (M2)',
        'EOG L', 'EMG1', 'EMG 2', '', 'O1', 'Oz', 'O2', 'F7', 'F8', 'T3',
      ];
      final enabled = [
        true, true, true, true, true, true,
        true, true, true, false, false, false, false, false, false, false,
      ];
      final selection = EdfRecorder.selectEnabledChannels(
        channelCount: 16,
        channelLabels: labels,
        enabledChannels: enabled,
      );
      expect(selection.indices.length, 9);
      expect(selection.labels.length, 9);
      expect(selection.labels, [
        'Fp1', 'Fp2', 'C1', 'C2', 'TP9( M1)', 'TP10 (M2)',
        'EOG L', 'EMG1', 'EMG 2',
      ]);
    });
  });

  group('SessionManager session parameters & reconnection lifecycle', () {
    late SessionManager sessionManager;
    late TestEdfRecorder testRecorder;
    late TestAcquisitionService testAcq;
    late SettingsService settings;
    late MultiStreamLslService multiLsl;
    late MultiDeviceAcquisitionService multiDevice;
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ccs-session-mgr-test-');
      FileNamingService.configureOutputDirectory(tempDir.path);
      settings = SettingsService();
      sessionManager = SessionManager();
      testRecorder = TestEdfRecorder();
      testAcq = TestAcquisitionService();
      multiLsl = MultiStreamLslService();
      multiDevice = MultiDeviceAcquisitionService();

      sessionManager.update(
        testAcq,
        testRecorder,
        settings,
        multiLsl,
        multiDevice,
      );
    });

    tearDown(() async {
      FileNamingService.configureOutputDirectory(null);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('starts immediately when acquisition is already streaming', () async {
      testAcq.setTestState(AcquisitionState.streaming);

      final customLabels = [
        'Fp1', 'Fp2', 'C1', 'C2', 'TP9( M1)', 'TP10 (M2)',
        'EOG L', 'EMG1', 'EMG 2', 'Ch 10', 'O1', 'Oz', 'O2', 'F7', 'F8', 'T3',
      ];
      final enabledMask = [
        true, true, true, true, true, true,
        true, true, true, false, false, false, false, false, false, false,
      ];

      await sessionManager.startSession(
        subject: 'TEST_SUBJ',
        module: ModuleType.nidra,
        channelCount: 16,
        sampleRate: 250,
        channelLabels: customLabels,
        enabledChannels: enabledMask,
      );

      expect(sessionManager.isRecording, isTrue);
      expect(testRecorder.startedCalls.length, 1);
      final call1 = testRecorder.startedCalls.first;
      expect(call1['channelCount'], 16);
      expect(call1['sampleRate'], 250);
      expect(call1['channelLabels'], customLabels);
      expect(call1['enabledChannels'], enabledMask);
      expect(call1['path'], endsWith('.edf'));
      expect(call1['path'], isNot(contains('_part')));

      await sessionManager.stopSession();
    });

    test(
      'queues session when connecting, starts part 1 with full params on streaming, '
      'and resumes into part 2 retaining full params on reconnect',
      () async {
        // Device is initially connecting (not streaming yet)
        testAcq.setTestState(AcquisitionState.connecting);

        final customLabels = [
          'Fp1', 'Fp2', 'C1', 'C2', 'TP9( M1)', 'TP10 (M2)',
          'EOG L', 'EMG1', 'EMG 2', 'Ch 10', 'O1', 'Oz', 'O2', 'F7', 'F8', 'T3',
        ];
        final enabledMask = [
          true, true, true, true, true, true,
          true, true, true, false, false, false, false, false, false, false,
        ];

        await sessionManager.startSession(
          subject: 'TEST_SUBJ',
          module: ModuleType.nidra,
          channelCount: 16,
          sampleRate: 250,
          channelLabels: customLabels,
          enabledChannels: enabledMask,
        );

        // Should be queued and timer paused without opening recorder yet
        expect(sessionManager.isRecording, isTrue);
        expect(sessionManager.timerPaused, isTrue);
        expect(testRecorder.startedCalls, isEmpty);

        // Now acquisition reaches streaming!
        testAcq.setTestState(AcquisitionState.streaming);
        sessionManager.update(
          testAcq,
          testRecorder,
          settings,
          multiLsl,
          multiDevice,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // First segment must start with the saved 16 channels, 250 Hz, and custom labels!
        expect(testRecorder.startedCalls.length, 1);
        final segment1 = testRecorder.startedCalls[0];
        expect(segment1['channelCount'], 16);
        expect(segment1['sampleRate'], 250);
        expect(segment1['channelLabels'], customLabels);
        expect(segment1['enabledChannels'], enabledMask);
        expect(segment1['path'], endsWith('.edf'));
        expect(segment1['path'], isNot(contains('_part')));

        // Disconnect occurs during recording
        testAcq.setTestState(AcquisitionState.disconnected);
        sessionManager.update(
          testAcq,
          testRecorder,
          settings,
          multiLsl,
          multiDevice,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(sessionManager.timerPaused, isTrue);

        // Reconnect occurs and reaches streaming again
        testAcq.setTestState(AcquisitionState.streaming);
        sessionManager.update(
          testAcq,
          testRecorder,
          settings,
          multiLsl,
          multiDevice,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Next segment must be part 2, with the SAME original 16 channels, 250 Hz, labels, and mask!
        expect(testRecorder.startedCalls.length, 2);
        final segment2 = testRecorder.startedCalls[1];
        expect(segment2['channelCount'], 16);
        expect(segment2['sampleRate'], 250);
        expect(segment2['channelLabels'], customLabels);
        expect(segment2['enabledChannels'], enabledMask);
        expect(segment2['path'], contains('part2.edf'));

        await sessionManager.stopSession();
      },
    );

    test('recordEvent immediately flushes marker to CSV file', () async {
      testAcq.setTestState(AcquisitionState.streaming);
      await sessionManager.startSession(
        subject: 'TEST_CSV',
        module: ModuleType.nidra,
        channelCount: 16,
        sampleRate: 250,
      );

      sessionManager.recordEvent('nidra_stimulus_manual', 40);

      // Verify marker was stored in log
      expect(sessionManager.markerLog.length, 1);
      expect(sessionManager.markerLog.first.value, 'nidra_stimulus_manual');
      expect(sessionManager.markerLog.first.code, 40);

      await sessionManager.stopSession();
    });
  });
}
