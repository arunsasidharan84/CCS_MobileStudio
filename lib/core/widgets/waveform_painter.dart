import 'dart:math';
import 'package:flutter/material.dart';

import '../models/stream_marker.dart';

/// Custom painter for multi-channel EEG waveforms.
/// Supports stacked (separate lanes) or overlaid viewing, autoscale vs fixed gain,
/// custom channel labels, and grid rendering.
class WaveformPainter extends CustomPainter {
  const WaveformPainter({
    required this.channels,
    required this.visibleChannels,
    required this.stacked,
    required this.selectedChannel,
    required this.gain,
    required this.sampleRate,
    required this.durationSeconds,
    required this.autoscale,
    this.channelLabels,
    this.channelScaleFactors,
    this.markers = const [],
    this.traceColor,
    this.strokeWidth = 1.5,
    this.now,
  });

  final List<List<double>> channels;
  final List<bool> visibleChannels;
  final bool stacked;
  final int selectedChannel;
  final double gain;
  final double sampleRate;
  final int durationSeconds;
  final bool autoscale;
  final List<String>? channelLabels;
  final List<double>? channelScaleFactors;
  final List<StreamMarker> markers;
  final Color? traceColor;
  final double strokeWidth;
  final DateTime? now;

  static const colors = [
    Color(0xFF14B8A6), // Teal
    Color(0xFF3B82F6), // Blue
    Color(0xFFF87171), // Coral
    Color(0xFFFBBF24), // Amber
    Color(0xFF8B5CF6), // Purple
    Color(0xFF10B981), // Emerald
    Color(0xFFEC4899), // Pink
    Color(0xFF06B6D4), // Cyan
  ];

  static double canvasHeightForChannels({
    required int channelCount,
    required double availableHeight,
    double minimumLaneHeight = 64.0,
  }) {
    return max(availableHeight, max(1, channelCount) * minimumLaneHeight);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Draw background grid
    final grid = Paint()
      ..color = const Color(0xFF334155).withValues(alpha: 0.4)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var i = 1; i < 8; i++) {
      final x = size.width * i / 8;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }

    final indices = stacked
        ? [
            for (var i = 0; i < channels.length; i++)
              if (i < visibleChannels.length && visibleChannels[i]) i,
          ]
        : [selectedChannel.clamp(0, max(0, channels.length - 1)).toInt()];

    if (indices.isEmpty) return;
    final points = max(2, (sampleRate * durationSeconds).round());
    final laneHeight = size.height / indices.length;

    for (var lane = 0; lane < indices.length; lane++) {
      final channel = indices[lane];
      if (channel >= channels.length) continue;
      final data = channels[channel];
      if (data.length < 2) continue;

      final start = max(0, data.length - points);
      final visible = data.sublist(start);
      final mean = visible.reduce((a, b) => a + b) / visible.length;

      final double scaleFactor;
      if (channelScaleFactors != null &&
          channel < channelScaleFactors!.length) {
        scaleFactor = max(0.000001, channelScaleFactors![channel]);
      } else if (autoscale) {
        scaleFactor = max(
          20.0,
          visible.map((v) => (v - mean).abs()).reduce(max),
        );
      } else {
        // Fixed scale: 150 uV full-scale height per lane
        scaleFactor = 150.0;
      }

      final centerY = laneHeight * (lane + 0.5);
      final path = Path();
      for (var i = 0; i < visible.length; i++) {
        final x = i * size.width / max(1, points - 1);
        final y =
            (centerY -
                    ((visible[i] - mean) / scaleFactor) *
                        laneHeight *
                        0.42 *
                        gain)
                .clamp(0.0, size.height);
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }

      final color = traceColor ?? colors[channel % colors.length];
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );

      final labelText = channelLabels != null && channel < channelLabels!.length
          ? channelLabels![channel]
          : 'Ch ${channel + 1}';

      final label = TextPainter(
        text: TextSpan(
          text: labelText,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(6, centerY - label.height - 3));
    }

    _paintMarkers(canvas, size);
  }

  void _paintMarkers(Canvas canvas, Size size) {
    if (markers.isEmpty || durationSeconds <= 0) return;
    final reference = now ?? DateTime.now();
    for (final marker in markers) {
      final age = reference.difference(marker.receivedAt).inMicroseconds / 1e6;
      if (age < -0.25 || age > durationSeconds) continue;
      final x = (size.width * (1 - age / durationSeconds)).clamp(
        0.0,
        size.width,
      );
      final paint = Paint()
        ..color = const Color(0xFFFFB74D)
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      final label = TextPainter(
        text: TextSpan(
          text: '${marker.value} (${marker.code})',
          style: const TextStyle(
            color: Color(0xFFFFD180),
            fontSize: 9,
            fontWeight: FontWeight.w700,
            backgroundColor: Color(0xB3111827),
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 120);
      label.paint(
        canvas,
        Offset((x + 3).clamp(0, size.width - label.width), 3),
      );
    }
  }

  @override
  bool shouldRepaint(covariant WaveformPainter oldDelegate) => true;
}
