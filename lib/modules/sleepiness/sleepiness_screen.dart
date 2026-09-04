import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/services/settings_service.dart';
import '../../core/widgets/stanford_sleepiness_scale.dart';

/// Independent Module Screen for the Stanford Sleepiness Scale (SSS).
///
/// Decouples subjective sleepiness tracking from specific task modules like ANGEL or WM,
/// allowing researchers to execute SSS assessments flexibly at any point in the protocol sequence.
class SleepinessScreen extends StatefulWidget {
  const SleepinessScreen({super.key});

  @override
  State<SleepinessScreen> createState() => _SleepinessScreenState();
}

class _SleepinessScreenState extends State<SleepinessScreen> {
  int? _selectedScore;
  String _selectedTiming = 'Baseline / Pre-Protocol';
  List<Map<String, String>> _recentScores = [];
  bool _isLoadingHistory = false;

  final List<String> _timingOptions = [
    'Baseline / Pre-Protocol',
    'Pre-Cognitive Task (ANGEL/WM)',
    'Mid-Protocol Checkpoint',
    'Post-Cognitive Task',
    'Post-NIDRA Sleep Intervention',
    'Recovery / Final Check',
  ];

  final List<String> _scaleItems = [
    "1 - Feeling active, vital, alert, or wide awake",
    "2 - Functioning at high levels, but not at peak; able to concentrate",
    "3 - Awake, but relaxed; responsive but not fully alert",
    "4 - Somewhat foggy, let down",
    "5 - Foggy; losing interest in remaining awake; slowed down",
    "6 - Sleepy, woozy, fighting sleep; prefer to lie down",
    "7 - No longer fighting sleep, sleep onset soon; having dream-like thoughts",
  ];

  @override
  void initState() {
    super.initState();
    _loadRecentScores();
  }

  Future<void> _loadRecentScores() async {
    setState(() => _isLoadingHistory = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/data/sleepiness_scores.csv');
      if (await file.exists()) {
        final lines = await file.readAsLines();
        if (lines.length > 1) {
          final history = <Map<String, String>>[];
          // Read up to last 15 scores in reverse order
          for (var i = lines.length - 1; i >= 1 && history.length < 15; i--) {
            final line = lines[i];
            final parts = _parseCsvLine(line);
            if (parts.length >= 5) {
              history.add({
                'timestamp': parts[0],
                'app_name': parts[1],
                'subject_id': parts[2],
                'timing': parts[3],
                'score': parts[4],
              });
            }
          }
          setState(() => _recentScores = history);
        }
      }
    } catch (e) {
      debugPrint('Error loading recent SSS scores: $e');
    } finally {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  List<String> _parseCsvLine(String line) {
    final result = <String>[];
    var current = StringBuffer();
    bool inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == ',' && !inQuotes) {
        result.add(current.toString().trim());
        current.clear();
      } else {
        current.write(c);
      }
    }
    result.add(current.toString().trim());
    return result;
  }

  Future<void> _submitScore(String subjectCode) async {
    if (_selectedScore == null) return;
    final score = _selectedScore!;
    await StanfordSleepinessScale.saveScore(
      'CCS_MobileStudio',
      subjectCode,
      _selectedTiming,
      score,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Saved Stanford Sleepiness Scale score: $score ($subjectCode)',
        ),
        backgroundColor: const Color(0xFF14B8A6),
      ),
    );
    setState(() => _selectedScore = null);
    await _loadRecentScores();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final subjectCode = settings.subjectCode;
    final lightTeal = const Color(0xFF14B8A6);

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        title: const Text(
          'Stanford Sleepiness Scale (SSS)',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF111827),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top Subject Info Card
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: lightTeal.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.person,
                      color: Color(0xFF14B8A6),
                      size: 28,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'GLOBAL SUBJECT ID (Inherited from Main UI)',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subjectCode,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111827),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Modular SSS Task',
                        style: TextStyle(
                          color: Color(0xFF14B8A6),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Timing Selector
              const Text(
                'Assessment Checkpoint / Timing',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: DropdownButton<String>(
                  value: _selectedTiming,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF1E293B),
                  underline: const SizedBox.shrink(),
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  icon: Icon(Icons.arrow_drop_down, color: lightTeal),
                  items: _timingOptions
                      .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) setState(() => _selectedTiming = val);
                  },
                ),
              ),
              const SizedBox(height: 24),

              // SSS Options
              const Text(
                'Select Current Subjective Alertness Level',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: List.generate(_scaleItems.length, (index) {
                    final score = index + 1;
                    final isSelected = _selectedScore == score;
                    return InkWell(
                      onTap: () => setState(() => _selectedScore = score),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? lightTeal.withOpacity(0.15)
                              : Colors.transparent,
                          border: index < _scaleItems.length - 1
                              ? const Border(
                                  bottom: BorderSide(color: Colors.white10),
                                )
                              : null,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isSelected
                                    ? lightTeal
                                    : const Color(0xFF111827),
                              ),
                              child: Text(
                                '$score',
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.black
                                      : Colors.white70,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                _scaleItems[index],
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.white70,
                                  fontWeight: isSelected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            if (isSelected)
                              Icon(
                                Icons.check_circle,
                                color: lightTeal,
                                size: 22,
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(height: 24),

              // Submit Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _selectedScore == null
                        ? const Color(0xFF334155)
                        : lightTeal,
                    foregroundColor: _selectedScore == null
                        ? Colors.white38
                        : Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _selectedScore == null
                      ? null
                      : () => _submitScore(subjectCode),
                  icon: const Icon(Icons.save, size: 22),
                  label: const Text(
                    'LOG SLEEPINESS SCORE TO CSV',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Recent Logs Table
              const Text(
                'Recent SSS Log Entries (sleepiness_scores.csv)',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: _isLoadingHistory
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    : _recentScores.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text(
                          'No previous sleepiness logs recorded yet.',
                          style: TextStyle(color: Colors.white38),
                        ),
                      )
                    : Column(
                        children: _recentScores.map((row) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: lightTeal.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'Score: ${row['score']}',
                                    style: TextStyle(
                                      color: lightTeal,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${row['subject_id']} • ${row['timing']}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        row['timestamp'] ?? '',
                                        style: const TextStyle(
                                          color: Colors.white38,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
