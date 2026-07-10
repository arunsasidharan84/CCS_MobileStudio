import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/nirs_sample.dart';
import 'native_core.dart';

/// Records fNIRS data to EDF using the same Rust native backend as EdfRecorder,
/// but with proper fNIRS channel labels (HbO/HbR) and physical dimensions (umol/L).
class NirsEdfRecorder extends ChangeNotifier {
  Pointer<Void> _writer = nullptr;
  String? _path;
  int _channelCount = 0;
  double _sampleRate = 10.0;
  List<String> _channelNames = [];

  bool get isRecording => _writer != nullptr;
  String? get path => _path;
  List<String> get channelNames => List.unmodifiable(_channelNames);

  Future<String> startAtPath({
    required String path,
    required String subject,
    required List<String> channelNames,
    required double sampleRate,
    bool includeMarkerChannel = true,
  }) async {
    await stop();

    _channelNames = List<String>.from(channelNames);
    if (includeMarkerChannel) {
      _channelNames.add('Marker');
    }
    _channelCount = _channelNames.length;
    _sampleRate = sampleRate.clamp(1.0, 1000.0);
    _path = path;

    final cleanSubject = subject.trim().isEmpty
        ? 'unknown'
        : subject.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

    final dims = _channelNames
        .map((n) => n == 'Marker' ? 'code' : 'umol/L')
        .toList();
    final prefilters = _channelNames
        .map((n) => n == 'Marker' ? 'HP:0 LP:0' : 'HP:0.01 LP:0')
        .toList();
    final transducers = _channelNames
        .map((n) => n == 'Marker' ? 'Event markers' : 'fNIRS optode')
        .toList();
    final physicalMinimums = _channelNames
        .map((n) => n == 'Marker' ? -32768.0 : -3000.0)
        .toList();
    final physicalMaximums = _channelNames
        .map((n) => n == 'Marker' ? 32767.0 : 3000.0)
        .toList();

    _writer = NativeCore.instance.openEdfWithLabels(
      _path!,
      cleanSubject,
      _channelCount,
      _sampleRate.round(),
      _channelNames,
      dims,
      prefilters,
      transducers,
      physicalMinimums: physicalMinimums,
      physicalMaximums: physicalMaximums,
    );

    if (_writer == nullptr) {
      throw StateError('Could not open fNIRS EDF file at $_path');
    }
    notifyListeners();
    return _path!;
  }

  Future<String> start({
    required String subject,
    required List<String> channelNames,
    required double sampleRate,
    bool includeMarkerChannel = true,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final recordings = Directory('${dir.path}/recordings');
    if (!await recordings.exists()) {
      await recordings.create(recursive: true);
    }

    final cleanSubject = subject.trim().isEmpty
        ? 'unknown'
        : subject.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );

    final fullPath = '${recordings.path}/${cleanSubject}_nirs_$stamp.edf';
    return startAtPath(
      path: fullPath,
      subject: cleanSubject,
      channelNames: channelNames,
      sampleRate: sampleRate,
      includeMarkerChannel: includeMarkerChannel,
    );
  }

  void push(NirsSample sample, {int markerCode = 0}) {
    if (_writer == nullptr) return;
    final values = List<double>.filled(_channelCount, 0.0);
    final nirsChannels = _channelCount - 1;
    for (var i = 0; i < nirsChannels; i++) {
      if (i < sample.channels.length) {
        values[i] = (sample.channels[i] * 100.0).clamp(-32768.0, 32767.0);
      }
    }
    values[_channelCount - 1] = markerCode.toDouble();
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
