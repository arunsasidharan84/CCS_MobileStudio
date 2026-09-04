import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_mobile_studio/core/services/file_naming_service.dart';

import 'package:ccs_mobile_studio/core/models/module_type.dart';

void main() {
  test('ModuleType parses persisted study sequence keys', () {
    expect(ModuleType.fromKey('standalone'), ModuleType.standalone);
    expect(ModuleType.fromKey('EEG'), ModuleType.standalone);
    expect(ModuleType.fromKey('NIDRA'), ModuleType.nidra);
    expect(ModuleType.fromKey('angel'), ModuleType.angel);
    expect(ModuleType.fromKey('adaptive_wm'), ModuleType.wm);
    expect(ModuleType.fromKey('heart_sync'), ModuleType.heartsync);
    expect(ModuleType.heartsync.fileTag, 'HEARTSYNC');
  });

  test('recovery keeps subject IDs containing underscores', () {
    expect(
      FileNamingService.subjectFromStem(
        'SITE_01_SUBJECT_7_NIDRA_20260713_220410',
      ),
      'SITE_01_SUBJECT_7',
    );
  });

  test('recovery strips EDF segment suffixes from the session stem', () {
    expect(
      FileNamingService.sessionStemFromFilename(
        'SSA007_NIDRA_20260713_220410_part3.edf',
      ),
      'SSA007_NIDRA_20260713_220410',
    );
  });

  test('recovery strips marker CSV suffix from the session stem', () {
    expect(
      FileNamingService.sessionStemFromFilename(
        'SSA007_NIDRA_20260713_220410_markers.csv',
      ),
      'SSA007_NIDRA_20260713_220410',
    );
  });

  test('device-aware EDF names remain grouped under one session', () {
    final started = DateTime(2026, 7, 29, 12, 56, 26);
    final primary = FileNamingService.edfFilename(
      'testing',
      ModuleType.standalone,
      started,
      deviceName: 'AXXSPU00003',
    );
    final orbit = FileNamingService.streamEdfFilename(
      'testing',
      ModuleType.standalone,
      started,
      '80:E1:27:88:3C',
      deviceName: 'Orbit 3C',
      streamName: 'primary',
    );

    expect(primary, 'testing_EEG_20260729_125626_device-AXXSPU00003.edf');
    expect(
      orbit,
      'testing_EEG_20260729_125626_device-Orbit_3C_stream-primary.edf',
    );
    expect(
      FileNamingService.sessionStemFromFilename(primary),
      'testing_EEG_20260729_125626',
    );
    expect(
      FileNamingService.sessionStemFromFilename(orbit),
      'testing_EEG_20260729_125626',
    );
  });
}
