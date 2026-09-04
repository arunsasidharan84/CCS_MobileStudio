import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/models/module_type.dart';
import '../../core/services/file_naming_service.dart';
import '../../core/services/session_manager.dart';
import '../home/home_screen.dart';
import 'erp_engine.dart';
import 'summary_report_service.dart';

class ExperimentScreen extends StatefulWidget {
  const ExperimentScreen({
    super.key,
    required this.sessionManager,
    required this.acquisitionService,
    required this.level,
    required this.language,
    required this.participant,
    required this.blocksCount,
    required this.trialsPerBlockOption,
    required this.practiceCount,
    this.categorySet = 'all',
    this.cdSchedule = 'by-block',
    this.pairedToneOffsetMode = 'continuous',
    this.visualDistractorMode = 'sync',
    this.tonePlaybackMode = 'async',
    this.level2Cd = true,
    this.intermixLevelBlocks = true,
    this.stimDuration = 0.240,
    this.responseWindow = 0.700,
    this.postMaskMin = 0.200,
    this.postMaskMax = 0.900,
    this.toneOffsetMin = -0.240,
    this.toneOffsetMax = 0.240,
    this.cdVolume = 0.70,
    this.excludePractice = false,
    this.recordEeg = true,
    this.audioInstructionsEnabled = true,
    this.channelLabels,
    this.enabledChannels,
  });

  final SessionManager sessionManager;
  final AcquisitionService acquisitionService;
  final String level;
  final String language;
  final String participant;
  final int blocksCount;
  final String trialsPerBlockOption;
  final int practiceCount;
  final String categorySet;
  final String cdSchedule;
  final String pairedToneOffsetMode;
  final String visualDistractorMode;
  final String tonePlaybackMode;
  final bool level2Cd;
  final bool intermixLevelBlocks;
  final double stimDuration;
  final double responseWindow;
  final double postMaskMin;
  final double postMaskMax;
  final double toneOffsetMin;
  final double toneOffsetMax;
  final double cdVolume;
  final bool excludePractice;
  final bool recordEeg;
  final bool audioInstructionsEnabled;
  final List<String>? channelLabels;
  final List<bool>? enabledChannels;

  @override
  State<ExperimentScreen> createState() => _ExperimentScreenState();
}

class _ExperimentScreenState extends State<ExperimentScreen> {
  late final ErpEngine _erpEngine;
  StreamSubscription<AcquisitionState>? _acqStateSub;

  bool _isLoading = true;
  String _loadingMessage = 'Loading EEG/EDF pipeline...';
  int _instructionStep = 0;
  int _mainInstructionStep = 0;
  bool _savedToPublic = false;
  bool _isFinishing = false;
  bool _waitingForReconnect = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _erpEngine = ErpEngine(
      level: widget.level,
      language: widget.language,
      participant: widget.participant,
      blocksCount: widget.blocksCount,
      trialsPerBlockOption: widget.trialsPerBlockOption,
      practiceCount: widget.practiceCount,
      stimDurationSeconds: widget.stimDuration,
      responseWindowSeconds: widget.responseWindow,
      postMaskMinSeconds: widget.postMaskMin,
      postMaskMaxSeconds: widget.postMaskMax,
      pairedToneOffsetMin: widget.toneOffsetMin,
      pairedToneOffsetMax: widget.toneOffsetMax,
      visualDistractorMode: widget.visualDistractorMode,
      pairedToneOffsetMode: widget.pairedToneOffsetMode,
      tonePlaybackMode: widget.tonePlaybackMode,
      categorySet: widget.categorySet,
      level2Cd: widget.level2Cd,
      intermixLevelBlocks: widget.intermixLevelBlocks,
      cdSchedule: widget.cdSchedule,
      excludePractice: widget.excludePractice,
      guideAudioEnabled: widget.audioInstructionsEnabled,
    );

    _erpEngine.onStateChanged = () {
      if (mounted) {
        setState(() {});
        if (_erpEngine.stage == ErpStage.completed && !_savedToPublic) {
          _savedToPublic = true;
          _finishSession();
        }
      }
    };

    _erpEngine.onMarkerSent = (event) {
      debugPrint(
        '[ERP MARKER] ${event.elapsedMs}ms: ${event.code} (${event.label})',
      );
      if (widget.recordEeg) {
        widget.sessionManager.recordEvent(event.label, event.code);
      }
    };

    if (widget.recordEeg) {
      _acqStateSub = widget.acquisitionService.state.listen(
        _handleAcquisitionState,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleAcquisitionState(widget.acquisitionService.currentState);
      });
    }

    _startSessionSetup();
  }

  void _handleAcquisitionState(AcquisitionState state) {
    if (!mounted || _isFinishing || !widget.recordEeg) return;
    final disconnected = state != AcquisitionState.streaming;
    if (disconnected && !_waitingForReconnect) {
      _erpEngine.pause();
      setState(() => _waitingForReconnect = true);
    } else if (!disconnected && _waitingForReconnect) {
      _erpEngine.resume();
      setState(() => _waitingForReconnect = false);
    }
  }

  Future<void> _startSessionSetup() async {
    try {
      await _erpEngine.init();

      if (widget.recordEeg) {
        setState(() {
          _loadingMessage = 'Starting EEG recording...';
        });

        final channelCount = widget.acquisitionService.channelCount;
        final sampleRate = widget.acquisitionService.sampleRate.toInt();
        final labels = widget.acquisitionService.recordingChannelLabels(
          widget.channelLabels,
        );
        final enabledChannels = widget.acquisitionService
            .recordingEnabledChannels(widget.enabledChannels);

        await widget.sessionManager.startSession(
          subject: widget.participant,
          module: ModuleType.angel,
          channelCount: channelCount,
          sampleRate: sampleRate,
          channelLabels: labels,
          enabledChannels: enabledChannels,
        );
      }

      setState(() {
        _isLoading = false;
      });

      _erpEngine.start();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingMessage = 'Error starting session: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _acqStateSub?.cancel();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    if (!_isFinishing) {
      widget.sessionManager.stopSession();
    }
    _erpEngine.dispose();
    super.dispose();
  }

  void _proceedFromPractice() {
    final practiceLevel = _erpEngine.lastCompletedPracticeLevel ?? '1';
    final isLevel1And2 = widget.level == '1,2';
    final hasProceedToLevel2 = isLevel1And2 && practiceLevel == '1';

    if (hasProceedToLevel2) {
      _erpEngine.resetPracticeMetrics();
      _erpEngine.currentTrialGlobalIndex = _erpEngine.practiceCount;
      setState(() => _instructionStep = 0);
      _erpEngine.stage = ErpStage.instructions;
      _erpEngine.playGuideAudio('WelcomeLevel1.mp3');
    } else {
      _erpEngine.stage = ErpStage.mainInstructions;
      setState(() => _mainInstructionStep = 0);
      _erpEngine.playGuideAudio('InstructionLevel1.mp3');
    }
  }

  void _handleScreenTap(TapDownDetails details, Size size) {
    if (_erpEngine.stage == ErpStage.instructions) {
      if (_instructionStep == 0) {
        setState(() => _instructionStep = 1);
        _erpEngine.playGuideAudio('InstructionLevel1.mp3');
      } else if (_instructionStep == 1) {
        setState(() => _instructionStep = 2);
        _erpEngine.playGuideAudio('PracticeStart.mp3');
      } else {
        _erpEngine.nextInstructionOrStart();
      }
    } else if (_erpEngine.stage == ErpStage.mainInstructions) {
      if (_mainInstructionStep == 0) {
        setState(() => _mainInstructionStep = 1);
        _erpEngine.playGuideAudio('Ready.mp3');
      } else {
        _erpEngine.nextInstructionOrStart();
      }
    } else if (_erpEngine.stage == ErpStage.practiceEnd) {
      _proceedFromPractice();
    } else if (_erpEngine.stage == ErpStage.blockFeedback) {
      _erpEngine.resetBlockFeedbackMetrics();
      _erpEngine.progressSlide();
    } else if (_erpEngine.stage == ErpStage.trialVisual ||
        _erpEngine.stage == ErpStage.trialResponseWindow) {
      final x = details.globalPosition.dx;
      final halfWidth = size.width / 2;
      if (x < halfWidth) {
        _erpEngine.registerResponse('left');
      } else {
        _erpEngine.registerResponse('right');
      }
    }
  }

  void _handleKeyboardKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      final logicalKey = event.logicalKey;
      if (logicalKey == LogicalKeyboardKey.escape ||
          logicalKey == LogicalKeyboardKey.keyQ) {
        _showExitConfirmation();
      } else if (logicalKey == LogicalKeyboardKey.arrowLeft ||
          logicalKey == LogicalKeyboardKey.keyZ ||
          logicalKey == LogicalKeyboardKey.digit1) {
        _erpEngine.registerResponse('left');
      } else if (logicalKey == LogicalKeyboardKey.arrowRight ||
          logicalKey == LogicalKeyboardKey.slash ||
          logicalKey == LogicalKeyboardKey.digit2) {
        _erpEngine.registerResponse('right');
      } else if (logicalKey == LogicalKeyboardKey.space ||
          logicalKey == LogicalKeyboardKey.enter) {
        if (_erpEngine.stage == ErpStage.instructions) {
          if (_instructionStep == 0) {
            setState(() => _instructionStep = 1);
            _erpEngine.playGuideAudio('InstructionLevel1.mp3');
          } else if (_instructionStep == 1) {
            setState(() => _instructionStep = 2);
            _erpEngine.playGuideAudio('PracticeStart.mp3');
          } else {
            _erpEngine.nextInstructionOrStart();
          }
        } else if (_erpEngine.stage == ErpStage.mainInstructions) {
          if (_mainInstructionStep == 0) {
            setState(() => _mainInstructionStep = 1);
            _erpEngine.playGuideAudio('Ready.mp3');
          } else {
            _erpEngine.nextInstructionOrStart();
          }
        } else if (_erpEngine.stage == ErpStage.practiceEnd) {
          _proceedFromPractice();
        } else if (_erpEngine.stage == ErpStage.blockFeedback) {
          _erpEngine.resetBlockFeedbackMetrics();
          _erpEngine.progressSlide();
        }
      }
    }
  }

  Future<void> _saveToPublicFolder({
    String? csvPath,
    String? pdfPath,
    String? sessionStem,
  }) async {
    final canExport =
        !Platform.isAndroid ||
        await Permission.manageExternalStorage.request().isGranted ||
        await Permission.storage.request().isGranted;
    if (!canExport) return;
    try {
      final stem =
          sessionStem ??
          FileNamingService.stem(
            widget.participant,
            ModuleType.angel,
            _erpEngine.sessionStartTime,
          );

      if (csvPath != null) {
        await FileNamingService.exportToDownloads(
          csvPath,
          subject: widget.participant,
          sessionStem: stem,
        );
      }

      if (pdfPath != null) {
        await FileNamingService.exportToDownloads(
          pdfPath,
          subject: widget.participant,
          sessionStem: stem,
        );
      }
    } catch (e) {
      debugPrint('[Save to output folder error] $e');
    }
  }

  Future<void> _finishSession() async {
    if (_isFinishing) return;
    _isFinishing = true;
    final sessionStem = widget.recordEeg
        ? widget.sessionManager.currentSessionStem
        : null;
    await widget.sessionManager.stopSession();
    final csvPath = await _erpEngine.writeLogFile();

    String? pdfPath;
    if (_erpEngine.trialLog.isNotEmpty) {
      try {
        pdfPath = await SummaryReportService.generate(
          participant: widget.participant,
          trialLog: _erpEngine.trialLog,
          sessionStart: _erpEngine.sessionStartTime,
        );
      } catch (e) {
        debugPrint('[PDF] Generation failed: $e');
      }
    }

    await _saveToPublicFolder(
      csvPath: csvPath,
      pdfPath: pdfPath,
      sessionStem: sessionStem,
    );

    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    }
  }

  void _exitToDashboard() async {
    if (_isFinishing) return;
    _isFinishing = true;
    final sessionStem = widget.recordEeg
        ? widget.sessionManager.currentSessionStem
        : null;
    await widget.sessionManager.stopSession();
    final csvPath = await _erpEngine.writeLogFile();

    String? pdfPath;
    if (_erpEngine.trialLog.isNotEmpty) {
      try {
        pdfPath = await SummaryReportService.generate(
          participant: widget.participant,
          trialLog: _erpEngine.trialLog,
          sessionStart: _erpEngine.sessionStartTime,
        );
      } catch (e) {
        debugPrint('[PDF] Generation failed: $e');
      }
    }

    await _saveToPublicFolder(
      csvPath: csvPath,
      pdfPath: pdfPath,
      sessionStem: sessionStem,
    );

    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    }
  }

  void _showExitConfirmation() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F2937),
        title: const Text(
          'Exit Experiment?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Are you sure you want to abort the experiment and return to the configuration screen? Your progress in this block will be lost.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Color(0xFF14B8A6)),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              _exitToDashboard();
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Exit', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _shareRecordedFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final List<XFile> shareFiles = [];

    final dataDir = Directory('${dir.path}/data');
    if (await dataDir.exists()) {
      for (final f in dataDir.listSync()) {
        if (f is File &&
            f.path.contains(widget.participant) &&
            (f.path.endsWith('.csv') || f.path.endsWith('.pdf'))) {
          shareFiles.add(XFile(f.path));
        }
      }
    }

    if (shareFiles.isNotEmpty) {
      await Share.shareXFiles(
        shareFiles,
        text: 'ANGEL ERP session data — ${widget.participant}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFF808080),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Color(0xFF14B8A6)),
              const SizedBox(height: 20),
              Text(
                _loadingMessage,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showExitConfirmation();
      },
      child: KeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        onKeyEvent: _handleKeyboardKey,
        child: Scaffold(
          backgroundColor: const Color(0xFF808080),
          body: GestureDetector(
            onTapDown: (details) => _handleScreenTap(details, size),
            onLongPress: _showExitConfirmation,
            behavior: HitTestBehavior.opaque,
            child: Stack(
              children: [
                if (_erpEngine.stage == ErpStage.instructions ||
                    _erpEngine.stage == ErpStage.mainInstructions)
                  _buildSlideContent()
                else if (_erpEngine.stage == ErpStage.practiceEnd)
                  _buildPracticeEndContent()
                else if (_erpEngine.stage == ErpStage.blockFeedback)
                  _buildFeedbackContent()
                else if (_erpEngine.stage == ErpStage.completed)
                  _buildCompletionContent()
                else
                  Positioned.fill(
                    child: CustomPaint(
                      painter: ErpCanvasPainter(engine: _erpEngine),
                    ),
                  ),
                Positioned(
                  top: 15,
                  right: 15,
                  child: IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white70,
                      size: 28,
                    ),
                    onPressed: _showExitConfirmation,
                  ),
                ),
                if (_waitingForReconnect) _buildConnectionLostOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionLostOverlay() {
    return Positioned.fill(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Container(
          color: Colors.black.withOpacity(0.62),
          child: const Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xFF111827),
                borderRadius: BorderRadius.all(Radius.circular(18)),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 36, vertical: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFF14B8A6)),
                    SizedBox(height: 18),
                    Text(
                      'EEG connection lost',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Task paused. It will resume after the amplifier reconnects.',
                      style: TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSlideContent() {
    ui.Image? slideImg;
    if (_erpEngine.stage == ErpStage.instructions) {
      if (_instructionStep == 0) {
        slideImg = _erpEngine.imgWelcome;
      } else if (_instructionStep == 1) {
        slideImg = _erpEngine.imgInstructions;
      } else {
        slideImg = _erpEngine.imgPractice;
      }
    } else if (_erpEngine.stage == ErpStage.mainInstructions) {
      if (_mainInstructionStep == 0) {
        slideImg = _erpEngine.imgInstructions;
      } else {
        slideImg = _erpEngine.imgReady;
      }
    }

    return Positioned.fill(
      child: Center(
        child: slideImg != null
            ? RawImage(image: slideImg, fit: BoxFit.contain)
            : const Text(
                'No Image Asset',
                style: TextStyle(color: Colors.white54),
              ),
      ),
    );
  }

  Widget _buildPracticeEndContent() {
    final acc = (_erpEngine.practiceAccuracy * 100).toStringAsFixed(1);
    final rt = _erpEngine.practiceMeanRtMs.toStringAsFixed(1);
    final practiceLevel = _erpEngine.lastCompletedPracticeLevel ?? '1';

    final isLevel1And2 = widget.level == '1,2';
    final hasProceedToLevel2 = isLevel1And2 && practiceLevel == '1';

    return Positioned.fill(
      child: Stack(
        children: [
          if (_erpEngine.imgPracticeEnd != null)
            Positioned.fill(
              child: RawImage(
                image: _erpEngine.imgPracticeEnd,
                fit: BoxFit.contain,
              ),
            ),
          Center(
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxWidth: 500),
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.85),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF14B8A6).withOpacity(0.3),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Practice Completed (Level $practiceLevel)',
                    style: const TextStyle(
                      color: Color(0xFF14B8A6),
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildPracticeMetricColumn('Accuracy', '$acc%'),
                      _buildPracticeMetricColumn('Mean RT', '${rt}ms'),
                    ],
                  ),
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () {
                          _erpEngine.resetPracticeMetrics();
                          final repeatStartIndex =
                              (widget.level == '1,2' && practiceLevel == '2')
                              ? _erpEngine.practiceCount
                              : 0;
                          _erpEngine.currentTrialGlobalIndex = repeatStartIndex;
                          setState(() => _instructionStep = 0);
                          _erpEngine.stage = ErpStage.instructions;
                          _erpEngine.playGuideAudio('WelcomeLevel1.mp3');
                        },
                        icon: const Icon(Icons.replay, color: Colors.white),
                        label: const Text(
                          'Repeat Practice',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey[800],
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _proceedFromPractice,
                        icon: const Icon(
                          Icons.arrow_forward,
                          color: Colors.black,
                        ),
                        label: Text(
                          hasProceedToLevel2
                              ? 'Proceed to Level 2'
                              : 'Start Main Task',
                          style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF14B8A6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPracticeMetricColumn(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 14),
        ),
        const SizedBox(height: 8),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildFeedbackContent() {
    final acc = (_erpEngine.blockAccuracy * 100).toStringAsFixed(1);
    final rt = _erpEngine.blockMeanRtMs.toStringAsFixed(1);

    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: _erpEngine.imgRelax != null
                  ? RawImage(image: _erpEngine.imgRelax, fit: BoxFit.contain)
                  : const SizedBox(),
            ),
          ),
          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.55),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Well Done! Take a short break.',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Block ${_erpEngine.currentBlockIndex} of ${widget.blocksCount} completed',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 25),
                    Text(
                      'Accuracy: $acc%',
                      style: const TextStyle(
                        color: Colors.tealAccent,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Mean RT: $rt ms',
                      style: const TextStyle(
                        color: Colors.tealAccent,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 35),
                    const Text(
                      'Tap screen or press Space to continue.',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 14,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletionContent() {
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: _erpEngine.imgThankYou != null
                  ? RawImage(image: _erpEngine.imgThankYou, fit: BoxFit.contain)
                  : const SizedBox(),
            ),
          ),
          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.65),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'Session Completed',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 15),
                    const Text(
                      'All EEG data and trial logs have been saved.',
                      style: TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                    const SizedBox(height: 35),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: _shareRecordedFiles,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF14B8A6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 15,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: const Icon(Icons.share, color: Colors.black),
                          label: const Text(
                            'Share Logs & EEG (EDF/CSV)',
                            style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 20),
                        OutlinedButton(
                          onPressed: () =>
                              Navigator.of(context).pushAndRemoveUntil(
                                MaterialPageRoute(
                                  builder: (_) => const HomeScreen(),
                                ),
                                (route) => false,
                              ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.white30),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 15,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text(
                            'Back to Dashboard',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ErpCanvasPainter extends CustomPainter {
  ErpCanvasPainter({required this.engine});

  final ErpEngine engine;

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF808080);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bg);

    final centerX = size.width / 2;
    final centerY = size.height / 2;

    final double h = size.height;
    final double targetWidth = h * 0.32;
    final double targetHeight = h * 0.41;
    final double distractorWidth = h * 0.12;
    final double distractorHeight = h * 0.085;
    final double fixSize = h * 0.075;

    final double targetOffset = h * 0.42;
    final double distractorOffsetX = h * 0.18;
    final double distractorOffsetY = h * 0.34;

    if (engine.maskVisible) {
      if (engine.imgCheckerboard != null) {
        _drawImage(
          canvas,
          engine.imgCheckerboard!,
          Offset(centerX - targetOffset, centerY),
          targetWidth,
          targetHeight,
        );
        _drawImage(
          canvas,
          engine.imgCheckerboard!,
          Offset(centerX + targetOffset, centerY),
          targetWidth,
          targetHeight,
        );
      }
      if (engine.imgFixation != null) {
        _drawImage(
          canvas,
          engine.imgFixation!,
          Offset(centerX, centerY),
          fixSize,
          fixSize,
        );
      }
    }

    if (engine.distractorVisible && engine.currentTrial != null) {
      final pos = engine.currentTrial!.visualDistractorPos;
      if (engine.imgCheckerboard != null) {
        final double ySign = pos == 'top' ? -1 : 1;
        final double distY = centerY + (distractorOffsetY * ySign);
        _drawImage(
          canvas,
          engine.imgCheckerboard!,
          Offset(centerX - distractorOffsetX, distY),
          distractorWidth,
          distractorHeight,
        );
        _drawImage(
          canvas,
          engine.imgCheckerboard!,
          Offset(centerX + distractorOffsetX, distY),
          distractorWidth,
          distractorHeight,
        );
      }
    }

    if (engine.targetVisible &&
        engine.currentTrial != null &&
        engine.currentTargetImage != null) {
      final side = engine.currentTrial!.targetSide;
      final double targetX = side == 'left'
          ? (centerX - targetOffset)
          : (centerX + targetOffset);
      _drawImage(
        canvas,
        engine.stage == ErpStage.trialResponseWindow
            ? engine.imgCheckerboard!
            : engine.currentTargetImage!,
        Offset(targetX, centerY),
        targetWidth,
        targetHeight,
      );
    }
  }

  void _drawImage(
    Canvas canvas,
    ui.Image image,
    Offset center,
    double width,
    double height,
  ) {
    final rect = Rect.fromCenter(center: center, width: width, height: height);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      Paint()..filterQuality = ui.FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(covariant ErpCanvasPainter oldDelegate) => true;
}
