import 'package:flutter/material.dart';

/// Custom painter for fNIRS data (HbO in red, HbR in blue, HbT in purple).
/// Groups channel pairs and renders each as a separate trace with auto-scaling.
class NirsWaveformPainter extends CustomPainter {
  NirsWaveformPainter({
    required this.buffers,
    required this.channelNames,
    required this.hiddenChannels,
  });

  final List<List<double>> buffers;
  final List<String> channelNames;
  final Set<int> hiddenChannels;

  static const Color _hboColor = Color(0xFFFF6B6B); // red — oxygenated Hb
  static const Color _hbrColor = Color(0xFF6B9FFF); // blue — deoxygenated Hb
  static const Color _hbtColor = Color(0xFFB57BFF); // purple — total Hb

  @override
  void paint(Canvas canvas, Size size) {
    final visibleIndices = List.generate(
      channelNames.length,
      (i) => i,
    ).where((i) => !hiddenChannels.contains(i)).toList();
    if (visibleIndices.isEmpty) return;

    final n = visibleIndices.length;
    final rowH = size.height / n;
    const hPad = 8.0;
    const vPad = 6.0;

    // Background grid lines
    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.05)
      ..strokeWidth = 0.5;

    for (var i = 0; i <= n; i++) {
      final y = i * rowH;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Channel traces
    for (var row = 0; row < visibleIndices.length; row++) {
      final ch = visibleIndices[row];
      if (ch >= buffers.length) continue;
      final buf = buffers[ch];
      if (buf.isEmpty) continue;

      final top = row * rowH + vPad;
      final bot = (row + 1) * rowH - vPad;
      final mid = (top + bot) / 2;
      final amplitude = (bot - top) / 2;

      // Auto-scale: find range of current buffer
      double minV = buf.reduce((a, b) => a < b ? a : b);
      double maxV = buf.reduce((a, b) => a > b ? a : b);
      final range = (maxV - minV).abs();
      if (range < 1e-6) {
        minV -= 0.5;
        maxV += 0.5;
      }
      final scale = (amplitude * 0.9) / ((maxV - minV) / 2);

      // Determine color by channel name
      final name = ch < channelNames.length ? channelNames[ch] : '';
      final color = name.contains('HbT')
          ? _hbtColor
          : name.contains('HbR')
          ? _hbrColor
          : _hboColor;

      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;

      final pts = buf.length;
      final xStep = (size.width - hPad * 2) / (pts - 1 < 1 ? 1 : pts - 1);
      final path = Path();

      for (var i = 0; i < pts; i++) {
        final x = hPad + i * xStep;
        final normalized = (buf[i] - (minV + maxV) / 2);
        final y = mid - normalized * scale;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);

      // Channel label
      final label = name.isNotEmpty ? name : 'CH${ch + 1}';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: color.withOpacity(0.8),
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(hPad, top + 2));

      // Value label (latest value)
      final latestVal = buf.last;
      final valTp = TextPainter(
        text: TextSpan(
          text: latestVal.toStringAsFixed(2),
          style: TextStyle(color: color.withOpacity(0.7), fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      valTp.paint(canvas, Offset(size.width - valTp.width - hPad, top + 2));
    }
  }

  @override
  bool shouldRepaint(NirsWaveformPainter old) => true;
}
