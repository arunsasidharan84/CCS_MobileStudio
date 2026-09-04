import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Generates a block-level performance summary PDF from an ANGEL ERP session.
///
/// **FIXED ACCURACY & RT FORMULA**:
/// - Checks both `'accuracy'` and `'correct'` field mappings.
/// - Checks both `'rt'` and `'rt_ms'` field mappings.
/// - Correctly computes overall and block-wise accuracy % and reaction times.
class SummaryReportService {
  static Future<String> generate({
    required String participant,
    required List<Map<String, dynamic>> trialLog,
    required DateTime sessionStart,
  }) async {
    final pdf = pw.Document();

    final mainTrials = trialLog.where((r) => r['phase'] == 'main').toList();
    final blocks = <int>{};
    for (final r in mainTrials) {
      final b = r['block'];
      if (b != null) blocks.add(b is int ? b : int.tryParse('$b') ?? 0);
    }
    final sortedBlocks = blocks.toList()..sort();

    final blockStats = <int, _BlockStat>{};
    for (final b in sortedBlocks) {
      final bTrials = mainTrials.where((r) {
        final rb = r['block'];
        return rb != null && (rb is int ? rb : int.tryParse('$rb') ?? -1) == b;
      }).toList();
      blockStats[b] = _computeBlockStat(bTrials, b);
    }

    final overall = _computeBlockStat(mainTrials, -1);

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(36),
          theme: pw.ThemeData.withFont(
            base: pw.Font.helvetica(),
            bold: pw.Font.helveticaBold(),
          ),
        ),
        build: (ctx) => [
          _buildHeader(participant, sessionStart),
          pw.SizedBox(height: 20),
          _buildOverallStats(overall),
          pw.SizedBox(height: 24),
          _buildBlockTable(sortedBlocks, blockStats),
          pw.SizedBox(height: 24),
          _buildAccuracyChart(sortedBlocks, blockStats),
          pw.SizedBox(height: 20),
          _buildRtChart(sortedBlocks, blockStats),
        ],
      ),
    );

    final dir = await getApplicationDocumentsDirectory();
    final dataDir = Directory('${dir.path}/data');
    if (!await dataDir.exists()) await dataDir.create(recursive: true);

    final cleanSubject = participant.trim().replaceAll(
      RegExp(r'[^A-Za-z0-9_-]'),
      '_',
    );
    final stamp = sessionStart.toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final filePath = '${dataDir.path}/${cleanSubject}_summary_$stamp.pdf';

    final file = File(filePath);
    await file.writeAsBytes(await pdf.save());
    debugPrint('[SummaryReport] Saved to $filePath');
    return filePath;
  }

  static _BlockStat _computeBlockStat(
    List<Map<String, dynamic>> trials,
    int block,
  ) {
    if (trials.isEmpty) {
      return _BlockStat(
        block: block,
        total: 0,
        correct: 0,
        missCount: 0,
        rtValues: [],
        accuracy: 0,
        meanRt: 0,
        semRt: 0,
      );
    }

    final activeTrials = trials.where((r) {
      final tt = '${r['trial_type']}'.toLowerCase();
      return tt != 'baseline';
    }).toList();

    int correct = 0;
    int miss = 0;
    final rtValues = <double>[];

    for (final r in activeTrials) {
      // FIXED FIELD MAPPINGS (accuracy / correct, rt / rt_ms)
      final accVal = r['accuracy'] ?? r['correct'];
      final isCorrect =
          accVal == true ||
          accVal == 1 ||
          accVal == '1' ||
          '${accVal}'.toLowerCase() == 'true';

      final rt = r['rt'] ?? r['rt_ms'];
      final rtVal = rt is double
          ? rt
          : (rt is int ? rt.toDouble() : double.tryParse('$rt'));
      final resp = '${r['response']}'.toLowerCase();

      if (resp == 'none' || resp == 'miss' || resp.isEmpty) {
        miss++;
      } else {
        if (isCorrect) correct++;
        if (rtVal != null && rtVal > 0) rtValues.add(rtVal);
      }
    }

    final total = activeTrials.length;
    final accuracy = total > 0 ? correct / total : 0.0;
    final meanRt = rtValues.isEmpty
        ? 0.0
        : rtValues.reduce((a, b) => a + b) / rtValues.length;
    final semRt = rtValues.length > 1
        ? () {
            final variance =
                rtValues
                    .map((v) => (v - meanRt) * (v - meanRt))
                    .reduce((a, b) => a + b) /
                rtValues.length;
            return variance == 0
                ? 0.0
                : (variance.abs().sqrt() / rtValues.length.toDouble().sqrt());
          }()
        : 0.0;

    return _BlockStat(
      block: block,
      total: total,
      correct: correct,
      missCount: miss,
      rtValues: rtValues,
      accuracy: accuracy,
      meanRt: meanRt,
      semRt: semRt,
    );
  }

  static pw.Widget _buildHeader(String participant, DateTime sessionStart) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'ANGEL ERP Session Report',
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              '${sessionStart.day.toString().padLeft(2, '0')}'
              '/${sessionStart.month.toString().padLeft(2, '0')}'
              '/${sessionStart.year}  '
              '${sessionStart.hour.toString().padLeft(2, '0')}'
              ':${sessionStart.minute.toString().padLeft(2, '0')}',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
            ),
          ],
        ),
        pw.Divider(thickness: 1.5, color: PdfColors.teal700),
        pw.SizedBox(height: 4),
        pw.Text(
          'Participant: $participant',
          style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
        ),
      ],
    );
  }

  static pw.Widget _buildOverallStats(_BlockStat overall) {
    final acc = (overall.accuracy * 100).toStringAsFixed(1);
    final rt = overall.meanRt.toStringAsFixed(1);
    final sem = overall.semRt.toStringAsFixed(1);

    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PdfColors.teal50,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
        border: pw.Border.all(color: PdfColors.teal200),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'Overall Performance',
            style: pw.TextStyle(
              fontSize: 14,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.teal900,
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
            children: [
              _statBox('Accuracy', '$acc%', PdfColors.teal700),
              _statBox('Mean RT', '$rt ms', PdfColors.indigo700),
              _statBox('RT SEM', '± $sem ms', PdfColors.grey700),
              _statBox('Trials', '${overall.total}', PdfColors.grey700),
              _statBox('Misses', '${overall.missCount}', PdfColors.red700),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _statBox(String label, String value, PdfColor color) {
    return pw.Column(
      children: [
        pw.Text(
          value,
          style: pw.TextStyle(
            fontSize: 18,
            fontWeight: pw.FontWeight.bold,
            color: color,
          ),
        ),
        pw.Text(
          label,
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
        ),
      ],
    );
  }

  static pw.Widget _buildBlockTable(
    List<int> blocks,
    Map<int, _BlockStat> stats,
  ) {
    final headers = [
      'Block',
      'Trials',
      'Correct',
      'Misses',
      'Accuracy %',
      'Mean RT (ms)',
      'SEM RT',
    ];
    final rows = blocks.map((b) {
      final s = stats[b]!;
      return [
        '$b',
        '${s.total}',
        '${s.correct}',
        '${s.missCount}',
        '${(s.accuracy * 100).toStringAsFixed(1)}%',
        s.meanRt.toStringAsFixed(1),
        '±${s.semRt.toStringAsFixed(1)}',
      ];
    }).toList();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Block-wise Performance',
          style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 6),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
          columnWidths: {
            0: const pw.FixedColumnWidth(40),
            1: const pw.FixedColumnWidth(40),
            2: const pw.FixedColumnWidth(50),
            3: const pw.FixedColumnWidth(45),
            4: const pw.FixedColumnWidth(70),
            5: const pw.FixedColumnWidth(80),
            6: const pw.FixedColumnWidth(55),
          },
          children: [
            pw.TableRow(
              decoration: const pw.BoxDecoration(color: PdfColors.teal700),
              children: headers
                  .map(
                    (h) => pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 5,
                      ),
                      child: pw.Text(
                        h,
                        style: pw.TextStyle(
                          color: PdfColors.white,
                          fontWeight: pw.FontWeight.bold,
                          fontSize: 9,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
            ...rows.asMap().entries.map((entry) {
              final isEven = entry.key.isEven;
              return pw.TableRow(
                decoration: pw.BoxDecoration(
                  color: isEven ? PdfColors.white : PdfColors.grey100,
                ),
                children: entry.value
                    .map(
                      (cell) => pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        child: pw.Text(
                          cell,
                          style: const pw.TextStyle(fontSize: 9),
                        ),
                      ),
                    )
                    .toList(),
              );
            }),
          ],
        ),
      ],
    );
  }

  static pw.Widget _buildAccuracyChart(
    List<int> blocks,
    Map<int, _BlockStat> stats,
  ) {
    if (blocks.isEmpty) return pw.SizedBox();
    final maxH = 120.0;

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Accuracy per Block (%)',
          style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 6),
        pw.SizedBox(
          height: maxH + 30,
          child: pw.CustomPaint(
            size: const PdfPoint(420, 150),
            painter: (canvas, size) {
              _drawLineChart(
                canvas: canvas,
                size: size,
                blocks: blocks,
                values: blocks.map((b) => stats[b]!.accuracy * 100).toList(),
                sems: blocks.map((b) => stats[b]!.semRt * 0).toList(),
                color: PdfColors.teal700,
                yMax: 100,
                yLabel: '%',
              );
            },
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildRtChart(List<int> blocks, Map<int, _BlockStat> stats) {
    if (blocks.isEmpty) return pw.SizedBox();
    final maxRt = blocks
        .map((b) => stats[b]!.meanRt + stats[b]!.semRt)
        .fold(0.0, (a, b) => a > b ? a : b);
    final yMax = (maxRt * 1.2).clamp(200.0, 2000.0);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Mean Reaction Time per Block (ms)',
          style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 6),
        pw.SizedBox(
          height: 150,
          child: pw.CustomPaint(
            size: const PdfPoint(420, 150),
            painter: (canvas, size) {
              _drawLineChart(
                canvas: canvas,
                size: size,
                blocks: blocks,
                values: blocks.map((b) => stats[b]!.meanRt).toList(),
                sems: blocks.map((b) => stats[b]!.semRt).toList(),
                color: PdfColors.indigo700,
                yMax: yMax,
                yLabel: 'ms',
              );
            },
          ),
        ),
      ],
    );
  }

  static void _drawLineChart({
    required PdfGraphics canvas,
    required PdfPoint size,
    required List<int> blocks,
    required List<double> values,
    required List<double> sems,
    required PdfColor color,
    required double yMax,
    required String yLabel,
  }) {
    if (blocks.isEmpty) return;
    const leftPad = 40.0;
    const bottomPad = 25.0;
    final w = size.x - leftPad - 10;
    final h = size.y - bottomPad - 10;

    canvas.setStrokeColor(PdfColors.grey400);
    canvas.setLineWidth(0.5);
    canvas.moveTo(leftPad, 10);
    canvas.lineTo(leftPad, h + 10);
    canvas.lineTo(leftPad + w, h + 10);
    canvas.strokePath();

    for (var i = 0; i <= 4; i++) {
      final y = 10 + h * (1 - i / 4);
      canvas.setStrokeColor(PdfColors.grey200);
      canvas.moveTo(leftPad, y);
      canvas.lineTo(leftPad + w, y);
      canvas.strokePath();
    }

    if (sems.any((s) => s > 0)) {
      canvas.setFillColor(PdfColor.fromHex('#0D7377').shade(0.15));
      final xStep = w / (blocks.length - 1 < 1 ? 1 : blocks.length - 1);
      for (var i = 0; i < blocks.length - 1; i++) {
        final x1 = leftPad + i * xStep;
        final x2 = leftPad + (i + 1) * xStep;
        final y1top =
            10 + h * (1 - (values[i] + sems[i]).clamp(0, yMax) / yMax);
        final y1bot =
            10 + h * (1 - (values[i] - sems[i]).clamp(0, yMax) / yMax);
        final y2top =
            10 + h * (1 - (values[i + 1] + sems[i + 1]).clamp(0, yMax) / yMax);
        final y2bot =
            10 + h * (1 - (values[i + 1] - sems[i + 1]).clamp(0, yMax) / yMax);
        canvas.moveTo(x1, y1top);
        canvas.lineTo(x2, y2top);
        canvas.lineTo(x2, y2bot);
        canvas.lineTo(x1, y1bot);
        canvas.closePath();
        canvas.fillPath();
      }
    }

    canvas.setStrokeColor(color);
    canvas.setLineWidth(1.5);
    final xStep = w / (blocks.length - 1 < 1 ? 1 : blocks.length - 1);
    for (var i = 0; i < blocks.length; i++) {
      final x = leftPad + i * xStep;
      final y = 10 + h * (1 - values[i].clamp(0, yMax) / yMax);
      if (i == 0) {
        canvas.moveTo(x, y);
      } else {
        canvas.lineTo(x, y);
      }
    }
    canvas.strokePath();

    canvas.setFillColor(color);
    for (var i = 0; i < blocks.length; i++) {
      final x = leftPad + i * xStep;
      final y = 10 + h * (1 - values[i].clamp(0, yMax) / yMax);
      canvas.drawEllipse(x, y, 2.5, 2.5);
      canvas.fillPath();
    }
  }
}

class _BlockStat {
  _BlockStat({
    required this.block,
    required this.total,
    required this.correct,
    required this.missCount,
    required this.rtValues,
    required this.accuracy,
    required this.meanRt,
    required this.semRt,
  });
  final int block;
  final int total;
  final int correct;
  final int missCount;
  final List<double> rtValues;
  final double accuracy;
  final double meanRt;
  final double semRt;
}

extension on double {
  double sqrt() => this == 0 ? 0 : (this > 0 ? _sqrt(this) : 0);
  static double _sqrt(double x) {
    double z = x;
    for (int i = 0; i < 50; i++) {
      z -= (z * z - x) / (2 * z);
    }
    return z;
  }
}
