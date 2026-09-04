import 'dart:io';

import 'package:ccs_mobile_studio/core/services/file_naming_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports session files below the configured output folder', () async {
    final temp = await Directory.systemTemp.createTemp('ccs-output-test-');
    addTearDown(() async {
      FileNamingService.configureOutputDirectory(null);
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final output = Directory('${temp.path}/chosen-output');
    FileNamingService.configureOutputDirectory(output.path);
    final source = File('${temp.path}/S007_ANGEL_20260813_120000.csv');
    await source.writeAsString('trial,response\n1,correct\n');

    final exported = await FileNamingService.exportToDownloads(source.path);

    expect(
      exported,
      '${output.path}/S007/S007_ANGEL_20260813_120000/'
      'S007_ANGEL_20260813_120000.csv',
    );
    expect(await File(exported!).readAsString(), await source.readAsString());
  });
}
