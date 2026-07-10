import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:liblsl/lsl.dart';

import '../models/nirs_sample.dart';
import '../models/lsl_config.dart';

enum NirsAcquisitionState { disconnected, resolving, connected }

/// Acquisition service for fNIRS data from NIRSport 2 (or any NIRS device)
/// via LSL (Lab Streaming Layer) over WiFi.
class NirsAcquisitionService extends ChangeNotifier {
  final _state = StreamController<NirsAcquisitionState>.broadcast();
  final _samples = StreamController<NirsSample>.broadcast();

  NirsAcquisitionState _currentState = NirsAcquisitionState.disconnected;
  LSLInlet<double>? _inlet;
  bool _running = false;

  List<String> _channelNames = [];
  double _nominalSampleRate = 10.0;
  int _channelCount = 0;
  String _streamName = '';

  static const _networkChannel = MethodChannel('angel/network');

  Stream<NirsAcquisitionState> get state => _state.stream;
  Stream<NirsSample> get samples => _samples.stream;
  NirsAcquisitionState get currentState => _currentState;
  List<String> get channelNames => List.unmodifiable(_channelNames);
  int get channelCount => _channelCount;
  double get sampleRate => _nominalSampleRate;
  String get connectedStreamName => _streamName;

  void _setState(NirsAcquisitionState s) {
    _currentState = s;
    if (!_state.isClosed) {
      _state.add(s);
    }
    notifyListeners();
  }

  Future<bool> connect(LslConfig config) async {
    await disconnect();
    _setState(NirsAcquisitionState.resolving);

    try {
      await _acquireMulticastLock();

      final streams = await _resolveStreams(config);
      if (streams.isEmpty) {
        debugPrint('[LSL-NIRS] No fNIRS/NIRS streams found.');
        _setState(NirsAcquisitionState.disconnected);
        await _releaseMulticastLock();
        return false;
      }

      final selected = _selectStream(streams, config.nirsStreamName);
      _channelCount = selected.channelCount;
      _nominalSampleRate = selected.sampleRate;
      _streamName = selected.streamName;
      _channelNames = _parseChannelNames(selected);

      debugPrint('[LSL-NIRS] Connected to: $_streamName '
          '(${_channelCount}ch @ ${_nominalSampleRate}Hz)');

      final inlet = LSLInlet<double>(selected, maxBuffer: 60, chunkSize: 0, recover: true);
      await inlet.create();
      _inlet = inlet;
      _running = true;
      _setState(NirsAcquisitionState.connected);
      _pullSamples();
      return true;
    } catch (e) {
      debugPrint('[LSL-NIRS] Connection failed: $e');
      _setState(NirsAcquisitionState.disconnected);
      await _releaseMulticastLock();
      return false;
    }
  }

  Future<List<LSLStreamInfo>> _resolveStreams(LslConfig config) async {
    final typesToTry = <String>{
      config.nirsStreamType,
      'fNIRS',
      'NIRS',
    }.toList();

    if (config.nirsStreamName.isNotEmpty) {
      final results = await _resolveByTypes(typesToTry, config.resolveTimeoutSeconds);
      if (results.isNotEmpty) {
        final filtered = results.where((s) =>
            s.streamName.toLowerCase().contains(config.nirsStreamName.toLowerCase())).toList();
        if (filtered.isNotEmpty) return filtered;
      }
    }

    return _resolveByTypes(typesToTry, config.resolveTimeoutSeconds);
  }

  Future<List<LSLStreamInfo>> _resolveByTypes(List<String> types, double timeout) async {
    for (final type in types) {
      final resolver = LSLStreamResolver(maxStreams: 10)..create();
      try {
        final results = await resolver.resolveByProperty(
          property: LSLStreamProperty.type,
          value: type,
          waitTime: timeout,
        );
        resolver.destroy();
        if (results.isNotEmpty) return results;
      } catch (_) {
        try { resolver.destroy(); } catch (_) {}
      }
    }
    return [];
  }

  LSLStreamInfo _selectStream(List<LSLStreamInfo> streams, String preferredName) {
    if (preferredName.isNotEmpty) {
      final target = preferredName.toLowerCase();
      return streams.firstWhere(
        (s) => s.streamName.toLowerCase() == target,
        orElse: () => streams.firstWhere(
          (s) => s.streamName.toLowerCase().contains(target),
          orElse: () => streams.first,
        ),
      );
    }
    return streams.firstWhere(
      (s) => s.streamName.toLowerCase().contains('nirx') ||
             s.streamName.toLowerCase().contains('nirs'),
      orElse: () => streams.first,
    );
  }

  List<String> _parseChannelNames(LSLStreamInfo stream) {
    try {
      final count = stream.channelCount;
      return List.generate(count, (i) {
        final pair = i ~/ 2 + 1;
        final chromophore = (i % 2 == 0) ? 'HbO' : 'HbR';
        return 'S$pair-D$pair $chromophore';
      });
    } catch (_) {
      return List.generate(stream.channelCount, (i) => 'NIRS ${i + 1}');
    }
  }

  Future<void> _pullSamples() async {
    final inlet = _inlet;
    final names = List<String>.from(_channelNames);
    final sr = _nominalSampleRate;
    while (_running && inlet != null) {
      try {
        final sample = await inlet.pullSample(timeout: 2.0);
        if (sample.data.isNotEmpty) {
          final channels = sample.data.toList();
          _samples.add(NirsSample(
            channels: channels,
            channelNames: names,
            sampleRate: sr,
            timestamp: DateTime.now(),
          ));
        }
      } catch (e) {
        if (_running) {
          debugPrint('[LSL-NIRS] Sample pull error: $e');
          await disconnect();
        }
        break;
      }
    }
  }

  Future<void> disconnect() async {
    _running = false;
    try { _inlet?.destroy(); } catch (_) {}
    _inlet = null;
    _channelNames = [];
    _channelCount = 0;
    _streamName = '';
    await _releaseMulticastLock();
    _setState(NirsAcquisitionState.disconnected);
  }

  @override
  void dispose() {
    disconnect();
    _state.close();
    _samples.close();
    super.dispose();
  }

  Future<void> _acquireMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod('acquireMulticastLock');
    } catch (e) {
      debugPrint('[LSL-NIRS] Multicast lock acquire failed: $e');
    }
  }

  Future<void> _releaseMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod('releaseMulticastLock');
    } catch (e) {
      debugPrint('[LSL-NIRS] Multicast lock release failed: $e');
    }
  }
}
