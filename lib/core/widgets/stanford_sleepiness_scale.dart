import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class StanfordSleepinessScale {
  static Future<void> saveScore(String appName, String subjectId, String timing, int score) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final dataDir = Directory('${dir.path}/data');
      if (!await dataDir.exists()) await dataDir.create(recursive: true);
      
      final file = File('${dataDir.path}/sleepiness_scores.csv');
      final exists = await file.exists();
      final timestamp = DateTime.now().toIso8601String();
      final csvLine = '"$timestamp","$appName","$subjectId","$timing",$score\n';
      if (!exists) {
        await file.writeAsString('timestamp,app_name,subject_id,timing,score\n$csvLine');
      } else {
        await file.writeAsString(csvLine, mode: FileMode.append);
      }
    } catch (e) {
      debugPrint('Error saving sleepiness score: $e');
    }
  }
}

class StanfordSleepinessScaleDialog extends StatefulWidget {
  final String appName;
  final String subjectId;
  final String timing;

  const StanfordSleepinessScaleDialog({
    super.key,
    required this.appName,
    required this.subjectId,
    required this.timing,
  });

  static Future<int?> show(BuildContext context, String appName, String subjectId, String timing) {
    return showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StanfordSleepinessScaleDialog(
        appName: appName,
        subjectId: subjectId,
        timing: timing,
      ),
    );
  }

  @override
  State<StanfordSleepinessScaleDialog> createState() => _StanfordSleepinessScaleDialogState();
}

class _StanfordSleepinessScaleDialogState extends State<StanfordSleepinessScaleDialog> {
  int? _selectedScore;

  final List<String> _scaleItems = [
    "1 - Feeling active, vital, alert, or wide awake",
    "2 - Functioning at high levels, but not at peak; able to concentrate",
    "3 - Awake, but relaxed; responsive but not fully alert",
    "4 - Somewhat foggy, let down",
    "5 - Foggy; losing interest in remaining awake; slowed down",
    "6 - Sleepy, woozy, fighting sleep; prefer to lie down",
    "7 - No longer fighting sleep, sleep onset soon; having dream-like thoughts"
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      title: const Text(
        'Stanford Sleepiness Scale',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Please select the statement that best describes how you feel right now:',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 16),
            ...List.generate(_scaleItems.length, (index) {
              final score = index + 1;
              return RadioListTile<int>(
                title: Text(
                  _scaleItems[index],
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
                value: score,
                groupValue: _selectedScore,
                activeColor: const Color(0xFF14B8A6),
                onChanged: (val) {
                  setState(() {
                    _selectedScore = val;
                  });
                },
              );
            }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _selectedScore == null
              ? null
              : () async {
                  await StanfordSleepinessScale.saveScore(
                    widget.appName,
                    widget.subjectId,
                    widget.timing,
                    _selectedScore!,
                  );
                  if (mounted) {
                    Navigator.of(context).pop(_selectedScore);
                  }
                },
          child: Text(
            'Submit',
            style: TextStyle(
              color: _selectedScore == null ? Colors.blueGrey : const Color(0xFF14B8A6),
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
