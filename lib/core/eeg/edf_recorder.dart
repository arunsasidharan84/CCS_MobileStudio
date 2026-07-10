import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/eeg_sample.dart';
import 'native_core.dart';

/// Records EEG samples to disk in EDF format.
class EdfRecorder extends ChangeNotifier {
  Pointer<Void> _writer = nullptr;
  String? _path;
  int _signalChannelCount = 1;
  int _edfChannelCount = 2;
  int _sampleRate = 100;
  List<String> _channelLabels = [];
  List<bool>? _enabledChannels;
  int _pendingMarkerCode = 0;

  int _segmentIndex = 0;
  String? _sessionTimestamp;

  bool get isRecording => _writer != nullptr;
  String? get path => _path;
  int get segmentIndex => _segmentIndex;
  int get channelCount => _signalChannelCount;
  int get sampleRate => _sampleRate;
  List<String> get channelLabels => List.unmodifiable(_channelLabels);
  List<bool>? get enabledChannels => _enabledChannels;

  /// Start recording directly at a specific file path (used by SessionManager).
  Future<String> startAtPath({
    required String path,
    required String subject,
    required int channelCount,
    required int sampleRate,
    List<String>? channelLabels,
    List<bool>? enabledChannels,
  }) async {
    await stop();
    _signalChannelCount = channelCount.clamp(1, 16);
    _edfChannelCount = _signalChannelCount + 1;
    _sampleRate = sampleRate.clamp(50, 1000);
    _channelLabels = channelLabels ?? [];
    _enabledChannels = enabledChannels;
    _pendingMarkerCode = 0;
    _path = path;

    final cleanSubject = subject.trim().isEmpty
        ? 'unknown'
        : subject.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

    if (_channelLabels.isNotEmpty) {
      final labels = _channelLabels.length >= _signalChannelCount
          ? _channelLabels.sublist(0, _signalChannelCount)
          : [
              ..._channelLabels,
              ...List.generate(
                _signalChannelCount - _channelLabels.length,
                (i) => 'Ch ${_channelLabels.length + i + 1}',
              ),
            ];
      labels.add('Marker');
      final physDims = [...List.filled(_signalChannelCount, 'uV'), 'code'];
      final prefilters = [
        ...List.filled(_signalChannelCount, 'None'),
        'HP:0 LP:0',
      ];
      final transducers = [
        ...List.filled(_signalChannelCount, 'EEG electrode'),
        'Event markers',
      ];
      final physicalMinimums = [
        ...List.filled(_signalChannelCount, -3000.0),
        -32768.0,
      ];
      final physicalMaximums = [
        ...List.filled(_signalChannelCount, 3000.0),
        32767.0,
      ];

      _writer = NativeCore.instance.openEdfWithLabels(
        _path!,
        cleanSubject,
        _edfChannelCount,
        _sampleRate,
        labels,
        physDims,
        prefilters,
        transducers,
        physicalMinimums: physicalMinimums,
        physicalMaximums: physicalMaximums,
      );
    } else {
      final labels = [
        ...List.generate(_signalChannelCount, (i) => 'EEG ${i + 1}'),
        'Marker',
      ];
      final physDims = [...List.filled(_signalChannelCount, 'uV'), 'code'];
      final prefilters = [
        ...List.filled(_signalChannelCount, 'HP:0.3 LP:35'),
        'HP:0 LP:0',
      ];
      final transducers = [
        ...List.filled(_signalChannelCount, 'frontal electrode'),
        'Event markers',
      ];
      final physicalMinimums = [
        ...List.filled(_signalChannelCount, -3000.0),
        -32768.0,
      ];
      final physicalMaximums = [
        ...List.filled(_signalChannelCount, 3000.0),
        32767.0,
      ];
      _writer = NativeCore.instance.openEdfWithLabels(
        _path!,
        cleanSubject,
        _edfChannelCount,
        _sampleRate,
        labels,
        physDims,
        prefilters,
        transducers,
        physicalMinimums: physicalMinimums,
        physicalMaximums: physicalMaximums,
      );
    }

    if (_writer == nullptr) {
      throw StateError('Could not open EDF file at $_path');
    }
    notifyListeners();
    return _path!;
  }

  /// Start recording with default naming in recordings/ folder.
  Future<String> start({
    required String subject,
    required int channelCount,
    required int sampleRate,
    int segment = 0,
    List<String>? channelLabels,
    List<bool>? enabledChannels,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final recordings = Directory('${dir.path}/recordings');
    if (!await recordings.exists()) {
      await recordings.create(recursive: true);
    }

    final cleanSubject = subject.trim().isEmpty
        ? 'unknown'
        : subject.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

    if (segment == 0) {
      _sessionTimestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      _segmentIndex = 0;
    }

    final stamp =
        _sessionTimestamp ??
        DateTime.now()
            .toIso8601String()
            .replaceAll(':', '-')
            .replaceAll('.', '-');

    final filename = segment == 0
        ? '${cleanSubject}_$stamp.edf'
        : '${cleanSubject}_${stamp}_part$segment.edf';

    final fullPath = '${recordings.path}/$filename';
    return startAtPath(
      path: fullPath,
      subject: cleanSubject,
      channelCount: channelCount,
      sampleRate: sampleRate,
      channelLabels: channelLabels,
      enabledChannels: enabledChannels,
    );
  }

  int nextSegment() {
    _segmentIndex++;
    return _segmentIndex;
  }

  void setMarker(int code) {
    _pendingMarkerCode = code;
    debugPrint('[EdfRecorder] Marker: $code');
  }

  void push(EegSample sample) {
    if (_writer == nullptr) return;
    final values = List<double>.filled(_edfChannelCount, 0.0);
    int writeIdx = 0;
    for (var i = 0; i < sample.channels.length; i++) {
      final isEnabled =
          _enabledChannels == null ||
          i >= _enabledChannels!.length ||
          _enabledChannels![i];
      if (isEnabled && writeIdx < _signalChannelCount) {
        values[writeIdx++] = sample.channels[i];
      }
    }
    values[_edfChannelCount - 1] = _pendingMarkerCode.toDouble();
    _pendingMarkerCode = 0;
    NativeCore.instance.pushEdfSample(_writer, values);
  }

  Future<String?> stop() async {
    if (_writer == nullptr) return _path;
    final writer = _writer;
    _writer = nullptr;
    NativeCore.instance.closeEdf(writer);
    notifyListeners();
    return _path;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
