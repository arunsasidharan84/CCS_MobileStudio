import 'dart:math';
import 'package:flutter/material.dart';
import 'models/experiment_models.dart';

class StimulusRenderer extends StatelessWidget {
  final TrialPhase phase;
  final TrialPlan? currentTrial;
  final Hemifield? cueHemifield;

  const StimulusRenderer({
    super.key,
    required this.phase,
    this.currentTrial,
    this.cueHemifield,
  });

  static const Color backgroundColor = Color.fromARGB(255, 45, 45, 48);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: backgroundColor,
      width: double.infinity,
      height: double.infinity,
      child: CustomPaint(
        painter: _StimulusPainter(
          phase: phase,
          currentTrial: currentTrial,
          cueHemifield: cueHemifield,
        ),
      ),
    );
  }
}

class _StimulusPainter extends CustomPainter {
  final TrialPhase phase;
  final TrialPlan? currentTrial;
  final Hemifield? cueHemifield;

  _StimulusPainter({
    required this.phase,
    this.currentTrial,
    this.cueHemifield,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = _calculateGeometry(size);

    switch (phase) {
      case TrialPhase.fixation:
      case TrialPhase.maintenance:
        _drawFixation(canvas, geometry);
        break;
      case TrialPhase.cue:
        _drawCue(canvas, geometry);
        break;
      case TrialPhase.encoding:
        _drawFixation(canvas, geometry);
        if (currentTrial != null) {
          _drawStimuli(canvas, currentTrial!.memoryItems, geometry);
        }
        break;
      case TrialPhase.retrieval:
        _drawFixation(canvas, geometry);
        if (currentTrial != null) {
          _drawStimuli(canvas, currentTrial!.testItems, geometry);
        }
        break;
      case TrialPhase.idle:
      case TrialPhase.iti:
      case TrialPhase.finished:
        break;
    }
  }

  _Geometry _calculateGeometry(Size size) {
    final screenWidth = size.width;
    final screenHeight = size.height;

    final fixationX = screenWidth * 0.5;
    final fixationY = screenHeight * 0.5;
    final sideMargin = screenWidth * 0.045;
    final centralGap = screenWidth * 0.105;
    final verticalTop = screenHeight * 0.20;
    final verticalBottom = screenHeight * 0.74;
    final squareSide = min(screenWidth * 0.068, screenHeight * 0.058);

    final leftHemifield = Rect.fromLTRB(
      sideMargin,
      verticalTop,
      fixationX - centralGap,
      verticalBottom,
    );
    final rightHemifield = Rect.fromLTRB(
      fixationX + centralGap,
      verticalTop,
      screenWidth - sideMargin,
      verticalBottom,
    );

    final leftStimulusBox = _centeredBoxIn(leftHemifield, 0.96, 0.72);
    final rightStimulusBox = _centeredBoxIn(rightHemifield, 0.96, 0.72);

    return _Geometry(
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      fixationX: fixationX,
      fixationY: fixationY,
      squareSide: squareSide,
      leftStimulusBox: leftStimulusBox,
      rightStimulusBox: rightStimulusBox,
    );
  }

  Rect _centeredBoxIn(Rect bounds, double widthScale, double heightScale) {
    final boxWidth = bounds.width * widthScale;
    final boxHeight = bounds.height * heightScale;
    final left = bounds.center.dx - boxWidth * 0.5;
    final top = bounds.center.dy - boxHeight * 0.5;
    return Rect.fromLTWH(left, top, boxWidth, boxHeight);
  }

  void _drawFixation(Canvas canvas, _Geometry geometry) {
    final textSize = min(geometry.screenWidth, geometry.screenHeight) * 0.11;
    _drawCenteredText(canvas, '+', geometry.fixationX, geometry.fixationY, textSize);
  }

  void _drawCue(Canvas canvas, _Geometry geometry) {
    final symbol = cueHemifield?.cueSymbol() ?? '';
    final textSize = min(geometry.screenWidth, geometry.screenHeight) * 0.16;
    _drawCenteredText(canvas, symbol, geometry.fixationX, geometry.fixationY, textSize);
  }

  void _drawStimuli(Canvas canvas, List<StimulusItem> items, _Geometry geometry) {
    final borderPaint = Paint()
      ..color = const Color.fromARGB(190, 0, 0, 0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = geometry.squareSide * 0.045;

    for (var item in items) {
      final rect = _rectFor(item, geometry);
      final fillPaint = Paint()
        ..color = item.color
        ..style = PaintingStyle.fill;
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, borderPaint);
    }
  }

  Rect _rectFor(StimulusItem item, _Geometry geometry) {
    final box = item.hemifield == Hemifield.left
        ? geometry.leftStimulusBox
        : geometry.rightStimulusBox;

    final centerX = box.center.dx;
    final centerY = box.center.dy;
    final horizontalRadius = max(0.0, (box.width - geometry.squareSide) * 0.5);
    final verticalRadius = max(0.0, (box.height - geometry.squareSide) * 0.5);
    final halfSide = geometry.squareSide * 0.5;

    final squareCenterX = centerX + item.slot.xFraction * horizontalRadius;
    final squareCenterY = centerY + item.slot.yFraction * verticalRadius;

    final left = (squareCenterX - halfSide).clamp(box.left, box.right - geometry.squareSide);
    final top = (squareCenterY - halfSide).clamp(box.top, box.bottom - geometry.squareSide);
    return Rect.fromLTWH(left, top, geometry.squareSide, geometry.squareSide);
  }

  void _drawCenteredText(Canvas canvas, String text, double centerX, double centerY, double fontSize) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: Colors.white, fontSize: fontSize, height: 1.0),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    final offset = Offset(centerX - textPainter.width * 0.5, centerY - textPainter.height * 0.5);
    textPainter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _StimulusPainter oldDelegate) {
    return phase != oldDelegate.phase ||
        currentTrial != oldDelegate.currentTrial ||
        cueHemifield != oldDelegate.cueHemifield;
  }
}

class _Geometry {
  final double screenWidth;
  final double screenHeight;
  final double fixationX;
  final double fixationY;
  final double squareSide;
  final Rect leftStimulusBox;
  final Rect rightStimulusBox;

  _Geometry({
    required this.screenWidth,
    required this.screenHeight,
    required this.fixationX,
    required this.fixationY,
    required this.squareSide,
    required this.leftStimulusBox,
    required this.rightStimulusBox,
  });
}
