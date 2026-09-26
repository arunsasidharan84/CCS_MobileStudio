import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import 'models.dart';

class HeartSyncPlaybackReceipt {
  const HeartSyncPlaybackReceipt({
    required this.requestedAt,
    required this.acknowledgedAt,
  });

  final DateTime requestedAt;
  final DateTime acknowledgedAt;
}

class HeartSyncStimulusService {
  HeartSyncStimulusService()
    : _players = {
        HeartSyncStimulusKind.frequent: AudioPlayer()
          ..setReleaseMode(ReleaseMode.stop),
        HeartSyncStimulusKind.rare: AudioPlayer()
          ..setReleaseMode(ReleaseMode.stop),
      };

  final Map<HeartSyncStimulusKind, AudioPlayer> _players;
  final Map<String, Uint8List> _toneCache = {};
  final Map<HeartSyncStimulusKind, String> _preparedKeys = {};
  final List<File> _generatedToneFiles = [];

  /// Resolve, decode and preload both stimuli before real-time scheduling.
  ///
  /// `BytesSource` is not supported consistently by Darwin's AVPlayer backend.
  /// Generated tones are therefore written once to the app's temporary folder
  /// and loaded through the same file-backed path as operator-selected sounds.
  Future<void> prepare(HeartSyncConfig config) async {
    if (config.stimulusMode != HeartSyncStimulusMode.tones) return;
    await _prepareKind(HeartSyncStimulusKind.frequent, config);
    await _prepareKind(HeartSyncStimulusKind.rare, config);
  }

  Future<void> _prepareKind(
    HeartSyncStimulusKind kind,
    HeartSyncConfig config,
  ) async {
    final selectedPath = kind == HeartSyncStimulusKind.frequent
        ? config.frequentFilePath.trim()
        : config.rareFilePath.trim();
    final frequency = kind == HeartSyncStimulusKind.frequent
        ? config.frequentToneHz
        : config.rareToneHz;
    final key = selectedPath.isNotEmpty
        ? 'file:$selectedPath'
        : 'tone:$frequency:${config.toneDurationMs}';
    if (_preparedKeys[kind] == key) return;

    late final File sourceFile;
    if (selectedPath.isNotEmpty) {
      sourceFile = File(selectedPath);
      if (!await sourceFile.exists()) {
        throw StateError(
          '${kind.name} sound file does not exist: $selectedPath',
        );
      }
    } else {
      final bytes = _toneCache.putIfAbsent(
        key,
        () => _wavTone(frequency, config.toneDurationMs),
      );
      final folder = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}ccs_heartsync_audio',
      );
      await folder.create(recursive: true);
      sourceFile = File(
        '${folder.path}${Platform.pathSeparator}'
        '${kind.name}_${frequency.round()}_${config.toneDurationMs}.wav',
      );
      await sourceFile.writeAsBytes(bytes, flush: true);
      if (!_generatedToneFiles.any((file) => file.path == sourceFile.path)) {
        _generatedToneFiles.add(sourceFile);
      }
    }

    await _players[kind]!.setSource(DeviceFileSource(sourceFile.path));
    _preparedKeys[kind] = key;
  }

  Future<HeartSyncPlaybackReceipt> present(
    HeartSyncStimulusKind kind,
    HeartSyncConfig config,
  ) async {
    if (config.stimulusMode != HeartSyncStimulusMode.tones) {
      final now = DateTime.now();
      return HeartSyncPlaybackReceipt(requestedAt: now, acknowledgedAt: now);
    }
    await _prepareKind(kind, config);
    final player = _players[kind]!;
    final requestedAt = DateTime.now();
    // Source decoding happened in prepare(). Only reset and resume remain on
    // the timing-critical path.
    await player.seek(Duration.zero);
    await player.resume();
    return HeartSyncPlaybackReceipt(
      requestedAt: requestedAt,
      acknowledgedAt: DateTime.now(),
    );
  }

  Uint8List _wavTone(double frequency, int durationMs) {
    const sampleRate = 44100;
    final count = (sampleRate * durationMs / 1000).round();
    final dataSize = count * 2;
    final bytes = ByteData(44 + dataSize);
    void text(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    text(0, 'RIFF');
    bytes.setUint32(4, 36 + dataSize, Endian.little);
    text(8, 'WAVE');
    text(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    text(36, 'data');
    bytes.setUint32(40, dataSize, Endian.little);
    final ramp = min(220, count ~/ 4);
    for (var i = 0; i < count; i++) {
      final envelope = min(
        1.0,
        min(i / max(1, ramp), (count - i) / max(1, ramp)),
      );
      final value =
          (sin(2 * pi * frequency * i / sampleRate) * envelope * 0.65 * 32767)
              .round();
      bytes.setInt16(44 + i * 2, value, Endian.little);
    }
    return bytes.buffer.asUint8List();
  }

  Future<void> dispose() async {
    for (final player in _players.values) {
      await player.dispose();
    }
    for (final file in _generatedToneFiles) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Temporary-file cleanup must not hide experiment results.
      }
    }
  }
}
