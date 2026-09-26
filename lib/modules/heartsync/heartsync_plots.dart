import 'dart:math';

import 'package:flutter/material.dart';

import 'heartsync_engine.dart';
import 'models.dart';
import 'posthoc_analyzer.dart';

class HeartSyncLivePlot extends StatelessWidget {
  const HeartSyncLivePlot({
    super.key,
    required this.ppg,
    required this.ecg,
    required this.beats,
    required this.markers,
    required this.seconds,
  });

  final List<HeartSyncTracePoint> ppg;
  final List<HeartSyncTracePoint> ecg;
  final List<DateTime> beats;
  final List<HeartSyncTraceMarker> markers;
  final double seconds;

  @override
  Widget build(BuildContext context) => Container(
    height: 230,
    margin: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: const Color(0xFF0F172A),
      border: Border.all(color: Colors.white12),
      borderRadius: BorderRadius.circular(10),
    ),
    child: CustomPaint(
      painter: _LivePainter(
        ppg: ppg,
        ecg: ecg,
        beats: beats,
        markers: markers,
        seconds: seconds,
      ),
      child: const SizedBox.expand(),
    ),
  );
}

class HeartSyncVerificationPlot extends StatelessWidget {
  const HeartSyncVerificationPlot({
    super.key,
    required this.ppg,
    required this.ecg,
    required this.results,
    required this.config,
  });

  final List<CardiacSample> ppg;
  final List<CardiacSample> ecg;
  final List<HeartSyncTrialResult> results;
  final HeartSyncConfig config;

  @override
  Widget build(BuildContext context) {
    final ppgAverage = _averageCycle(
      ppg,
      HeartSyncPostHocAnalyzer.findPeaks(
        ppg,
        config,
        pulseMode: HeartSyncPulseMode.ppg,
      ),
    );
    final ecgAverage = _averageCycle(
      ecg,
      HeartSyncPostHocAnalyzer.findPeaks(
        ecg,
        config,
        pulseMode: HeartSyncPulseMode.ecg,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Beat-aligned verification',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        const Text(
          'Average normalized cardiac cycle with actual post-hoc marker '
          'phase distributions. Vertical dashed lines show configured targets.',
          style: TextStyle(color: Colors.white60, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Container(
          height: 300,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            border: Border.all(color: Colors.white12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: CustomPaint(
            painter: _VerificationPainter(
              ppg: ppgAverage,
              ecg: ecgAverage,
              results: results,
              systolicTarget: config.systolicOffsetPercent,
              diastolicTarget: config.diastolicOffsetPercent,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

class _LivePainter extends CustomPainter {
  _LivePainter({
    required this.ppg,
    required this.ecg,
    required this.beats,
    required this.markers,
    required this.seconds,
  });

  final List<HeartSyncTracePoint> ppg;
  final List<HeartSyncTracePoint> ecg;
  final List<DateTime> beats;
  final List<HeartSyncTraceMarker> markers;
  final double seconds;

  @override
  void paint(Canvas canvas, Size size) {
    final latest = [
      if (ppg.isNotEmpty) ppg.last.timestamp,
      if (ecg.isNotEmpty) ecg.last.timestamp,
    ].fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    if (latest == null) {
      _text(canvas, 'Waiting for PPG / ECG samples…', const Offset(12, 12));
      return;
    }
    final start = latest.subtract(
      Duration(microseconds: (seconds * 1000000).round()),
    );
    final lanes = (ppg.isNotEmpty ? 1 : 0) + (ecg.isNotEmpty ? 1 : 0);
    var lane = 0;
    if (ppg.isNotEmpty) {
      _trace(
        canvas,
        size,
        ppg,
        start,
        latest,
        lane++,
        lanes,
        const Color(0xFF22D3EE),
        'PPG',
      );
    }
    if (ecg.isNotEmpty) {
      _trace(
        canvas,
        size,
        ecg,
        start,
        latest,
        lane,
        lanes,
        const Color(0xFFA78BFA),
        'ECG',
      );
    }
    for (final beat in beats.where((time) => !time.isBefore(start))) {
      final x = _timeX(beat, start, latest, size.width);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = const Color(0x66F43F5E)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(
        Offset(x, 12),
        4,
        Paint()..color = const Color(0xFFF43F5E),
      );
    }
    for (final marker in markers.where(
      (item) => !item.timestamp.isBefore(start),
    )) {
      final x = _timeX(marker.timestamp, start, latest, size.width);
      final color = _markerColor(marker.code);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = color
          ..strokeWidth = 1.5,
      );
      _text(
        canvas,
        '${marker.code}',
        Offset(min(size.width - 24, x + 2), size.height - 18),
        color: color,
      );
    }
    _text(
      canvas,
      '● detected beat',
      const Offset(100, 8),
      color: const Color(0xFFF43F5E),
    );
  }

  void _trace(
    Canvas canvas,
    Size size,
    List<HeartSyncTracePoint> points,
    DateTime start,
    DateTime end,
    int lane,
    int lanes,
    Color color,
    String label,
  ) {
    final visible = points
        .where((point) => !point.timestamp.isBefore(start))
        .toList();
    if (visible.length < 2) return;
    final sorted = visible.map((point) => point.value).toList()..sort();
    final low = sorted[(sorted.length * 0.05).floor()];
    final high = sorted[min(sorted.length - 1, (sorted.length * 0.95).floor())];
    final span = max(1e-9, high - low);
    final laneHeight = size.height / lanes;
    final top = lane * laneHeight;
    final path = Path();
    for (var index = 0; index < visible.length; index++) {
      final point = visible[index];
      final x = _timeX(point.timestamp, start, end, size.width);
      final normalized = ((point.value - low) / span).clamp(0.0, 1.0);
      final y = top + laneHeight * (0.88 - normalized * 0.70);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    _text(canvas, '$label (clean)', Offset(8, top + 8), color: color);
  }

  @override
  bool shouldRepaint(covariant _LivePainter oldDelegate) => true;
}

class _VerificationPainter extends CustomPainter {
  _VerificationPainter({
    required this.ppg,
    required this.ecg,
    required this.results,
    required this.systolicTarget,
    required this.diastolicTarget,
  });

  final List<double> ppg;
  final List<double> ecg;
  final List<HeartSyncTrialResult> results;
  final double systolicTarget;
  final double diastolicTarget;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 42.0;
    const right = 10.0;
    const top = 26.0;
    final waveBottom = size.height * 0.62;
    final plotWidth = size.width - left - right;
    canvas.drawLine(
      Offset(left, waveBottom),
      Offset(size.width - right, waveBottom),
      Paint()..color = Colors.white24,
    );
    for (final percent in [0, 25, 50, 75, 100]) {
      final x = left + plotWidth * percent / 100;
      canvas.drawLine(
        Offset(x, top),
        Offset(x, size.height - 25),
        Paint()..color = Colors.white10,
      );
      _text(canvas, '$percent%', Offset(x - 10, size.height - 20));
    }
    _averagePath(
      canvas,
      ppg,
      left,
      plotWidth,
      top,
      waveBottom,
      const Color(0xFF22D3EE),
      'PPG average',
    );
    _averagePath(
      canvas,
      ecg,
      left,
      plotWidth,
      top,
      waveBottom,
      const Color(0xFFA78BFA),
      'ECG average',
    );
    _target(
      canvas,
      left + plotWidth * systolicTarget / 100,
      top,
      size.height - 25,
      'S target',
    );
    _target(
      canvas,
      left + plotWidth * diastolicTarget / 100,
      top,
      size.height - 25,
      'D target',
    );

    final bins = List.generate(4, (_) => List<int>.filled(20, 0));
    for (final trial in results) {
      final phase = trial.postHocPhasePercent;
      if (phase == null) continue;
      final index = _resultClass(trial);
      bins[index][min(19, (phase / 5).floor())]++;
    }
    final maximum = bins.expand((row) => row).fold<int>(1, max);
    final base = size.height - 27;
    for (var category = 0; category < bins.length; category++) {
      final paint = Paint()
        ..color = _classColor(category).withValues(alpha: 0.72);
      for (var bin = 0; bin < 20; bin++) {
        final height = (bins[category][bin] / maximum) * 55;
        final width = plotWidth / 20 / 4;
        final x = left + bin * plotWidth / 20 + category * width;
        canvas.drawRect(
          Rect.fromLTWH(x, base - height, max(1, width - 0.5), height),
          paint,
        );
      }
    }
    _text(canvas, 'Marker phase distribution', Offset(left, waveBottom + 8));
    _text(
      canvas,
      '1 F-S  2 R-S  11 F-D  12 R-D',
      Offset(left + 155, waveBottom + 8),
    );
  }

  void _averagePath(
    Canvas canvas,
    List<double> values,
    double left,
    double width,
    double top,
    double bottom,
    Color color,
    String label,
  ) {
    if (values.length < 2) return;
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x = left + width * index / (values.length - 1);
      final y = top + (bottom - top) * (0.5 - values[index] * 0.38);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _text(
      canvas,
      label,
      Offset(left + (label.startsWith('ECG') ? 115 : 0), 5),
      color: color,
    );
  }

  void _target(
    Canvas canvas,
    double x,
    double top,
    double bottom,
    String label,
  ) {
    final paint = Paint()
      ..color = Colors.amberAccent.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    for (var y = top; y < bottom; y += 7) {
      canvas.drawLine(Offset(x, y), Offset(x, min(bottom, y + 4)), paint);
    }
    _text(canvas, label, Offset(x + 2, top), color: Colors.amberAccent);
  }

  @override
  bool shouldRepaint(covariant _VerificationPainter oldDelegate) => true;
}

List<double> _averageCycle(
  List<CardiacSample> samples,
  List<DateTime> peaks, {
  int bins = 101,
}) {
  if (samples.length < 3 || peaks.length < 2) return const [];
  final sums = List<double>.filled(bins, 0);
  var used = 0;
  for (var cycle = 0; cycle < peaks.length - 1; cycle++) {
    final start = peaks[cycle];
    final end = peaks[cycle + 1];
    final segment = samples
        .where(
          (sample) =>
              !sample.timestamp.isBefore(start) &&
              !sample.timestamp.isAfter(end),
        )
        .toList();
    if (segment.length < 3) continue;
    final mean =
        segment.map((sample) => sample.value).reduce((a, b) => a + b) /
        segment.length;
    final amplitude = segment
        .map((sample) => (sample.value - mean).abs())
        .fold<double>(1e-9, max);
    var sampleIndex = 0;
    for (var bin = 0; bin < bins; bin++) {
      final target = start.add(
        Duration(
          microseconds:
              (end.difference(start).inMicroseconds * bin / (bins - 1)).round(),
        ),
      );
      while (sampleIndex + 1 < segment.length &&
          (segment[sampleIndex + 1].timestamp.difference(target).abs() <
              segment[sampleIndex].timestamp.difference(target).abs())) {
        sampleIndex++;
      }
      sums[bin] += (segment[sampleIndex].value - mean) / amplitude;
    }
    used++;
  }
  return used == 0
      ? const []
      : sums.map((value) => value / used).toList(growable: false);
}

double _timeX(DateTime time, DateTime start, DateTime end, double width) {
  final total = max(1, end.difference(start).inMicroseconds);
  return (time.difference(start).inMicroseconds / total * width)
      .clamp(0, width)
      .toDouble();
}

int _resultClass(HeartSyncTrialResult trial) =>
    switch ((trial.plan.stimulus, trial.plan.targetPhase)) {
      (HeartSyncStimulusKind.frequent, CardiacPhase.systole) => 0,
      (HeartSyncStimulusKind.rare, CardiacPhase.systole) => 1,
      (HeartSyncStimulusKind.frequent, CardiacPhase.diastole) => 2,
      (HeartSyncStimulusKind.rare, CardiacPhase.diastole) => 3,
      _ => 0,
    };

Color _classColor(int index) => const [
  Color(0xFF60A5FA),
  Color(0xFFF87171),
  Color(0xFF2563EB),
  Color(0xFFDC2626),
][index];
Color _markerColor(int code) => switch (code) {
  1 => const Color(0xFF60A5FA),
  2 => const Color(0xFFF87171),
  11 => const Color(0xFF2563EB),
  12 => const Color(0xFFDC2626),
  _ => Colors.amber,
};

void _text(
  Canvas canvas,
  String text,
  Offset offset, {
  Color color = Colors.white60,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: 11),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, offset);
}
