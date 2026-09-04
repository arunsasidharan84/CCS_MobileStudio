import 'package:ccs_mobile_studio/core/models/sleep_score.dart';
import 'package:ccs_mobile_studio/core/services/alert_service.dart';
import 'package:ccs_mobile_studio/modules/nidra/auditory_stim_service.dart';
import 'package:flutter_test/flutter_test.dart';

SleepScoreResult score(
  SleepStage stage, {
  double n3Probability = 0.9,
  double artifactRatio = 0,
}) => SleepScoreResult(
  stage: stage,
  confidence: 0.9,
  epochIndex: 0,
  deltaPower: 1,
  thetaPower: 1,
  alphaPower: 1,
  betaPower: 1,
  artifactRatio: artifactRatio,
  probWake: stage == SleepStage.wake ? 0.9 : 0.02,
  probN1: 0.02,
  probN2: 0.03,
  probN3: n3Probability,
  probREM: 0.03,
);

void configureManual(AuditoryStimService service) {
  service.configure(
    enabled: true,
    targetStage: SleepStage.n3,
    stimType: 'beep',
    toneFrequencyHz: 1000,
    toneDurationMs: 300,
    audioFilePath: '',
    volume: 0.8,
    minProbability: 0.5,
    stableDurationSecs: 5,
    maxDurationSecs: 10,
    intervalSecs: 2,
    refractorySecs: 300,
    mode: 'manual',
    notifyBeep: false,
    notifyFlash: true,
    notificationIntervalSecs: 5,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('manual guidance times a target condition and waits for snooze', (
    tester,
  ) async {
    var now = DateTime(2026);
    final service = AuditoryStimService(
      alertService: AlertService(),
      now: () => now,
    );
    configureManual(service);

    service.onNewScore(score(SleepStage.n3));
    expect(service.conditionActive, isTrue);
    expect(service.conditionMet, isFalse);

    now = now.add(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
    expect(service.conditionMet, isTrue);
    expect(service.notificationActive, isTrue);
    expect(service.isStimulating, isFalse);

    service.snooze();
    expect(service.conditionActive, isFalse);
    expect(service.notificationActive, isFalse);
    expect(service.refractoryRemainingSecs, greaterThan(290));
    service.dispose();
  });

  testWidgets('stage loss and poor signal cancel an active condition', (
    tester,
  ) async {
    final service = AuditoryStimService(
      alertService: AlertService(),
      now: () => DateTime(2026),
    );
    configureManual(service);

    service.onNewScore(score(SleepStage.n3));
    expect(service.conditionActive, isTrue);
    service.onNewScore(score(SleepStage.wake));
    expect(service.conditionActive, isFalse);

    service.onNewScore(score(SleepStage.n3));
    expect(service.conditionActive, isTrue);
    service.onNewScore(score(SleepStage.n3, artifactRatio: 0.8));
    expect(service.conditionActive, isFalse);
    expect(service.statusText, contains('Poor signal'));
    service.dispose();
  });
}
