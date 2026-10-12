import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'resonance_config.dart';

class ResonanceParameter {
  const ResonanceParameter(
    this.key,
    this.label,
    this.help, {
    this.integer = false,
  });
  final String key, label, help;
  final bool integer;
}

const resonanceParameterGroups = <String, List<ResonanceParameter>>{
  'Timing and pacing': [
    ResonanceParameter(
      'settleSeconds',
      'Settling (seconds)',
      '10–120; excluded from measurement.',
      integer: true,
    ),
    ResonanceParameter(
      'measureSeconds',
      'Measurement (seconds)',
      '90–300; must include the minimum cycles at the slowest pace.',
      integer: true,
    ),
    ResonanceParameter(
      'restSeconds',
      'Rest (seconds)',
      '0–300; natural breathing between rates.',
      integer: true,
    ),
    ResonanceParameter(
      'practiceSeconds',
      'Practice (seconds)',
      '60–1800 after confirmation.',
      integer: true,
    ),
    ResonanceParameter(
      'minRate',
      'Minimum pace (breaths/min)',
      '4–8; adult research range.',
    ),
    ResonanceParameter(
      'maxRate',
      'Maximum pace (breaths/min)',
      '4–8; at least 0.5 above the minimum.',
    ),
    ResonanceParameter(
      'sweepStep',
      'Sweep step (breaths/min)',
      '0.25–1; descending conventional trials.',
    ),
    ResonanceParameter(
      'inhaleFraction',
      'Inhale fraction of cycle',
      '0.3–0.7; 0.5 gives equal inhale/exhale. No holds.',
    ),
  ],
  'Adaptive estimation': [
    ResonanceParameter(
      'adaptiveStep',
      'Adaptive grid step (breaths/min)',
      '0.05–0.5; up to 81 candidate rates.',
    ),
    ResonanceParameter(
      'minTrials',
      'Minimum accepted trials',
      '3–12 before early stopping.',
      integer: true,
    ),
    ResonanceParameter(
      'maxTrials',
      'Maximum accepted trials',
      'Minimum trials–16.',
      integer: true,
    ),
    ResonanceParameter(
      'targetWidth',
      'Target 95% credible width (breaths/min)',
      'At least one grid step; model-based stopping threshold.',
    ),
    ResonanceParameter(
      'noiseFloor',
      'Log-response noise floor',
      '0.1–1; larger values give more cautious posterior updates.',
    ),
    ResonanceParameter(
      'planningNoise',
      'Planning log-response noise',
      'Noise floor–1; used for expected information gain.',
    ),
  ],
  'Quality and confirmation': [
    ResonanceParameter(
      'minIntervals',
      'Minimum clean intervals',
      '20–200 per epoch.',
      integer: true,
    ),
    ResonanceParameter(
      'minCycles',
      'Minimum paced cycles',
      '6–20; increase measurement duration if needed.',
    ),
    ResonanceParameter(
      'minAccepted',
      'Minimum accepted fraction',
      '0.7–1; 0.9 permits up to 10% rejected intervals.',
    ),
    ResonanceParameter(
      'minCoverage',
      'Minimum coverage fraction',
      '0.7–1; clean interval duration / measurement duration.',
    ),
    ResonanceParameter(
      'minAmplitudeMs',
      'Minimum oscillation amplitude (ms)',
      '1–100; semi-amplitude of the fitted interval wave.',
    ),
    ResonanceParameter(
      'minFitR2',
      'Minimum partial fit R²',
      '0.05–0.95; improvement beyond a linear trend.',
    ),
    ResonanceParameter(
      'outlierFraction',
      'Interval outlier fraction',
      '0.15–0.6 deviation from the recent median.',
    ),
    ResonanceParameter(
      'confirmRatioMin',
      'Confirmation amplitude lower ratio',
      '0.1–1 relative to nearest accepted discovery trial.',
    ),
    ResonanceParameter(
      'confirmRatioMax',
      'Confirmation amplitude upper ratio',
      '1–3; repeatability heuristic.',
    ),
  ],
};

class ResonanceParameterEditor extends StatelessWidget {
  const ResonanceParameterEditor({
    super.key,
    required this.fields,
    required this.onChanged,
    required this.onReset,
  });
  final Map<String, TextEditingController> fields;
  final VoidCallback onChanged, onReset;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final group in resonanceParameterGroups.entries)
        ExpansionTile(
          title: Text(group.key),
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth >= 620
                      ? (constraints.maxWidth - 16) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      for (final parameter in group.value)
                        SizedBox(
                          width: width,
                          child: TextField(
                            key: ValueKey('resonance-${parameter.key}'),
                            controller: fields[parameter.key],
                            keyboardType: TextInputType.numberWithOptions(
                              decimal: !parameter.integer,
                            ),
                            onChanged: (_) => onChanged(),
                            decoration: InputDecoration(
                              labelText: parameter.label,
                              helperText: parameter.help,
                              helperMaxLines: 3,
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      TextButton.icon(
        onPressed: onReset,
        icon: const Icon(Icons.restore),
        label: const Text('Restore default parameters'),
      ),
    ],
  );
}

class ResonanceMethodsPanel extends StatelessWidget {
  const ResonanceMethodsPanel({super.key, required this.config});
  final ResonanceConfig config;
  Future<void> _open(BuildContext context, String url) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      /* Show the selectable URL below when opening is unavailable. */
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Could not open the reference. Copy the URL shown below.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ExpansionTile(
        title: const Text('How the assessment works'),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SelectableText(
                  '1. Select one cardiac stream. ECG uses R-wave intervals; PPG uses pulse intervals. The shared causal detector filters ECG at 5–25 Hz or PPG at 0.5–5 Hz, with a 300 ms refractory period. A gap or sample-rate change discards the current epoch.',
                ),
                const SizedBox(height: 12),
                Text(
                  '2. Settle for ${config.settleSeconds}s, then measure for ${config.measureSeconds}s. Fit RR(t) = offset + trend × t + A sin(2πft) + B cos(2πft) directly at irregular interval midpoints. Response amplitude = √(A²+B²) ms; partial R² compares against a separately fitted linear trend. SDNN and RMSSD are descriptive only.',
                ),
                const SizedBox(height: 12),
                Text(
                  '3. Reject intervals outside 300–2000 ms or more than ${(100 * config.outlierFraction).toStringAsFixed(0)}% from the recent median. Require ≥${config.minIntervals} clean intervals, ≥${config.minCycles} cycles, ≥${(100 * config.minAccepted).toStringAsFixed(0)}% accepted, ≥${(100 * config.minCoverage).toStringAsFixed(0)}% coverage, amplitude ≥${config.minAmplitudeMs} ms and partial R² ≥${config.minFitR2}. Only comfortable, quality-approved epochs are used.',
                ),
                const SizedBox(height: 12),
                Text(
                  '4. Conventional: compare ${config.sweepRates.length} descending rates and choose the largest fitted amplitude. Adaptive: update a posterior over the optimum, marginalizing unknown peak height and width. The next rate minimizes expected entropy of that optimum; start with broad coverage. Stop after ${config.minTrials}–${config.maxTrials} accepted trials, using a 95% credible-width target of ${config.targetWidth} breaths/min.',
                ),
                const SizedBox(height: 12),
                const SelectableText(
                  'Adaptive model: log(amplitude) = log(height) − ½[(rate − optimum)/width]². Uniform optimum prior; height grid 10, 20, 40, 80, 160, 320 ms; width grid 0.4, 0.8, 1.5, 3.0 breaths/min. Gaussian log-response likelihood; predictive quadrature selects the next rate. This is a physiological adaptation of Psi, separate from the HRD psychometric model.',
                ),
                const SizedBox(height: 12),
                Text(
                  '5. Confirm with a fresh, comfortable epoch: amplitude must be ${config.confirmRatioMin}–${config.confirmRatioMax} times the nearest accepted discovery epoch. This is a repeatability heuristic. Then practise for ${config.practiceSeconds}s.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Research limits: actual respiration, phase alignment and baroreflex gain are unmeasured. The adaptive model assumes a stable single peak. Its credible interval and engineering quality thresholds need independent validation. Changing parameters changes the protocol; all values are saved with the session.',
                ),
              ],
            ),
          ),
        ],
      ),
      ExpansionTile(
        title: const Text('Scientific references'),
        subtitle: const Text('Protocol basis and adaptive-design inspiration'),
        children: [
          _reference(
            context,
            'Shaffer & Meehan (2020)',
            'A Practical Guide to Resonance Frequency Assessment for Heart Rate Variability Biofeedback. Frontiers in Neuroscience, 14:570400. DOI: 10.3389/fnins.2020.570400.',
            'Adult sweeps, artifact review and respiration measurement. Our numerical ranking and abbreviated rest are adaptations.',
            'https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2020.570400/full',
          ),
          _reference(
            context,
            'Kontsevich & Tyler (1999)',
            'Bayesian adaptive estimation of psychometric slope and threshold. Vision Research, 39:2729–2737. DOI: 10.1016/S0042-6989(98)00285-5.',
            'Inspiration for selecting each trial by expected information gain; not a validation of resonance breathing.',
            'https://pubmed.ncbi.nlm.nih.gov/10492833/',
          ),
          _reference(
            context,
            'Prins (2013)',
            'The psi-marginal adaptive method: How to give nuisance parameters the attention they deserve (no more, no less). Journal of Vision, 13(7):3. DOI: 10.1167/13.7.3.',
            'Inspiration for optimizing the marginal posterior of the parameter of interest while retaining nuisance uncertainty.',
            'https://pubmed.ncbi.nlm.nih.gov/23750016/',
          ),
        ],
      ),
    ],
  );
  Widget _reference(
    BuildContext context,
    String title,
    String citation,
    String relevance,
    String url,
  ) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        SelectableText(citation),
        const SizedBox(height: 6),
        Text(relevance),
        TextButton.icon(
          onPressed: () => _open(context, url),
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open reference'),
        ),
        SelectableText(url, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}
