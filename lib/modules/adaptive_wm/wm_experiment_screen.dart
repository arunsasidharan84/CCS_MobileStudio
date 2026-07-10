import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/services/session_manager.dart';
import '../home/home_screen.dart';
import 'models/experiment_models.dart';
import 'stimulus_renderer.dart';
import 'trial_runner.dart';
import 'wm_module.dart';

class WmExperimentScreen extends StatefulWidget {
  const WmExperimentScreen({
    super.key,
    required this.module,
    required this.sessionManager,
    required this.acquisitionService,
    required this.subjectId,
    this.channelLabels,
    this.enabledChannels,
  });

  final WmModule module;
  final SessionManager sessionManager;
  final AcquisitionService acquisitionService;
  final String subjectId;
  final List<String>? channelLabels;
  final List<bool>? enabledChannels;

  @override
  State<WmExperimentScreen> createState() => _WmExperimentScreenState();
}

class _WmExperimentScreenState extends State<WmExperimentScreen> {
  VoidCallback? _sessionSub;
  VoidCallback? _runnerSub;
  StreamSubscription<AcquisitionState>? _acqStateSub;
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

    _sessionSub = () {
      if (!mounted) return;
      final runner = widget.module.runner;
      if (widget.module.recordEeg) {
        if (!widget.sessionManager.isStreaming &&
            !runner.isPaused &&
            runner.isRunning) {
          runner.pause();
        } else if (widget.sessionManager.isStreaming && runner.isPaused) {
          runner.resume();
        }
      }
    };
    widget.sessionManager.addListener(_sessionSub!);
    _runnerSub = () {
      if (!mounted) return;
      if (widget.module.runner.currentPhase == TrialPhase.finished &&
          !_isFinishing) {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted && !_isFinishing) _finishExperiment();
        });
      }
    };
    widget.module.runner.addListener(_runnerSub!);

    if (widget.module.recordEeg) {
      _acqStateSub = widget.acquisitionService.state.listen(
        _handleAcquisitionState,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleAcquisitionState(widget.acquisitionService.currentState);
      });
    }
  }

  void _handleAcquisitionState(AcquisitionState state) {
    if (!mounted || _isFinishing || !widget.module.recordEeg) return;
    final disconnected = state != AcquisitionState.streaming;
    final runner = widget.module.runner;
    if (disconnected && !_waitingForReconnect) {
      if (runner.isRunning && !runner.isPaused) {
        runner.pause();
      }
      setState(() => _waitingForReconnect = true);
    } else if (!disconnected && _waitingForReconnect) {
      if (runner.isRunning && runner.isPaused) {
        runner.resume();
      }
      setState(() => _waitingForReconnect = false);
    }
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    if (_sessionSub != null) {
      widget.sessionManager.removeListener(_sessionSub!);
    }
    if (_runnerSub != null) {
      widget.module.runner.removeListener(_runnerSub!);
    }
    _acqStateSub?.cancel();
    super.dispose();
  }

  void _showExitConfirmation() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Exit Experiment?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'Are you sure you want to stop the experiment early? Data and logs collected so far will be saved.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.blueGrey),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.of(context).pop();
              _exitExperiment();
            },
            child: const Text('Exit', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _exitExperiment() async {
    await _finishExperiment();
  }

  Future<void> _finishExperiment() async {
    if (_isFinishing) return;
    _isFinishing = true;
    await widget.module.stopSession(widget.subjectId);

    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    }
  }

  void _handleKeyboardKey(KeyEvent event) {
    if (event is KeyDownEvent) {
      final runner = widget.module.runner;
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.keyQ) {
        _showExitConfirmation();
        return;
      }
      if (runner.currentPhase != TrialPhase.retrieval) return;
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.keyZ ||
          key == LogicalKeyboardKey.digit1) {
        runner.submitResponse(MatchDecision.match);
      } else if (key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.slash ||
          key == LogicalKeyboardKey.digit2) {
        runner.submitResponse(MatchDecision.mismatch);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TrialRunner>.value(
      value: widget.module.runner,
      child: KeyboardListener(
        focusNode: FocusNode()..requestFocus(),
        onKeyEvent: _handleKeyboardKey,
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            _showExitConfirmation();
          },
          child: Scaffold(
            backgroundColor: StimulusRenderer.backgroundColor,
            body: Stack(
              children: [
                _buildParadigm(context),
                Positioned(
                  top: 24,
                  right: 24,
                  child: IconButton(
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white54,
                      size: 32,
                    ),
                    tooltip: 'Exit Experiment',
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

  Widget _buildParadigm(BuildContext context) {
    return Consumer<TrialRunner>(
      builder: (context, runner, child) {
        if (runner.currentPhase == TrialPhase.idle) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    "You will see a fixation cross (+) and then an arrow cue pointing left (←) or right (→).\n\n"
                    "Focus strictly on the memory squares on the cued side.\n\n"
                    "After a brief delay, a test array will appear. One square's color may have changed.\n\n"
                    "Press Match if the cued array is identical, or Mismatch if one color changed.\n\n"
                    "Tap below to begin.",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),
                  ElevatedButton.icon(
                    onPressed: () {
                      widget.module.startSession(
                        subject: widget.subjectId,
                        channelCount: widget.acquisitionService.channelCount,
                        sampleRate: widget.acquisitionService.sampleRate
                            .toInt(),
                        channelLabels:
                            widget.channelLabels ??
                            widget.acquisitionService.channelLabels,
                        enabledChannels: widget.enabledChannels,
                      );
                    },
                    icon: const Icon(
                      Icons.play_arrow,
                      size: 28,
                      color: Colors.black,
                    ),
                    label: const Text(
                      "Start Adaptive WM Task",
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF14B8A6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 18,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        if (runner.currentPhase == TrialPhase.finished) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.check_circle,
                  color: Color(0xFF14B8A6),
                  size: 64,
                ),
                const SizedBox(height: 20),
                const Text(
                  "Adaptive WM Battery Complete!",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  "Completed ${runner.records.length} trials • Overall Accuracy: ${(runner.overallAccuracy * 100).toStringAsFixed(1)}%\n"
                  "Synchronized EEG (EDF), CSV timestamps, and PDF report saved to Downloads.",
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 36),
                ElevatedButton.icon(
                  onPressed: () async {
                    await _finishExperiment();
                  },
                  icon: const Icon(Icons.home, color: Colors.white),
                  label: const Text(
                    "Return to Dashboard",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E293B),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          );
        }

        return Stack(
          children: [
            StimulusRenderer(
              phase: runner.currentPhase,
              currentTrial: runner.currentTrial,
              cueHemifield: runner.currentCue,
            ),
            if (runner.isRunning)
              Positioned(
                top: 16,
                left: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B).withOpacity(0.92),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF334155)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.timer_outlined,
                        size: 18,
                        color: Color(0xFF60A5FA),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Trial ${runner.currentTrialNumber}/${runner.totalTrials} • N=${runner.currentSetSize} • '
                        '${(runner.elapsedSeconds ~/ 60).toString().padLeft(2, '0')}:${(runner.elapsedSeconds % 60).toString().padLeft(2, '0')}',
                        style: const TextStyle(
                          color: Color(0xFF60A5FA),
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (runner.currentPhase == TrialPhase.retrieval)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: const Color.fromARGB(210, 33, 33, 36),
                  padding: const EdgeInsets.all(24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color.fromARGB(
                              255,
                              52,
                              143,
                              80,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: () =>
                              runner.submitResponse(MatchDecision.match),
                          icon: const Icon(
                            Icons.check,
                            color: Colors.white,
                            size: 32,
                          ),
                          label: const Text(
                            "Match (Left/Z)",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 24),
                      Expanded(
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color.fromARGB(
                              255,
                              181,
                              61,
                              55,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: () =>
                              runner.submitResponse(MatchDecision.mismatch),
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 32,
                          ),
                          label: const Text(
                            "Mismatch (Right//)",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (runner.isPaused)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withOpacity(0.6),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 5.0, sigmaY: 5.0),
                    child: Center(
                      child: Card(
                        color: const Color(0xFF1E293B),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: Colors.white12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 40,
                            vertical: 30,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Color(0xFF14B8A6),
                                ),
                              ),
                              const SizedBox(height: 24),
                              const Text(
                                "EEG Connection Lost",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                "EEG disconnected – waiting for automatic reconnect…\nRecording will resume without losing trial progression.",
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 15,
                                  height: 1.4,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 28),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                ),
                                onPressed: _showExitConfirmation,
                                child: const Text(
                                  "Cancel Experiment",
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
