import 'package:flutter_test/flutter_test.dart';

import 'package:ccs_mobile_studio/modules/adaptive_wm/models/experiment_models.dart';
import 'package:ccs_mobile_studio/modules/adaptive_wm/wm_summary_service.dart';

void main() {
  test('full Adaptive WM trial log paginates into a valid PDF', () async {
    final records = List.generate(60, (index) {
      final trial = index + 1;
      final start = index * 5000;
      return TrialRecord(
        trialNumber: trial,
        setSize: 2 + (index % 6),
        cuedHemifield: index.isEven ? Hemifield.left : Hemifield.right,
        isMatchTrial: index.isEven,
        userResponse: index.isEven
            ? MatchDecision.match
            : MatchDecision.mismatch,
        accuracy: 1,
        reactionTimeMs: 650,
        trialStartGlobalMs: start,
        fixationOnsetGlobalMs: start + 300,
        cueOnsetGlobalMs: start + 800,
        encodingOnsetGlobalMs: start + 1100,
        maintenanceOnsetGlobalMs: start + 1400,
        retrievalOnsetGlobalMs: start + 2400,
        responseOnsetGlobalMs: start + 3050,
        trialEndGlobalMs: start + 3100,
      );
    });

    final document = WmSummaryService.buildDocument(
      participant: 'SSA007',
      records: records,
      sessionStart: DateTime(2026, 7, 18, 12),
    );
    final bytes = await document.save();

    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });
}
