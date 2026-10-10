import '../../core/models/eeg_sample.dart';
import '../../core/models/signal_stream_sample.dart';
import '../../core/models/device_profile.dart';
import '../heartsync/cardiac_detector.dart';
import '../heartsync/models.dart';
import 'hep_engine.dart';

/// Orbit's native 62.5 Hz PPG events anchor both 250 Hz frontal EEG channels.
/// Display PPG (interpolated to EEG rate) is deliberately ignored.
class OrbitHepSession {
  OrbitHepSession({required this.deviceProfileId, required this.ppgStreamId});
  final String deviceProfileId, ppgStreamId;
  final List<HepEngine> channels = [
    HepEngine(250, externalEvents: true),
    HepEngine(250, externalEvents: true),
  ];
  CardiacDetector _detector = CardiacDetector(const HeartSyncConfig());
  DateTime? lastEeg, lastPpg;
  String? error;
  int pulseCount = 0;
  final List<DateTime> pulseTimes = [];
  void addEeg(EegSample s) {
    if (s.source != 'Orbit') return;
    if (s.sampleRate != 250 || s.channels.length < 2) {
      error = 'Orbit EEG configuration changed. Restart the session.';
      return;
    }
    if (lastEeg != null && !s.timestamp.isAfter(lastEeg!)) return;
    final previousGaps = channels.first.gaps;
    for (var i = 0; i < 2; i++) {
      channels[i].add(s.channels[i], 0, s.timestamp);
    }
    if (channels.first.gaps != previousGaps) {
      _detector = CardiacDetector(const HeartSyncConfig());
    }
    lastEeg = s.timestamp;
  }

  void addPpg(SignalStreamSample s) {
    if (s.deviceProfileId != deviceProfileId || s.streamId != ppgStreamId) {
      return;
    }
    if (s.signalType != SignalType.ppg ||
        s.sampleRate != 62.5 ||
        s.channels.length != 1) {
      error = 'Orbit PPG configuration changed. Restart the session.';
      return;
    }
    if (lastPpg != null && !s.timestamp.isAfter(lastPpg!)) return;
    final gap =
        lastPpg != null &&
        s.timestamp.difference(lastPpg!).inMicroseconds > 48000;
    if (gap || !s.channels.first.isFinite) {
      _detector = CardiacDetector(const HeartSyncConfig());
      for (final e in channels) {
        e.cardiacGap();
      }
    }
    lastPpg = s.timestamp;
    if (!s.channels.first.isFinite) return;
    final at = _detector.add(CardiacSample(s.timestamp, s.channels.first));
    if (at != null) {
      pulseCount++;
      pulseTimes.add(at);
      for (final e in channels) {
        e.addCardiacEvent(at);
      }
    }
  }

  String quality(DateTime now) {
    if (error != null) return error!;
    if (lastEeg == null || now.difference(lastEeg!).inSeconds > 3) {
      return 'Waiting for Orbit EEG';
    }
    if (lastPpg == null || now.difference(lastPpg!).inSeconds > 3) {
      return 'Waiting for native Orbit PPG';
    }
    return 'AF7: ${channels[0].quality} • AF8: ${channels[1].quality}';
  }

  void finish() {
    for (final e in channels) {
      e.finish();
    }
  }
}
