import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ccs_mobile_studio/core/services/file_naming_service.dart';
import 'package:ccs_mobile_studio/core/services/session_manager.dart';
import 'package:ccs_mobile_studio/modules/hrd/hrd_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_mobile_studio/core/models/module_type.dart';
import 'package:ccs_mobile_studio/modules/hrd/hrd_models.dart';
import 'package:ccs_mobile_studio/modules/hrd/hrd_native.dart';
import 'package:ccs_mobile_studio/modules/hrd/hrd_report.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'catch and timeout responses checkpoint without updating Psi; valid trial completes',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'),
        (_) async => 1,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global/events'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'),
        (call) async {
          if (call.method == 'create') {
            final id = (call.arguments as Map)['playerId'];
            messenger.setMockMethodCallHandler(
              MethodChannel('xyz.luan/audioplayers/events/$id'),
              (_) async => null,
            );
          }
          return 1;
        },
      );
      final folder = await Directory.systemTemp.createTemp('hrd_lifecycle');
      FileNamingService.configureOutputDirectory(folder.path);
      final sessions = SessionManager();
      final engine = HrdEngine(
        config: const HrdConfig(trials: 3, catchTrials: 1, record: false),
        subject: 'S01',
        sessions: sessions,
        streams: [],
      );
      try {
        await engine.start();
        for (final response in <int?>[1, null, 1]) {
          engine.deadline?.cancel();
          engine.phase = HrdPhase.response;
          engine.hr = 72;
          engine.delta = 10;
          engine.presented = 82;
          engine.reactionClock
            ..reset()
            ..start();
          await engine.answer(response);
        }
        expect(engine.rows.length, 3);
        expect(engine.history, [
          [10.0, 1.0],
        ]);
        expect(engine.rows[1]['SubjResponse'], isNull);
        expect(engine.rows[1]['SubjAccuracy'], isNull);
        expect(engine.phase, HrdPhase.complete);
        final checkpoint =
            jsonDecode(
                  await File(
                    engine.csvPath!.replaceFirst('.csv', '.json'),
                  ).readAsString(),
                )
                as Map;
        expect(checkpoint['complete'], true);
        expect((checkpoint['history'] as List).length, 1);
        await engine.stop();
        expect(engine.phase, HrdPhase.stopped);
      } finally {
        engine.dispose();
        sessions.dispose();
        await Future<void>.delayed(Duration.zero);
        FileNamingService.configureOutputDirectory(null);
        await folder.delete(recursive: true);
      }
    },
    skip: !File('rust/target/debug/libtrain_nidra_core.dylib').existsSync(),
  );

  test('HRD is a distinct persisted research module', () {
    expect(ModuleType.fromKey('HRD'), ModuleType.hrd);
    expect(ModuleType.hrd.fileTag, 'HRD');
  });
  test(
    'catch placement follows source rules, including dense catch schedules',
    () {
      for (var total = 1; total <= 30; total++) {
        for (var count = 0; count <= total; count++) {
          final plan = hrdCatchPlan(total, count, Random(42));
          expect(plan.where((v) => v).length, count);
          if (count > 0) expect(plan.first, true);
          if (count > 0 && count - 1 <= total - max(1, total ~/ 2)) {
            for (var i = 1; i < max(1, total ~/ 2); i++) {
              expect(plan[i], false);
            }
          }
        }
      }
    },
  );
  test('rate clamping and Python half-step ties are preserved', () {
    expect(hrdPresentedRate(10, -40), 15);
    expect(hrdPresentedRate(199, 40), 199.5);
    expect(hrdPresentedRate(60.25, 0), 60);
    expect(hrdPresentedRate(60.75, 0), 61);
  });
  test('invalid schedules are rejected before a session starts', () {
    expect(
      () => const HrdConfig(trials: 2, catchTrials: 3).validate(),
      throwsArgumentError,
    );
    expect(
      () => const HrdConfig(epochSeconds: 0).validate(),
      throwsArgumentError,
    );
  });
  test(
    'Rust FFI works through a background isolate for PPG and ECG',
    () async {
      for (final ecg in [false, true]) {
        final fs = ecg ? 250.0 : 62.5;
        final sim = await compute(hrdCompute, <String, Object>{
          'simulation': true,
          'sampleRate': fs,
          'seconds': 16.0,
          'ecg': ecg,
        });
        final result = await compute(hrdCompute, <String, Object>{
          'history': <List<double>>[],
          'samples': sim['samples']!,
          'sampleRate': fs,
          'ecg': ecg,
        });
        expect((result['stats'] as List<double>)[0], closeTo(72, 1));
        expect(
          (result['peaks'] as List<double>).where((v) => v == 1).length,
          greaterThan(15),
        );
        expect(result['delta'], -2.5);
        expect(
          (result['estimate'] as List<double>).every((v) => v.isNaN),
          true,
        );
      }
    },
    skip: !File('rust/target/debug/libtrain_nidra_core.dylib').existsSync(),
  );
  test(
    'native audio emits source pulse pattern and a valid WAV',
    () {
      final result = hrdCompute(<String, Object>{
        'history': <List<double>>[],
        'bpm': 60.0,
        'seconds': 11.0,
      });
      final bytes = result['audio'] as Uint8List;
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(bytes.length, 44 + 44100 * 11 * 2);
    },
    skip: !File('rust/target/debug/libtrain_nidra_core.dylib').existsSync(),
  );
  test(
    'Dart report includes source-compatible behavioral and signal exports',
    () async {
      final folder = await Directory.systemTemp.createTemp('hrd_report_test');
      try {
        final rows = <Map<String, Object?>>[
          {
            'Trial': 1,
            'TrialType': 'catch',
            'ActualRate': 72.0,
            'PresentedRate': 82.0,
            'PsiDeltaRate': 10.0,
            'SubjResponse': 1,
            'ResponseTime': 0.7,
            'SubjRating': null,
            'EstimatedRateMean': double.nan,
          },
        ];
        final snapshotPath = '${folder.path}/task_trial0001.json';
        await File(snapshotPath).writeAsString(
          jsonEncode({
            'trial': 1,
            'signal': 'PPG',
            'source': 'simulation',
            'sampleRate': 62.5,
            'cleaned': List.generate(200, (i) => sin(i / 8)),
            'peaks': List.generate(200, (i) => i % 50 == 12 ? 1 : 0),
            'rates': List.filled(200, 72),
            'stats': [72, 0, 0, 0, 4],
          }),
        );
        final paths = await compute(writeHrdReportRequest, <String, Object>{
          'csvPath': '${folder.path}/task.csv',
          'rows': rows,
          'snapshots': [snapshotPath],
          'subject': 'S01',
        });
        expect(paths.length, 2);
        final review = Platform.environment['HRD_REVIEW_OUTPUT'];
        if (review != null) {
          await Directory(review).create(recursive: true);
          for (final path in paths) {
            await File(path).copy('$review/${path.split('/').last}');
          }
        }

        expect(await File(paths.last).length(), greaterThan(100));
        expect(
          await File(paths.first).readAsString(),
          contains('Actual and presented'),
        );
      } finally {
        await folder.delete(recursive: true);
      }
    },
  );
}
