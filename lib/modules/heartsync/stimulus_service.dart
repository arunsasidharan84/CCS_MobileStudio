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

  Future<HeartSyncPlaybackReceipt> present(
    HeartSyncStimulusKind kind,
    HeartSyncConfig config,
  ) async {
    if (config.stimulusMode != HeartSyncStimulusMode.tones) {
      final now = DateTime.now();
      return HeartSyncPlaybackReceipt(requestedAt: now, acknowledgedAt: now);
    }
    final path = kind == HeartSyncStimulusKind.frequent
        ? config.frequentFilePath
        : config.rareFilePath;
    final player = _players[kind]!;
    if (path.isNotEmpty && await File(path).exists()) {
      final requestedAt = DateTime.now();
      await player.play(DeviceFileSource(path));
      return HeartSyncPlaybackReceipt(
        requestedAt: requestedAt,
        acknowledgedAt: DateTime.now(),
      );
    }
    final frequency = kind == HeartSyncStimulusKind.frequent
        ? config.frequentToneHz
        : config.rareToneHz;
    final cacheKey = '$frequency:${config.toneDurationMs}';
    final bytes = _toneCache.putIfAbsent(
      cacheKey,
      () => _wavTone(frequency, config.toneDurationMs),
    );
    final requestedAt = DateTime.now();
    await player.play(BytesSource(bytes));
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
  }
}
