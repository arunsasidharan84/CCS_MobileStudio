import 'dart:math';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'hrd_models.dart';

const _teal = Color(0xFF5EEAD4);

class HrdCombinedResponse extends StatefulWidget {
  const HrdCombinedResponse({super.key, required this.onConfirm});
  final void Function(HrdSliderAnswer) onConfirm;
  @override
  State<HrdCombinedResponse> createState() => _HrdCombinedResponseState();
}

class _HrdCombinedResponseState extends State<HrdCombinedResponse> {
  double value = 0;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Text(
            'Choose a side, then show how sure you are',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Further from the centre = more confident. Confirm to submit.',
          ),
          const SizedBox(height: 24),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [Text('← Slower'), Text('Faster →')],
          ),
          Slider(
            key: const Key('hrd-combined-slider'),
            value: value,
            min: -9,
            max: 9,
            divisions: 18,
            label: value == 0
                ? 'Choose a side'
                : '${value > 0 ? 'Faster' : 'Slower'} · confidence ${value.abs().round()}/9',
            onChanged: (v) => setState(() => value = v),
          ),
          Text(
            value == 0
                ? 'No answer selected'
                : '${value > 0 ? 'Faster' : 'Slower'} • confidence ${value.abs().round()} of 9',
            style: const TextStyle(fontSize: 20, color: _teal),
          ),
          const Text(
            'Near centre: low confidence  •  Outer ends: high confidence',
          ),
          const SizedBox(height: 20),
          FilledButton(
            key: const Key('hrd-confirm-slider'),
            onPressed: value == 0
                ? null
                : () => widget.onConfirm(HrdSliderAnswer(value)),
            child: const Text('Confirm response'),
          ),
        ],
      ),
    ),
  );
}

class HrdJourneyProgress extends StatelessWidget {
  const HrdJourneyProgress({
    super.key,
    required this.completed,
    required this.total,
    required this.stage,
    required this.collecting,
    required this.fraction,
  });
  final int completed, total;
  final String stage;
  final bool collecting;
  final double fraction;
  @override
  Widget build(BuildContext context) {
    final progress = completed / max(1, total);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            SizedBox(
              width: 76,
              height: 76,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: progress),
                    duration: const Duration(milliseconds: 400),
                    builder: (_, v, child) => SizedBox(
                      width: 72,
                      height: 72,
                      child: CircularProgressIndicator(
                        value: v,
                        strokeWidth: 7,
                        color: _teal,
                        backgroundColor: Colors.white12,
                      ),
                    ),
                  ),
                  Text(
                    '$completed/$total',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    completed == total
                        ? 'Journey complete'
                        : 'Your session journey',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('$completed of $total rounds completed'),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: progress,
                    color: _teal,
                    backgroundColor: Colors.white12,
                  ),
                  const SizedBox(height: 10),
                  Text(stage),
                  if (collecting) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: fraction.clamp(0, 1),
                      color: Colors.indigoAccent,
                      backgroundColor: Colors.white12,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${(fraction * 100).round()}% of this listening window',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HrdResultsPanel extends StatefulWidget {
  const HrdResultsPanel({
    super.key,
    required this.rows,
    required this.estimate,
    required this.paths,
    required this.complete,
  });
  final List<Map<String, Object?>> rows;
  final List<double> estimate;
  final List<String> paths;
  final bool complete;
  @override
  State<HrdResultsPanel> createState() => _HrdResultsPanelState();
}

class _HrdResultsPanelState extends State<HrdResultsPanel> {
  bool rates = false;
  int? selected;
  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final valid = rows.where((r) => r['SubjResponse'] != null).length;
    final adaptive = rows
        .where((r) => r['SubjResponse'] != null && r['TrialType'] == 'psi')
        .length;
    final e = widget.estimate;
    final bias = e.isNotEmpty && e.first.isFinite ? e.first : null;
    final pdf = widget.paths.where((p) => p.endsWith('.pdf')).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(
                  widget.complete
                      ? Icons.workspace_premium
                      : Icons.save_outlined,
                  color: _teal,
                  size: 44,
                ),
                const SizedBox(height: 12),
                Text(
                  widget.complete
                      ? 'Session completed'
                      : 'Partial session saved',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$valid responses recorded • ${rows.length - valid} missed • $adaptive adaptive updates',
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 28,
                  runSpacing: 12,
                  children: [
                    _metric(
                      'Estimated rate offset',
                      bias == null
                          ? 'Not available'
                          : '${bias >= 0 ? '+' : ''}${bias.toStringAsFixed(1)} BPM',
                    ),
                    _metric(
                      'Model steepness',
                      e.length > 3 && e[3].isFinite
                          ? e[3].toStringAsFixed(2)
                          : 'Not available',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  bias == null
                      ? 'No valid adaptive responses yet.'
                      : bias.abs() < 0.5
                      ? 'The estimated rate offset is close to zero.'
                      : 'The model estimates a ${bias.abs().toStringAsFixed(1)} BPM ${bias < 0 ? 'lower' : 'higher'} feedback rate offset relative to the measured heart rate.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Exploratory model estimates, not an interoceptive ability score. Short sessions and steepness estimates require particular caution.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'How your estimates developed',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Rate difference')),
                    ButtonSegment(value: true, label: Text('Heart & feedback')),
                  ],
                  selected: {rates},
                  onSelectionChanged: (v) => setState(() {
                    rates = v.first;
                    selected = null;
                  }),
                ),
                const SizedBox(height: 16),
                Text(
                  rates
                      ? 'Compare the measured heart rate with the feedback rate on each round.'
                      : 'Above zero: feedback faster than measured HR. Below zero: slower. Teal shows the evolving model offset.',
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (_, constraints) => GestureDetector(
                    onTapDown: (d) {
                      if (rows.isEmpty) return;
                      final x =
                          ((d.localPosition.dx - 55) /
                                  (constraints.maxWidth - 75) *
                                  rows.length)
                              .floor()
                              .clamp(0, rows.length - 1);
                      setState(() => selected = x);
                    },
                    child: SizedBox(
                      height: 280,
                      child: CustomPaint(
                        painter: HrdAccessibleChart(
                          rows,
                          rates,
                          selected,
                          labelStyle: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ),
                ),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _legend(Colors.redAccent, 'Answered faster'),
                    _legend(Colors.blueAccent, 'Answered slower'),
                    _legend(Colors.grey, 'Catch (diamond)'),
                    _legend(Colors.white54, 'Missed (outline)'),
                    _legend(
                      _teal,
                      rates ? 'Measured HR' : 'Model offset ± SD/2',
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  rates
                      ? 'Tap a round for its measured and feedback rates.'
                      : 'The SD/2 band reproduces the source task. It is not a 95% credible interval. Tap a round for details.',
                  style: const TextStyle(color: Colors.white60),
                ),
                if (selected != null && selected! < rows.length) ...[
                  const Divider(),
                  Text(
                    _details(rows[selected!]),
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          child: Column(
            children: [
              if (pdf != null)
                ListTile(
                  leading: const Icon(Icons.picture_as_pdf, color: _teal),
                  title: const Text('Open session report'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => OpenFilex.open(pdf),
                ),
              ExpansionTile(
                title: Text('Saved files (${widget.paths.length})'),
                subtitle: const Text(
                  'CSV responses, trial signals, session data and report',
                ),
                children: widget.paths
                    .map(
                      (p) => ListTile(
                        title: Text(p.split('/').last),
                        subtitle: SelectableText(p),
                        dense: true,
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _metric(String label, String value) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: _teal,
        ),
      ),
      Text(label),
    ],
  );
  Widget _legend(Color color, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.circle, size: 10, color: color),
      const SizedBox(width: 5),
      Text(text, style: const TextStyle(fontSize: 12)),
    ],
  );
  String _details(Map<String, Object?> r) =>
      'Round ${r['Trial']} • ${r['TrialType']}\nMeasured ${(r['ActualRate'] as num).toStringAsFixed(1)} BPM • Feedback ${(r['PresentedRate'] as num).toStringAsFixed(1)} BPM\nRequested difference ${r['PsiDeltaRate']} BPM • Answer ${r['SubjResponse'] == null
          ? 'missed'
          : r['SubjResponse'] == 1
          ? 'faster'
          : 'slower'} • Confidence ${r['SubjRating'] ?? 'not collected'}';
}

class HrdAccessibleChart extends CustomPainter {
  HrdAccessibleChart(this.rows, this.rates, this.selected, {this.labelStyle});
  final TextStyle? labelStyle;
  final List<Map<String, Object?>> rows;
  final bool rates;
  final int? selected;
  void label(
    Canvas c,
    String text,
    Offset position, {
    Color color = Colors.white60,
  }) {
    final t = TextPainter(
      text: TextSpan(
        text: text,
        style: (labelStyle ?? const TextStyle()).copyWith(
          fontSize: 11,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    t.paint(c, position);
  }

  @override
  void paint(Canvas c, Size s) {
    if (rows.isEmpty) {
      label(c, 'No completed rounds', const Offset(55, 80));
      return;
    }
    const left = 55.0, top = 25.0;
    final bottom = s.height - 38, right = s.width - 20;
    final values = <double>[if (!rates) 0];
    for (final r in rows) {
      for (final k
          in rates
              ? ['ActualRate', 'PresentedRate']
              : ['PsiDeltaRate', 'EstimatedRateLow', 'EstimatedRateHigh']) {
        final v = r[k];
        if (v is num && v.isFinite) values.add(v.toDouble());
      }
    }
    final low = values.isEmpty ? -50.0 : values.reduce(min),
        high = values.isEmpty ? 50.0 : values.reduce(max);
    final pad = max(5.0, (high - low) * 0.15);
    final minY = low - pad, maxY = high + pad;
    double y(double v) => bottom - (v - minY) / (maxY - minY) * (bottom - top);
    double x(int i) => left + (right - left) * (i + 0.5) / rows.length;
    for (var i = 0; i <= 4; i++) {
      final v = minY + (maxY - minY) * i / 4;
      final yy = y(v);
      c.drawLine(
        Offset(left, yy),
        Offset(right, yy),
        Paint()..color = Colors.white12,
      );
      label(c, v.toStringAsFixed(0), Offset(5, yy - 6));
    }
    label(c, rates ? 'Rate (BPM)' : 'Difference (BPM)', const Offset(5, 2));
    label(c, 'Round', Offset(s.width / 2 - 15, s.height - 14));
    if (!rates) {
      c.drawLine(
        Offset(left, y(0)),
        Offset(right, y(0)),
        Paint()
          ..color = Colors.white38
          ..strokeWidth = 1.5,
      );
    }
    final model = Path();
    bool begun = false;
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i], xx = x(i);
      if (i == selected) {
        c.drawRect(
          Rect.fromLTWH(
            xx - (right - left) / rows.length / 2,
            top,
            (right - left) / rows.length,
            bottom - top,
          ),
          Paint()..color = _teal.withValues(alpha: 0.08),
        );
      }
      final response = r['SubjResponse'];
      final color = response == null
          ? Colors.white54
          : r['TrialType'] == 'catch'
          ? Colors.grey
          : response == 1
          ? Colors.redAccent
          : Colors.blueAccent;
      final value = (r[rates ? 'PresentedRate' : 'PsiDeltaRate'] as num)
          .toDouble();
      final point = Offset(xx, y(value));
      final dot = Paint()
        ..color = color
        ..style = response == null ? PaintingStyle.stroke : PaintingStyle.fill
        ..strokeWidth = 2;
      if (r['TrialType'] == 'catch') {
        c.drawPath(
          Path()
            ..moveTo(point.dx, point.dy - 5)
            ..lineTo(point.dx + 5, point.dy)
            ..lineTo(point.dx, point.dy + 5)
            ..lineTo(point.dx - 5, point.dy)
            ..close(),
          dot,
        );
      } else {
        c.drawCircle(point, 4, dot);
      }
      final mean = r[rates ? 'ActualRate' : 'EstimatedRateMean'];
      if (mean is num && mean.isFinite) {
        final yy = y(mean.toDouble());
        if (!begun) {
          model.moveTo(xx, yy);
          begun = true;
        } else {
          model.lineTo(xx, yy);
        }
        if (!rates) {
          final l = r['EstimatedRateLow'], h = r['EstimatedRateHigh'];
          if (l is num && h is num && l.isFinite && h.isFinite) {
            c.drawLine(
              Offset(xx, y(l.toDouble())),
              Offset(xx, y(h.toDouble())),
              Paint()
                ..color = _teal.withValues(alpha: 0.35)
                ..strokeWidth = max(3, (right - left) / rows.length * 0.3),
            );
          }
        }
      }
      if (rows.length <= 20 ||
          i == 0 ||
          i == rows.length - 1 ||
          i % max(1, rows.length ~/ 10) == 0) {
        label(c, '${r['Trial']}', Offset(xx - 5, bottom + 8));
      }
    }
    c.drawPath(
      model,
      Paint()
        ..color = _teal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(HrdAccessibleChart old) => true;
}
