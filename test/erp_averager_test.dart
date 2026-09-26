import 'package:ccs_mobile_studio/core/models/eeg_sample.dart';
import 'package:ccs_mobile_studio/modules/generic_erp/erp_averager.dart';
import 'package:flutter_test/flutter_test.dart';

EegSample sample(double value) => EegSample(
  channels: [value],
  sampleRate: 10,
  timestamp: DateTime(2026),
  source: 'test',
);

void main() {
  test('ERP averager captures baseline-corrected stimulus epochs', () {
    final averager = ErpAverager(sampleRate: 10);
    averager.push(sample(4));
    averager.mark('Rare');
    for (var index = 0; index < 8; index++) {
      averager.push(sample(6.0 + index));
    }

    expect(averager.counts['Rare'], 1);
    expect(averager.averages['Rare']!.first, 0);
    expect(averager.averages['Rare']![1], 2);
  });
}
