import 'dart:async';
import 'dart:isolate';

import '../../core/models/eeg_sample.dart';
import '../../core/models/sleep_score.dart';
import '../../core/eeg/native_core.dart';

/// Real-time ONNX sleep staging pipeline running in a background Isolate.
///
/// Receives frontal EEG samples (or 16-channel EEG where Ch1/Fp1 is extracted),
/// feeds them into the native Rust ONNX inference engine (`tn_push_sample`),
/// and emits 30-second epoch classifications ([SleepScoreResult]) containing
/// stage probabilities and spectral band powers (Delta, Theta, Alpha, Beta).
class SleepPipeline {
  SleepPipeline({
    required double sampleRate,
    String? modelPath,
    required void Function(bool usesModel) onInitialized,
  }) {
    _spawnIsolate(sampleRate, modelPath, onInitialized);
  }

  Isolate? _isolate;
  SendPort? _toIsolatePort;
  final _receivePort = ReceivePort();
  final _scores = StreamController<SleepScoreResult>.broadcast();
  final List<Object> _pendingCommands = [];

  Stream<SleepScoreResult> get scores => _scores.stream;

  void _spawnIsolate(
    double sampleRate,
    String? modelPath,
    void Function(bool usesModel) onInitialized,
  ) {
    final initPort = ReceivePort();
    Isolate.spawn(
      _scoringIsolateEntry,
      _IsolateSpawnParams(
        sampleRate: sampleRate,
        modelPath: modelPath,
        initSendPort: initPort.sendPort,
        scoresSendPort: _receivePort.sendPort,
      ),
    ).then((iso) {
      _isolate = iso;
    });

    initPort.listen((msg) {
      if (msg is SendPort) {
        _toIsolatePort = msg;
        for (final cmd in _pendingCommands) {
          _toIsolatePort!.send(cmd);
        }
        _pendingCommands.clear();
      } else if (msg is bool) {
        onInitialized(msg);
        initPort.close();
      }
    });

    _receivePort.listen((msg) {
      if (msg is SleepScoreResult) {
        _scores.add(msg);
      }
    });
  }

  void setScoringStep(double stepSeconds) {
    final cmd = _ScoringStepCommand(stepSeconds);
    if (_toIsolatePort != null) {
      _toIsolatePort!.send(cmd);
    } else {
      _pendingCommands.add(cmd);
    }
  }

  void push(EegSample sample) {
    if (sample.channels.isEmpty) return;
    final frontalVal = sample.channels.first;
    final cmd = _PushSampleCommand(frontalVal);
    if (_toIsolatePort != null) {
      _toIsolatePort!.send(cmd);
    } else {
      _pendingCommands.add(cmd);
    }
  }

  void dispose() {
    _toIsolatePort?.send(_DisposeCommand());
    _receivePort.close();
    _scores.close();
    _isolate?.kill(priority: Isolate.beforeNextEvent);
  }
}

class _IsolateSpawnParams {
  _IsolateSpawnParams({
    required this.sampleRate,
    required this.modelPath,
    required this.initSendPort,
    required this.scoresSendPort,
  });

  final double sampleRate;
  final String? modelPath;
  final SendPort initSendPort;
  final SendPort scoresSendPort;
}

class _PushSampleCommand {
  _PushSampleCommand(this.sampleVal);
  final double sampleVal;
}

class _ScoringStepCommand {
  _ScoringStepCommand(this.stepSeconds);
  final double stepSeconds;
}

class _DisposeCommand {}

void _scoringIsolateEntry(_IsolateSpawnParams params) {
  final receivePort = ReceivePort();
  params.initSendPort.send(receivePort.sendPort);

  final nativeCore = NativeCore.instance;
  final state = nativeCore.createSleepState(
    params.sampleRate,
    modelPath: params.modelPath,
  );

  final usesModel = nativeCore.sleepStateUsesModel(state);
  params.initSendPort.send(usesModel);

  receivePort.listen((msg) {
    if (msg is _PushSampleCommand) {
      final score = nativeCore.pushSample(state, msg.sampleVal);
      if (score != null) {
        params.scoresSendPort.send(score);
      }
    } else if (msg is _ScoringStepCommand) {
      nativeCore.setScoringStep(state, msg.stepSeconds);
    } else if (msg is _DisposeCommand) {
      nativeCore.freeSleepState(state);
      receivePort.close();
    }
  });
}
