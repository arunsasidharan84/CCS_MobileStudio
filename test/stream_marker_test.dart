import 'package:ccs_mobile_studio/core/models/stream_marker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('numeric LSL markers retain their EDF code', () {
    expect(StreamMarker.codeForValue('10'), 10);
    expect(StreamMarker.codeForValue('-3'), -3);
  });

  test('text LSL markers map to stable non-zero EDF codes', () {
    final first = StreamMarker.codeForValue('stimulus_onset');
    final second = StreamMarker.codeForValue('stimulus_onset');
    expect(first, second);
    expect(first, inInclusiveRange(1, 32766));
  });
}
