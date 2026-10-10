import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

Future<List<String>> writeHrdReportRequest(Map<String, Object> request) =>
    writeHrdReport(
      request['csvPath'] as String,
      request['rows'] as List<Map<String, Object?>>,
      request['snapshots'] as List<String>,
      request['subject'] as String,
    );

/// Visualization and document layout stay in Dart; numerical analysis is native.
Future<List<String>> writeHrdReport(
  String csvPath,
  List<Map<String, Object?>> rows,
  List<String> snapshots,
  String subject,
) async {
  if (rows.isEmpty) return [];
  final doc = pw.Document();
  final summary = hrdSummarySvg(rows);
  final svgPath = csvPath.replaceFirst('.csv', '_summary.svg');
  await File(svgPath).writeAsString(summary, flush: true);
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Header(level: 0, text: 'Heart Rate Detection - $subject'),
          pw.Text(
            'Response mode: ${rows.first['ResponseMode'] ?? 'buttons (legacy)'}',
          ),
          pw.Text(
            '${rows.length} completed trials. Red: faster; blue: slower; grey: catch/no response. Green: posterior mean and SD/2 bounds.',
          ),
          pw.SizedBox(height: 20),
          pw.SvgImage(svg: summary),
          pw.SizedBox(height: 20),
          pw.Text(
            'Missed responses and catch trials do not update the posterior. Bounds reproduce the source definition (mean +/- SD/2); they are not a credible interval.',
          ),
        ],
      ),
    ),
  );
  for (final path in snapshots) {
    final snap =
        jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    final index = (snap['trial'] as int) - 1;
    if (index >= rows.length) continue;
    final row = rows[index];
    final cleaned = (snap['cleaned'] as List).cast<num>();
    final peaks = (snap['peaks'] as List).cast<num>();
    final stats = snap['stats'] as List;
    final svg = signalSvg(cleaned, peaks);
    final rates = (snap['rates'] as List? ?? []).cast<num>();
    final rateSvg = rates.isEmpty
        ? null
        : signalSvg(rates, List<num>.filled(rates.length, 0));
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Header(level: 0, text: 'Trial ${index + 1}: ${snap['signal']}'),
            pw.Text('Processing: ${snap['processingMethod'] ?? 'legacy'}'),
            pw.Text(
              'Source: ${snap['source']}   Sampling: ${snap['sampleRate']} Hz',
            ),
            pw.SizedBox(height: 16),
            pw.Text('Cleaned waveform with detected peaks'),
            pw.SvgImage(svg: svg, height: 180),
            if (rateSvg != null) ...[
              pw.Text('Heart rate over the trial (BPM)'),
              pw.SvgImage(svg: rateSvg, height: 80),
            ],
            pw.SizedBox(height: 16),
            pw.Text(
              'Actual HR: ${(row['ActualRate'] as double).toStringAsFixed(1)} BPM\nPresented rate: ${(row['PresentedRate'] as double).toStringAsFixed(1)} BPM\nPsi delta: ${row['PsiDeltaRate']} BPM\nTrial type: ${row['TrialType']}\nResponse: ${row['SubjResponse'] == null
                  ? 'Timeout'
                  : row['SubjResponse'] == 1
                  ? 'Faster'
                  : 'Slower'}\nResponse time: ${row['ResponseTime'] ?? 'NA'} seconds\nConfidence: ${row['SubjRating'] ?? 'NA'}\nResponse mode: ${row['ResponseMode'] ?? 'buttons (legacy)'}\nDetected peaks: ${stats[4]}\nRobust HR MAD: ${stats[1]}\nHRV score: ${stats[2]}\nSample entropy: ${stats[3]}',
            ),
            pw.SizedBox(height: 20),
            pw.Text(
              'Complete raw signal, cleaned waveform, peak mask and sample timestamps are available in the accompanying trial JSON.',
            ),
          ],
        ),
      ),
    );
  }
  final pdfPath = csvPath.replaceFirst('.csv', '_Report.pdf');
  await File(pdfPath).writeAsBytes(await doc.save(), flush: true);
  return [svgPath, pdfPath];
}

String signalSvg(List<num> values, List<num> peaks) {
  if (values.isEmpty) {
    return '<svg xmlns="http://www.w3.org/2000/svg" width="720" height="240"></svg>';
  }
  final low = values.reduce(min).toDouble(),
      high = values.reduce(max).toDouble(),
      range = max(1e-9, high - low);
  double x(int i) => 20 + 680 * i / max(1, values.length - 1);
  double y(int i) => 220 - 200 * (values[i] - low) / range;
  final points = [
    for (var i = 0; i < values.length; i++)
      '${x(i).toStringAsFixed(2)},${y(i).toStringAsFixed(2)}',
  ].join(' ');
  final circles = [
    for (var i = 0; i < peaks.length; i++)
      if (peaks[i] > 0)
        '<circle cx="${x(i)}" cy="${y(i)}" r="3" fill="#cc3344"/>',
  ].join();
  return '<svg xmlns="http://www.w3.org/2000/svg" width="720" height="240" viewBox="0 0 720 240"><rect width="720" height="240" fill="white"/><polyline points="$points" fill="none" stroke="#258080" stroke-width="1"/>$circles</svg>';
}

String hrdSummarySvg(List<Map<String, Object?>> rows) {
  final parts = <String>[
    '<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="360" viewBox="0 0 1000 360"><rect width="1000" height="360" fill="white"/><text x="25" y="20" font-size="16">Psi delta and estimated bias (BPM)</text><text x="530" y="20" font-size="16">Actual and presented rate (BPM)</text>',
  ];
  final bias = <String>[];
  final rates = <String>[];
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    final x = 30 + 440 * (i + 0.5) / rows.length;
    double y(double d) => 180 - d * 2.5;
    final d = r['PsiDeltaRate'] as double;
    final color = r['TrialType'] == 'catch' || r['SubjResponse'] == null
        ? '#888888'
        : r['SubjResponse'] == 1
        ? '#cc3344'
        : '#3366cc';
    parts.add('<circle cx="$x" cy="${y(d)}" r="3" fill="$color"/>');
    final a = r['EstimatedRateMean'];
    if (a is double && a.isFinite) {
      bias.add('$x,${y(a)}');
      parts.add(
        '<line x1="$x" x2="$x" y1="${y(r['EstimatedRateLow'] as double)}" y2="${y(r['EstimatedRateHigh'] as double)}" stroke="#00aa77"/>',
      );
    }
    final bx = x + 500;
    final actual = r['ActualRate'] as double;
    final presented = r['PresentedRate'] as double;
    parts.add(
      '<line x1="$bx" x2="$bx" y1="330" y2="${330 - actual * 1.4}" stroke="#bbbbbb" stroke-width="${max(1.0, 350 / rows.length)}"/><circle cx="$bx" cy="${330 - presented * 1.4}" r="3" fill="$color"/>',
    );
    rates.add('$bx,${330 - presented * 1.4}');
  }
  parts.add('<line x1="20" x2="480" y1="180" y2="180" stroke="#cccccc"/>');
  if (bias.length > 1) {
    parts.add(
      '<polyline points="${bias.join(' ')}" fill="none" stroke="#00aa77" stroke-width="2"/>',
    );
  }
  if (rates.length > 1) {
    parts.add(
      '<polyline points="${rates.join(' ')}" fill="none" stroke="#555555" stroke-width="1"/>',
    );
  }
  parts.add('</svg>');
  return parts.join();
}
