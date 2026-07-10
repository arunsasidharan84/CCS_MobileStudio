import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'models/experiment_models.dart';

class WmSummaryService {
  static Future<String> generate({
    required String participant,
    required List<TrialRecord> records,
    required DateTime sessionStart,
  }) async {
    final pdf = pw.Document();

    final totalTrials = records.length;
    final correctCount = records.where((r) => r.accuracy == 1).length;
    final incorrectCount = records.where((r) => r.accuracy == 0 && r.userResponse != MatchDecision.noResponse).length;
    final omissionCount = records.where((r) => r.userResponse == MatchDecision.noResponse).length;
    final overallAcc = totalTrials == 0 ? 0.0 : (correctCount / totalTrials) * 100.0;

    final validRts = records.where((r) => r.reactionTimeMs != null).map((r) => r.reactionTimeMs!).toList();
    final meanRt = validRts.isEmpty ? 0.0 : validRts.reduce((a, b) => a + b) / validRts.length;

    final maxSetSize = records.isEmpty ? 2 : records.map((r) => r.setSize).reduce((a, b) => a > b ? a : b);

    // Group by set size
    final setSizes = records.map((r) => r.setSize).toSet().toList()..sort();
    final setSizeStats = <int, _ConditionStat>{};
    for (final sz in setSizes) {
      final sub = records.where((r) => r.setSize == sz).toList();
      setSizeStats[sz] = _computeStat(sub);
    }

    // Condition stats
    final leftStats = _computeStat(records.where((r) => r.cuedHemifield == Hemifield.left).toList());
    final rightStats = _computeStat(records.where((r) => r.cuedHemifield == Hemifield.right).toList());
    final matchStats = _computeStat(records.where((r) => r.isMatchTrial).toList());
    final mismatchStats = _computeStat(records.where((r) => !r.isMatchTrial).toList());

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
          _buildOverallStats(totalTrials, overallAcc, correctCount, incorrectCount, omissionCount, meanRt, maxSetSize),
          pw.SizedBox(height: 24),
          _buildSetSizeTable(setSizes, setSizeStats),
          pw.SizedBox(height: 24),
          _buildConditionTable(leftStats, rightStats, matchStats, mismatchStats),
          pw.SizedBox(height: 24),
          _buildTrialLogTable(records),
        ],
      ),
    );

    final dir = await getApplicationDocumentsDirectory();
    final dataDir = Directory('${dir.path}/data');
    if (!await dataDir.exists()) await dataDir.create(recursive: true);

    final cleanSubject = participant.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final stamp = sessionStart.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final filePath = '${dataDir.path}/adaptive_wm_${cleanSubject}_summary_$stamp.pdf';

    final file = File(filePath);
    await file.writeAsBytes(await pdf.save());
    debugPrint('[WmSummaryService] Saved PDF to $filePath');
    return filePath;
  }

  static _ConditionStat _computeStat(List<TrialRecord> trials) {
    if (trials.isEmpty) return _ConditionStat(0, 0, 0.0, 0.0);
    final total = trials.length;
    final correct = trials.where((r) => r.accuracy == 1).length;
    final acc = (correct / total) * 100.0;
    final rts = trials.where((r) => r.reactionTimeMs != null).map((r) => r.reactionTimeMs!).toList();
    final rt = rts.isEmpty ? 0.0 : rts.reduce((a, b) => a + b) / rts.length;
    return _ConditionStat(total, correct, acc, rt);
  }

  static pw.Widget _buildHeader(String participant, DateTime start) {
    final dateStr = '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')} '
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';

    return pw.Container(
      padding: const pw.EdgeInsets.all(16),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#0F172A'),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'ADAPTIVE WORKING MEMORY (N-BACK) • SESSION REPORT',
            style: pw.TextStyle(color: PdfColor.fromHex('#38BDF8'), fontSize: 16, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Participant: $participant', style: pw.TextStyle(color: PdfColors.white, fontSize: 12)),
              pw.Text('Date/Time: $dateStr', style: pw.TextStyle(color: PdfColors.white, fontSize: 12)),
            ],
          ),
          pw.SizedBox(height: 4),
          pw.Text('Paradigm: Visual Lateralized Adaptive N-Back (Color-Location)',
              style: pw.TextStyle(color: PdfColor.fromHex('#94A3B8'), fontSize: 10)),
        ],
      ),
    );
  }

  static pw.Widget _buildOverallStats(
      int total, double acc, int correct, int incorrect, int omissions, double rt, int maxSz) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('OVERALL PERFORMANCE SUMMARY', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#1E293B'))),
        pw.SizedBox(height: 8),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            _statBox('Total Trials', '$total', '#0284C7'),
            _statBox('Accuracy', '${acc.toStringAsFixed(1)}%', '#059669'),
            _statBox('Mean RT', '${rt.toStringAsFixed(0)} ms', '#7C3AED'),
            _statBox('Max Set Size', 'N = $maxSz', '#D97706'),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
          children: [
            pw.Text('Correct: $correct', style: pw.TextStyle(color: PdfColor.fromHex('#059669'), fontSize: 11)),
            pw.Text('Incorrect: $incorrect', style: pw.TextStyle(color: PdfColor.fromHex('#DC2626'), fontSize: 11)),
            pw.Text('Omissions: $omissions', style: pw.TextStyle(color: PdfColor.fromHex('#D97706'), fontSize: 11)),
          ],
        )
      ],
    );
  }

  static pw.Widget _statBox(String label, String value, String hexColor) {
    return pw.Container(
      width: 110,
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColor.fromHex(hexColor), width: 1.5),
        borderRadius: pw.BorderRadius.circular(6),
        color: PdfColor.fromHex('#F8FAFC'),
      ),
      child: pw.Column(
        children: [
          pw.Text(label, style: pw.TextStyle(fontSize: 9, color: PdfColor.fromHex('#64748B'))),
          pw.SizedBox(height: 4),
          pw.Text(value, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex(hexColor))),
        ],
      ),
    );
  }

  static pw.Widget _buildSetSizeTable(List<int> setSizes, Map<int, _ConditionStat> stats) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('PERFORMANCE BY N-BACK SET SIZE', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#1E293B'))),
        pw.SizedBox(height: 8),
        pw.Table.fromTextArray(
          headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 10),
          headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#0284C7')),
          cellStyle: pw.TextStyle(fontSize: 10),
          cellAlignment: pw.Alignment.center,
          headers: ['Set Size', 'Trials Count', 'Correct Count', 'Accuracy (%)', 'Mean RT (ms)'],
          data: setSizes.map((sz) {
            final st = stats[sz]!;
            return [
              'Set Size $sz',
              '${st.total}',
              '${st.correct}',
              '${st.accuracy.toStringAsFixed(1)}%',
              '${st.meanRt.toStringAsFixed(0)} ms',
            ];
          }).toList(),
        ),
      ],
    );
  }

  static pw.Widget _buildConditionTable(
      _ConditionStat left, _ConditionStat right, _ConditionStat match, _ConditionStat mismatch) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('PERFORMANCE BY TRIAL CONDITION', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#1E293B'))),
        pw.SizedBox(height: 8),
        pw.Table.fromTextArray(
          headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 10),
          headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#475569')),
          cellStyle: pw.TextStyle(fontSize: 10),
          cellAlignment: pw.Alignment.center,
          headers: ['Condition', 'Trials Count', 'Correct Count', 'Accuracy (%)', 'Mean RT (ms)'],
          data: [
            ['Left Hemifield Cue', '${left.total}', '${left.correct}', '${left.accuracy.toStringAsFixed(1)}%', '${left.meanRt.toStringAsFixed(0)} ms'],
            ['Right Hemifield Cue', '${right.total}', '${right.correct}', '${right.accuracy.toStringAsFixed(1)}%', '${right.meanRt.toStringAsFixed(0)} ms'],
            ['Match Trial', '${match.total}', '${match.correct}', '${match.accuracy.toStringAsFixed(1)}%', '${match.meanRt.toStringAsFixed(0)} ms'],
            ['Mismatch Trial', '${mismatch.total}', '${mismatch.correct}', '${mismatch.accuracy.toStringAsFixed(1)}%', '${mismatch.meanRt.toStringAsFixed(0)} ms'],
          ],
        ),
      ],
    );
  }

  static pw.Widget _buildTrialLogTable(List<TrialRecord> records) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('TRIAL-BY-TRIAL CHRONOLOGICAL LOG', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#1E293B'))),
        pw.SizedBox(height: 8),
        pw.Table.fromTextArray(
          headerStyle: pw.TextStyle(color: PdfColors.white, fontWeight: pw.FontWeight.bold, fontSize: 9),
          headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#1E293B')),
          cellStyle: pw.TextStyle(fontSize: 8),
          cellAlignment: pw.Alignment.center,
          headers: ['Trial #', 'Set Size', 'Cue Side', 'Match?', 'Response', 'Acc', 'RT (ms)'],
          data: records.map((r) {
            return [
              '${r.trialNumber}',
              '${r.setSize}',
              r.cuedHemifield.name.toUpperCase(),
              r.isMatchTrial ? 'Yes' : 'No',
              r.userResponse.exportLabel,
              r.accuracy == 1 ? '1 (Correct)' : '0 (Incorrect)',
              r.reactionTimeMs != null ? '${r.reactionTimeMs}' : '-',
            ];
          }).toList(),
        ),
      ],
    );
  }
}

class _ConditionStat {
  final int total;
  final int correct;
  final double accuracy;
  final double meanRt;

  _ConditionStat(this.total, this.correct, this.accuracy, this.meanRt);
}
