import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

import '../eeg/acquisition_service.dart';
import '../eeg/edf_recorder.dart';
import '../eeg/signal_stream_edf_recorder.dart';
import '../models/eeg_sample.dart';
import '../models/device_profile.dart';
import '../models/signal_stream_sample.dart';
import '../models/module_type.dart';
import '../models/stream_marker.dart';
import 'settings_service.dart';
import 'multi_stream_lsl_service.dart';
import 'multi_device_acquisition_service.dart';
import 'file_naming_service.dart';
import 'device_awake_service.dart';

/// Manages EDF session lifecycle across connection/reconnection events.
///
/// - Tracks session timestamp, subject, module, and current segment index.
/// - On disconnect: closes the current segment and exports it to the configured
///   operator-visible output folder.
/// - On reconnect: opens a new segment (_part2, _part3, etc.) automatically.
class SessionManager extends ChangeNotifier {
  String _subject = '';
  ModuleType _module = ModuleType.standalone;
  DateTime? _sessionStart;
  int _segmentIndex = 1;
  bool _isRecording = false;
  bool _wasRecordingBeforeDisconnect = false;

  // ── Recording timer pause/resume ───────────────────────────────────────────
  /// Total duration accumulated in previous segments (before the current pause).
  Duration _accumulatedDuration = Duration.zero;

  /// When the current running segment started (null when paused / not recording).
  DateTime? _timerSegmentStart;

  /// True while the recording timer is paused due to disconnection.
  bool _timerPaused = false;

  EdfRecorder? _recorder;
  AcquisitionService? _acq;
  SettingsService? _settings;
  MultiStreamLslService? _multiLsl;
  MultiDeviceAcquisitionService? _multiDevice;
  StreamSubscription<EegSample>? _sampleSub;
  StreamSubscription<SignalStreamSample>? _streamSampleSub;
  StreamSubscription<SignalStreamSample>? _lslSampleSub;
  StreamSubscription<StreamMarker>? _markerSub;
  StreamSubscription<SignalStreamSample>? _multiDeviceSampleSub;
  final Map<String, SignalStreamEdfRecorder> _streamRecorders = {};
  final List<StreamMarker> _markerLog = [];
  Timer? _durationTicker;

  AcquisitionState? _lastAcqState;

  String get subject => _subject;
  ModuleType get module => _module;
  DateTime? get sessionStart => _sessionStart;
  int get segmentIndex => _segmentIndex;
  bool get isRecording => _isRecording;

  /// Actual EEG-connected recording time (pauses on disconnect, resumes on reconnect).
  Duration get currentDuration {
    if (!_isRecording) return Duration.zero;
    final running = _timerPaused || _timerSegmentStart == null
        ? Duration.zero
        : DateTime.now().difference(_timerSegmentStart!);
    return _accumulatedDuration + running;
  }

  bool get timerPaused => _timerPaused;

  String get formattedDuration {
    final d = currentDuration;
    final hrs = d.inHours.toString().padLeft(2, '0');
    final mins = (d.inMinutes % 60).toString().padLeft(2, '0');
    final secs = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hrs:$mins:$secs';
  }

  ModuleType? get activeModule => _isRecording ? _module : null;
  int get currentSegment => _segmentIndex;
  String? get lastExportPath => _recorder?.path;
  bool get isStreaming =>
      (_acq?.isStreamReady ?? false) ||
      (_multiDevice?.readySecondaryServices.isNotEmpty ?? false) ||
      (_multiLsl?.isConnected ?? false);
  String? get currentSessionStem {
    final start = _sessionStart;
    if (start == null || _subject.isEmpty) return null;
    return FileNamingService.stem(_subject, _module, start);
  }

  // ── DI update (called by ProxyProvider) ────────────────────────────────────

  void update(
    AcquisitionService acq,
    EdfRecorder recorder,
    SettingsService settings,
    MultiStreamLslService multiLsl,
    MultiDeviceAcquisitionService multiDevice,
  ) {
    _recorder = recorder;
    _settings = settings;
    if (_multiLsl != multiLsl) {
      _lslSampleSub?.cancel();
      _markerSub?.cancel();
      _lslSampleSub = multiLsl.samples.listen((sample) {
        if (_isRecording) {
          _streamRecorders[sample.streamId]?.push(sample);
        }
      });
      _markerSub = multiLsl.markers.listen((marker) {
        if (_isRecording) {
          recordEvent('lsl_${marker.value}', marker.code, marker: marker);
        }
      });
      _multiLsl = multiLsl;
    }
    if (_multiDevice != multiDevice) {
      _multiDeviceSampleSub?.cancel();
      _multiDeviceSampleSub = multiDevice.samples.listen((sample) {
        if (_isRecording) {
          _streamRecorders[sample.streamId]?.push(sample);
        }
      });
      _multiDevice = multiDevice;
    }

    if (_acq != acq) {
      _sampleSub?.cancel();
      _streamSampleSub?.cancel();
      _sampleSub = acq.samples.listen((sample) {
        if (_isRecording && _recorder != null) {
          _recorder!.push(sample);
        }
      });
      _streamSampleSub = acq.streamSamples.listen((sample) {
        if (_isRecording) {
          _streamRecorders[sample.streamId]?.push(sample);
        }
      });
    }

    final newState = acq.currentState;
    if (_acq != null && newState != _lastAcqState) {
      _onAcquisitionStateChanged(newState);
    }
    _acq = acq;
    _lastAcqState = newState;
  }

  // ── State transitions ──────────────────────────────────────────────────────

  void _onAcquisitionStateChanged(AcquisitionState state) {
    switch (state) {
      case AcquisitionState.scanning:
      case AcquisitionState.connecting:
      case AcquisitionState.disconnected:
        if (_isRecording) {
          _wasRecordingBeforeDisconnect = true;
          _pauseTimer();
          _stopCurrentSegment();
        }
      case AcquisitionState.streaming:
        if (_wasRecordingBeforeDisconnect &&
            (_settings?.autoResumeRecordingAfterReconnect ?? true)) {
          _wasRecordingBeforeDisconnect = false;
          _resumeTimer();
          _startNextSegment();
        }
    }
  }

  void _pauseTimer() {
    if (_timerPaused || !_isRecording) return;
    if (_timerSegmentStart != null) {
      _accumulatedDuration += DateTime.now().difference(_timerSegmentStart!);
      _timerSegmentStart = null;
    }
    _timerPaused = true;
    notifyListeners();
  }

  void _resumeTimer() {
    if (!_timerPaused || !_isRecording) return;
    _timerSegmentStart = DateTime.now();
    _timerPaused = false;
    notifyListeners();
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Begin a new recording session.
  Future<String?> startSession({
    String? subject,
    String? subjectId,
    required ModuleType module,
    required int channelCount,
    required int sampleRate,
    List<String>? channelLabels,
    List<bool>? enabledChannels,
  }) async {
    if (_isRecording && _module != module) {
      throw StateError(
        '${_module.displayName} is already recording. Stop it before starting '
        '${module.displayName}.',
      );
    }
    await stopSession();
    _subject = FileNamingService.sanitizeSubject(
      subject ?? subjectId ?? 'ANON',
    );
    _module = module;
    _sessionStart = DateTime.now();
    _segmentIndex = 1;
    _isRecording = true;
    _wasRecordingBeforeDisconnect = false;
    _accumulatedDuration = Duration.zero;
    _timerSegmentStart = DateTime.now();
    _timerPaused = false;
    _markerLog.clear();
    _startDurationTicker();
    unawaited(DeviceAwakeService.acquire());

    final recorder = _recorder;
    if (recorder == null) {
      await DeviceAwakeService.release();
      _stopDurationTicker();
      _isRecording = false;
      return null;
    }

    final path = await FileNamingService.edfPath(
      _subject,
      _module,
      _sessionStart!,
      part: 1,
      deviceName: _acq?.connectedDeviceLabel,
    );

    try {
      final recordPrimary =
          (_acq?.currentState == AcquisitionState.streaming &&
              _acq?.connectedDeviceKind != DeviceKind.generic) ||
          (!(_multiLsl?.isConnected ?? false) &&
              _acq?.connectedDeviceProfile == null);
      if (recordPrimary) {
        await recorder.startAtPath(
          path: path,
          subject: _subject,
          channelCount: channelCount,
          sampleRate: sampleRate,
          channelLabels: channelLabels,
          enabledChannels: enabledChannels,
          dcBlockElectrophysiology:
              _acq?.connectedDeviceProfile?.protocol ==
                  DeviceProtocol.xampBinary ||
              _acq?.connectedDeviceProfile?.protocol ==
                  DeviceProtocol.orbitJson,
        );
      }
      await _startConfiguredStreamRecorders(part: 1);
      await _startLslStreamRecorders(part: 1);
      await _startDirectDeviceRecorders(part: 1);
    } catch (_) {
      _isRecording = false;
      _timerSegmentStart = null;
      _stopDurationTicker();
      await DeviceAwakeService.release();
      rethrow;
    }

    notifyListeners();
    debugPrint('[SessionManager] Started segment 1 → $path');
    return recorder.isRecording
        ? path
        : _streamRecorders.values.firstOrNull?.path;
  }

  /// Stop the session entirely.
  Future<void> stopSession() async {
    if (!_isRecording) return;
    _isRecording = false;
    _wasRecordingBeforeDisconnect = false;
    _timerPaused = false;
    _timerSegmentStart = null;
    _accumulatedDuration = Duration.zero;
    _stopDurationTicker();
    await _stopCurrentSegment();
    await DeviceAwakeService.release();
    notifyListeners();
  }

  Future<void> stopRecording() => stopSession();

  Future<String?> startRecording({
    String? subject,
    String? subjectId,
    required ModuleType module,
    required int channelCount,
    required int sampleRate,
    List<String>? channelLabels,
    List<bool>? enabledChannels,
  }) => startSession(
    subject: subject ?? subjectId,
    module: module,
    channelCount: channelCount,
    sampleRate: sampleRate,
    channelLabels: channelLabels,
    enabledChannels: enabledChannels,
  );

  void recordEvent(String label, int code, {StreamMarker? marker}) {
    _recorder?.setMarker(code);
    for (final recorder in _streamRecorders.values) {
      recorder.setMarker(code);
    }
    _markerLog.add(
      marker ??
          StreamMarker(
            streamId: 'manual',
            source: 'CCS Mobile Studio',
            value: label,
            code: code,
            receivedAt: DateTime.now(),
          ),
    );
    debugPrint('[SessionManager] Event: $label ($code)');
  }

  Future<void> _stopCurrentSegment() async {
    final recorder = _recorder;
    final paths = <String>[];
    if (recorder != null && recorder.isRecording) {
      final path = await recorder.stop();
      if (path != null) paths.add(path);
    }
    for (final streamRecorder in _streamRecorders.values) {
      final path = await streamRecorder.stop();
      if (path != null) paths.add(path);
    }
    _streamRecorders.clear();
    await _exportMarkerCsv();
    if (paths.isEmpty) return;
    for (final path in paths) {
      final start = _sessionStart;
      final stem = start == null
          ? null
          : FileNamingService.stem(_subject, _module, start);
      await FileNamingService.exportToDownloads(
        path,
        subject: _subject,
        sessionStem: stem,
      );
      debugPrint(
        '[SessionManager] Segment closed → $path (exported to output folder)',
      );
    }
  }

  Future<void> _exportMarkerCsv() async {
    final start = _sessionStart;
    if (start == null || _markerLog.isEmpty) return;
    final path = await FileNamingService.markerCsvPath(
      _subject,
      _module,
      start,
    );
    String cell(Object? value) {
      final text = value?.toString() ?? '';
      return '"${text.replaceAll('"', '""')}"';
    }

    final rows = <String>[
      'received_iso,elapsed_seconds,source,stream_id,value,edf_code,lsl_timestamp',
      ..._markerLog.map((marker) {
        final elapsed =
            marker.receivedAt.difference(start).inMicroseconds / 1e6;
        return [
          cell(marker.receivedAt.toIso8601String()),
          elapsed.toStringAsFixed(6),
          cell(marker.source),
          cell(marker.streamId),
          cell(marker.value),
          marker.code,
          marker.lslTimestamp?.toStringAsFixed(9) ?? '',
        ].join(',');
      }),
    ];
    await File(path).writeAsString('${rows.join('\n')}\n', flush: true);
    await FileNamingService.exportToDownloads(
      path,
      subject: _subject,
      sessionStem: FileNamingService.stem(_subject, _module, start),
    );
  }

  Future<void> _startNextSegment() async {
    final start = _sessionStart;
    if (start == null || _recorder == null) return;
    _segmentIndex++;

    final path = await FileNamingService.edfPath(
      _subject,
      _module,
      start,
      part: _segmentIndex,
      deviceName: _acq?.connectedDeviceLabel,
    );

    // Get params from the recorder's previous session
    final rec = _recorder!;
    await rec.startAtPath(
      path: path,
      subject: _subject,
      channelCount: rec.channelCount,
      sampleRate: rec.sampleRate,
      channelLabels: rec.channelLabels,
      enabledChannels: rec.enabledChannels,
      dcBlockElectrophysiology: rec.dcBlockElectrophysiology,
    );
    await _startConfiguredStreamRecorders(part: _segmentIndex);
    await _startLslStreamRecorders(part: _segmentIndex);
    await _startDirectDeviceRecorders(part: _segmentIndex);
    debugPrint('[SessionManager] Started segment $_segmentIndex → $path');
    notifyListeners();
  }

  Future<void> _startLslStreamRecorders({required int part}) async {
    final streams = _multiLsl?.connectedStreamProfiles ?? const {};
    for (final entry in streams.entries) {
      if (entry.value.signalType == SignalType.marker) continue;
      final runtimeProfile = SignalStreamProfile.fromJson(entry.value.toJson())
        ..id = entry.key;
      final deviceId = entry.key.split(':').first;
      await _startStreamRecorder(
        DeviceProfile(
          id: deviceId,
          name: deviceId,
          transport: ConnectionTransport.lsl,
          protocol: DeviceProtocol.lsl,
          streams: [runtimeProfile],
        ),
        runtimeProfile,
        part,
      );
    }
  }

  Future<void> _startDirectDeviceRecorders({required int part}) async {
    final streams = _multiDevice?.connectedStreamProfiles ?? const {};
    for (final entry in streams.entries) {
      final runtime = SignalStreamProfile.fromJson(entry.value.toJson())
        ..id = entry.key;
      await _startStreamRecorder(
        DeviceProfile(
          id: entry.key.split(':').first,
          name: runtime.name,
          transport: ConnectionTransport.bluetoothLe,
          protocol: runtime.name.toUpperCase().startsWith('AXXSPU')
              ? DeviceProtocol.xampBinary
              : runtime.name.toUpperCase().startsWith('ORBIT')
              ? DeviceProtocol.orbitJson
              : DeviceProtocol.delimitedText,
          streams: [runtime],
        ),
        runtime,
        part,
      );
    }
  }

  Future<void> _startConfiguredStreamRecorders({required int part}) async {
    final acq = _acq;
    final start = _sessionStart;
    if (acq == null || start == null) return;
    final profile = acq.connectedDeviceProfile;
    final primaryId = acq.primaryRecordingStream?.id;
    if (profile == null) return;
    for (final stream in profile.enabledStreams) {
      if (profile.id == 'orbit' &&
          stream.signalType == SignalType.ppg &&
          (_settings?.combineCompatibleStreams ?? true)) {
        continue;
      }
      if (stream.id == primaryId && (_recorder?.isRecording ?? false)) continue;
      await _startStreamRecorder(profile, stream, part);
    }
  }

  Future<void> _startStreamRecorder(
    DeviceProfile device,
    SignalStreamProfile stream,
    int part,
  ) async {
    final start = _sessionStart;
    if (start == null) return;
    final recorder = SignalStreamEdfRecorder();
    final path = await FileNamingService.streamEdfPath(
      _subject,
      _module,
      start,
      '${device.id}-${stream.id}',
      part: part,
      deviceName: device.name,
      streamName: stream.name,
    );
    await recorder.start(
      path: path,
      subject: _subject,
      profile: stream,
      dcBlockElectrophysiology:
          device.protocol == DeviceProtocol.xampBinary ||
          device.protocol == DeviceProtocol.orbitJson,
    );
    _streamRecorders[stream.id] = recorder;
    debugPrint(
      '[SessionManager] ${stream.name} ${stream.sampleRate} Hz → $path',
    );
  }

  void _startDurationTicker() {
    _durationTicker?.cancel();
    _durationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isRecording && !_timerPaused) {
        notifyListeners();
      }
    });
  }

  void _stopDurationTicker() {
    _durationTicker?.cancel();
    _durationTicker = null;
  }

  @override
  void dispose() {
    _sampleSub?.cancel();
    _streamSampleSub?.cancel();
    _lslSampleSub?.cancel();
    _markerSub?.cancel();
    _multiDeviceSampleSub?.cancel();
    for (final recorder in _streamRecorders.values) {
      unawaited(recorder.stop());
    }
    _stopDurationTicker();
    unawaited(DeviceAwakeService.reset());
    super.dispose();
  }
}
