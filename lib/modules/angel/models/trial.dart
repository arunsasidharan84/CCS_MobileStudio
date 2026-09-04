import 'dart:math';

class Trial {
  Trial({
    required this.level,
    required this.block,
    required this.trialInBlock,
    required this.trialType,
    this.standardCategory,
    this.stimulusCategory,
    required this.frequencyClass,
    this.omittedCategory,
    this.targetSide,
    this.visualDistractorPos,
    required this.auditoryClass,
    this.auditoryOffsetS,
    this.corollaryMode,
    this.correctResponse,
    this.reversalPhase,
  });

  final String level;
  final int block;
  final int trialInBlock;
  final String trialType;
  final String? standardCategory;
  final String? stimulusCategory;
  final String frequencyClass;
  final String? omittedCategory;
  final String? targetSide;
  final String? visualDistractorPos;
  final String auditoryClass;
  final double? auditoryOffsetS;
  final String? corollaryMode;
  final String? correctResponse;
  final String? reversalPhase;

  Trial copyWith({String? level, int? block, int? trialInBlock}) {
    return Trial(
      level: level ?? this.level,
      block: block ?? this.block,
      trialInBlock: trialInBlock ?? this.trialInBlock,
      trialType: trialType,
      standardCategory: standardCategory,
      stimulusCategory: stimulusCategory,
      frequencyClass: frequencyClass,
      omittedCategory: omittedCategory,
      targetSide: targetSide,
      visualDistractorPos: visualDistractorPos,
      auditoryClass: auditoryClass,
      auditoryOffsetS: auditoryOffsetS,
      corollaryMode: corollaryMode,
      correctResponse: correctResponse,
      reversalPhase: reversalPhase,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'level': level,
      'block': block,
      'trial_in_block': trialInBlock,
      'trial_type': trialType,
      'standard_category': standardCategory ?? '',
      'stimulus_category': stimulusCategory ?? '',
      'frequency_class': frequencyClass,
      'omitted_category': omittedCategory ?? '',
      'target_side': targetSide ?? '',
      'visual_distractor_pos': visualDistractorPos ?? '',
      'auditory_class': auditoryClass,
      'auditory_offset_s': auditoryOffsetS ?? '',
      'corollary_mode': corollaryMode ?? '',
      'correct_response': correctResponse ?? '',
      'reversal_phase': reversalPhase ?? '',
    };
  }
}

class TrialGenerator {
  static const categories = {
    'face_present': {
      'meaning': 'meaningful',
      'family': 'face',
      'description': 'Mooney face',
      'files': [
        'fpa01.png',
        'fpa02.png',
        'fpa03.png',
        'fpa04.png',
        'fpa05.png',
        'fpa06.png',
        'fpa07.png',
        'fpa08.png',
        'fpa09.png',
        'fpa10.png',
        'fpa11.png',
        'fpa12.png',
        'fpa13.png',
        'fpa14.png',
        'fpa15.png',
        'fpa16.png',
        'fpa17.png',
        'fpa18.png',
        'fpa19.png',
        'fpa20.png',
        'fpa21.png',
        'fpa22.png',
        'fpa23.png',
        'fpa24.png',
        'fpa25.png',
        'fpa26.png',
        'fpa27.png',
        'fpa28.png',
        'fpa29.png',
        'fpa30.png',
      ],
    },
    'face_absent': {
      'meaning': 'ambiguous',
      'family': 'face',
      'description': 'distorted Mooney face',
      'files': [
        'faa01.png',
        'faa02.png',
        'faa03.png',
        'faa04.png',
        'faa05.png',
        'faa06.png',
        'faa07.png',
        'faa08.png',
        'faa09.png',
        'faa10.png',
        'faa11.png',
        'faa12.png',
        'faa13.png',
        'faa14.png',
        'faa15.png',
        'faa16.png',
        'faa17.png',
        'faa18.png',
        'faa19.png',
        'faa20.png',
        'faa21.png',
        'faa22.png',
        'faa23.png',
        'faa24.png',
        'faa25.png',
        'faa26.png',
        'faa27.png',
        'faa28.png',
        'faa29.png',
        'faa30.png',
      ],
    },
    'shape_present': {
      'meaning': 'meaningful',
      'family': 'shape',
      'description': 'Kanizsa triangle',
      'files': ['knz_wob.png', 'knz_bow.png'],
    },
    'shape_absent': {
      'meaning': 'ambiguous',
      'family': 'shape',
      'description': 'distorted Kanizsa',
      'files': ['nknz_wob.png', 'nknz_bow.png'],
    },
  };

  static const categorySets = {
    'all': ['face_present', 'face_absent', 'shape_present', 'shape_absent'],
    'face': ['face_present', 'face_absent'],
    'shape': ['shape_present', 'shape_absent'],
  };

  static List<Trial> generatePractice({
    required String level,
    required int trialsCount,
    required Random rng,
  }) {
    final trials = <Trial>[];
    for (var i = 1; i <= trialsCount; i++) {
      final isBaseline = i % 4 == 0;
      if (isBaseline) {
        trials.add(
          Trial(
            level: level,
            block: 0,
            trialInBlock: i,
            trialType: 'baseline',
            frequencyClass: 'baseline',
            auditoryClass: 'blank',
          ),
        );
      } else {
        final categorySet = categorySets['all']!;
        final stimCategory = categorySet[rng.nextInt(categorySet.length)];
        final targetSide = rng.nextBool() ? 'left' : 'right';
        final correctResponse = level == '1'
            ? targetSide
            : (categories[stimCategory]!['meaning'] == 'meaningful'
                  ? 'left'
                  : 'right');

        trials.add(
          Trial(
            level: level,
            block: 0,
            trialInBlock: i,
            trialType: 'active',
            standardCategory: categorySet.first,
            stimulusCategory: stimCategory,
            frequencyClass: rng.nextBool() ? 'frequent' : 'rare',
            targetSide: targetSide,
            visualDistractorPos: rng.nextBool() ? 'top' : 'bottom',
            auditoryClass: rng.nextBool() ? 'standard' : 'deviant',
            auditoryOffsetS: 0.0,
            corollaryMode: 'immediate',
            correctResponse: correctResponse,
          ),
        );
      }
    }
    return trials;
  }

  static List<Trial> generateLevelTrials({
    required String level,
    required int blocks,
    required Random rng,
    String categorySetKey = 'all',
    String pairedToneOffsetMode = 'continuous',
    double pairedToneOffsetMin = -0.24,
    double pairedToneOffsetMax = 0.24,
    String cdSchedule = 'by-block',
    int activeTrialsPerBlock = 25,
    int baselineTrialsPerBlock = 3,
    bool level2Cd = false,
  }) {
    final categoriesList = categorySets[categorySetKey]!;
    final blockSpecs = <(String, String)>[];
    while (blockSpecs.length < blocks) {
      for (final cat in categoriesList) {
        for (final side in ['left', 'right']) {
          blockSpecs.add((cat, side));
        }
      }
    }
    blockSpecs.shuffle(rng);
    final selectedSpecs = blockSpecs.sublist(0, blocks);

    final immediateBlocks = <int>{};
    final indices = List.generate(blocks, (i) => i + 1);
    indices.shuffle(rng);
    for (var i = 0; i < blocks / 2; i++) {
      immediateBlocks.add(indices[i]);
    }

    final trials = <Trial>[];
    for (var blockIdx = 1; blockIdx <= blocks; blockIdx++) {
      final (standardCategory, standardSide) = selectedSpecs[blockIdx - 1];
      final otherSide = standardSide == 'left' ? 'right' : 'left';
      final candidates = categoriesList
          .where((c) => c != standardCategory)
          .toList();
      String? omitted;
      List<String> rareCategories;
      if (candidates.length >= 2) {
        omitted = candidates[rng.nextInt(candidates.length)];
        rareCategories = candidates.where((c) => c != omitted).toList();
      } else {
        omitted = null;
        rareCategories = [candidates[0], candidates[0]];
      }

      final frequentCount = (activeTrialsPerBlock * 0.80).round();
      final rareCount = activeTrialsPerBlock - frequentCount;
      final rareACount = (rareCount + 1) ~/ 2;
      final rareBCount = rareCount - rareACount;

      final active = <(String, String)>[];
      for (var i = 0; i < frequentCount; i++) {
        active.add((standardCategory, 'frequent'));
      }
      for (var i = 0; i < rareACount; i++) {
        active.add((rareCategories[0], 'rare'));
      }
      for (var i = 0; i < rareBCount; i++) {
        active.add((rareCategories[1], 'rare'));
      }
      active.shuffle(rng);

      final blankCount = max(1, (activeTrialsPerBlock * 0.08).round());
      final standardCount = frequentCount;
      final deviantCount = activeTrialsPerBlock - standardCount - blankCount;

      final auditory = <String>[];
      for (var i = 0; i < standardCount; i++) {
        auditory.add('standard');
      }
      for (var i = 0; i < deviantCount; i++) {
        auditory.add('deviant');
      }
      for (var i = 0; i < blankCount; i++) {
        auditory.add('blank');
      }
      auditory.shuffle(rng);

      final blockCdModes = _makeCdModes(
        schedule: cdSchedule,
        blockIndex: blockIdx,
        immediateBlocks: immediateBlocks,
        activeTrialsCount: activeTrialsPerBlock,
        rng: rng,
      );

      for (var trialIdx = 1; trialIdx <= activeTrialsPerBlock; trialIdx++) {
        final (stimulusCategory, frequencyClass) = active[trialIdx - 1];
        final auditoryClass = auditory[trialIdx - 1];
        final targetSide = frequencyClass == 'frequent'
            ? standardSide
            : otherSide;

        final double? auditoryOffset = _samplePairedToneOffset(
          auditoryClass: auditoryClass,
          mode: pairedToneOffsetMode,
          minVal: pairedToneOffsetMin,
          maxVal: pairedToneOffsetMax,
          rng: rng,
        );

        final visualDistractorPos = rng.nextBool() ? 'top' : 'bottom';
        String? reversalPhase;
        String? correctResponse;
        String? corollaryMode;

        if (level == '1') {
          correctResponse = targetSide;
          corollaryMode = blockCdModes[trialIdx - 1];
        } else {
          corollaryMode = level2Cd ? blockCdModes[trialIdx - 1] : 'none';
          reversalPhase = blockIdx <= blocks / 2
              ? 'pre_reversal'
              : 'post_reversal';
          final meaning = categories[stimulusCategory]!['meaning'] as String;
          if (reversalPhase == 'pre_reversal') {
            correctResponse = meaning == 'meaningful' ? 'left' : 'right';
          } else {
            correctResponse = meaning == 'meaningful' ? 'right' : 'left';
          }
        }

        trials.add(
          Trial(
            level: level,
            block: blockIdx,
            trialInBlock: trialIdx,
            trialType: 'active',
            standardCategory: standardCategory,
            stimulusCategory: stimulusCategory,
            frequencyClass: frequencyClass,
            omittedCategory: omitted,
            targetSide: targetSide,
            visualDistractorPos: visualDistractorPos,
            auditoryClass: auditoryClass,
            auditoryOffsetS: auditoryOffset,
            corollaryMode: corollaryMode,
            correctResponse: correctResponse,
            reversalPhase: reversalPhase,
          ),
        );
      }

      for (var baseIdx = 1; baseIdx <= baselineTrialsPerBlock; baseIdx++) {
        trials.add(
          Trial(
            level: level,
            block: blockIdx,
            trialInBlock: activeTrialsPerBlock + baseIdx,
            trialType: 'baseline',
            standardCategory: standardCategory,
            frequencyClass: 'baseline',
            omittedCategory: omitted,
            auditoryClass: 'blank',
          ),
        );
      }
    }
    return trials;
  }

  static List<String> _makeCdModes({
    required String schedule,
    required int blockIndex,
    required Set<int> immediateBlocks,
    required int activeTrialsCount,
    required Random rng,
  }) {
    final modes = <String>[];
    if (schedule == 'all-immediate') {
      return List.filled(activeTrialsCount, 'immediate');
    }
    if (schedule == 'all-delayed') {
      return List.filled(activeTrialsCount, 'delayed');
    }
    if (schedule == 'all-none') {
      return List.filled(activeTrialsCount, 'none');
    }

    if (schedule == 'by-block') {
      final blockFeedbackMode = immediateBlocks.contains(blockIndex)
          ? 'immediate'
          : 'delayed';
      final noneCount = (activeTrialsCount * 0.20).round();
      final feedbackCount = activeTrialsCount - noneCount;
      for (var i = 0; i < feedbackCount; i++) {
        modes.add(blockFeedbackMode);
      }
      for (var i = 0; i < noneCount; i++) {
        modes.add('none');
      }
      modes.shuffle(rng);
    } else {
      final noneCount = (activeTrialsCount * 0.20).round();
      final immediateCount = (activeTrialsCount - noneCount) ~/ 2;
      final delayedCount = activeTrialsCount - noneCount - immediateCount;
      for (var i = 0; i < noneCount; i++) {
        modes.add('none');
      }
      for (var i = 0; i < immediateCount; i++) {
        modes.add('immediate');
      }
      for (var i = 0; i < delayedCount; i++) {
        modes.add('delayed');
      }
      modes.shuffle(rng);
    }
    return modes;
  }

  static double? _samplePairedToneOffset({
    required String auditoryClass,
    required String mode,
    required double minVal,
    required double maxVal,
    required Random rng,
  }) {
    if (auditoryClass == 'blank') return null;
    if (mode == 'fixed') {
      final choices = [-0.240, 0.0, 0.160];
      return choices[rng.nextInt(choices.length)];
    }
    return minVal + rng.nextDouble() * (maxVal - minVal);
  }
}
