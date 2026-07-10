import 'package:flutter_test/flutter_test.dart';

import 'package:ccs_mobile_studio/core/models/module_type.dart';

void main() {
  test('ModuleType parses persisted study sequence keys', () {
    expect(ModuleType.fromKey('standalone'), ModuleType.standalone);
    expect(ModuleType.fromKey('EEG'), ModuleType.standalone);
    expect(ModuleType.fromKey('NIDRA'), ModuleType.nidra);
    expect(ModuleType.fromKey('angel'), ModuleType.angel);
    expect(ModuleType.fromKey('adaptive_wm'), ModuleType.wm);
  });
}
