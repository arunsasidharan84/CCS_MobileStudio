import 'dart:io';

import 'package:csv/csv.dart';

import '../../core/models/device_profile.dart';

class HeartSyncReplayDatum {
  const HeartSyncReplayDatum({
    required this.offset,
    required this.signalType,
    required this.channelName,
    required this.value,
    this.markerCode,
  });

  final Duration offset;
  final SignalType signalType;
  final String channelName;
  final double value;
  final int? markerCode;
}

/// Reads a timestamped CSV into a deterministic, real-time replay sequence.
///
/// Supported inputs include HeartSync's `timestamp,value` cardiac export and
/// combined recordings containing `timestamp_utc`, `PPG`, `ECG`, and `marker`.
class HeartSyncCardiacReplay {
  static Future<List<HeartSyncReplayDatum>> load(
    String path, {
    required SignalType valueColumnType,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      throw StateError('Cardiac replay file does not exist: $path');
    }
    final rows = Csv(dynamicTyping: false).decode(await file.readAsString());
    if (rows.length < 2) {
      throw const FormatException('Cardiac replay CSV has no data rows.');
    }
    final headers = rows.first
        .map((value) => _normalized('$value'))
        .toList(growable: false);
    final timestampIndex = _firstIndex(headers, const [
      'timestamp',
      'timestamputc',
      'time',
      'seconds',
      'elapsedseconds',
    ]);
    if (timestampIndex < 0) {
      throw const FormatException(
        'Replay CSV needs timestamp, timestamp_utc, time, or seconds.',
      );
    }
    final ppgIndex = _firstIndex(headers, const [
      'ppg',
      'pulse',
      'pleth',
      'photoplethysmogram',
    ]);
    final ecgIndex = _firstIndex(headers, const ['ecg', 'ekg']);
    final valueIndex = _firstIndex(headers, const ['value', 'signal']);
    final markerIndex = _firstIndex(headers, const [
      'marker',
      'markercode',
      'event',
    ]);
    if (ppgIndex < 0 && ecgIndex < 0 && valueIndex < 0) {
      throw const FormatException(
        'Replay CSV needs a PPG, ECG, value, or signal column.',
      );
    }

    final parsed =
        <({DateTime? time, double? seconds, List<_ReplayValue> values})>[];
    for (final row in rows.skip(1)) {
      if (timestampIndex >= row.length) continue;
      final timestampText = '${row[timestampIndex]}'.trim();
      final absolute = DateTime.tryParse(timestampText);
      final seconds = absolute == null ? double.tryParse(timestampText) : null;
      if (absolute == null && seconds == null) continue;
      final marker = markerIndex >= 0 && markerIndex < row.length
          ? double.tryParse('${row[markerIndex]}')?.round()
          : null;
      final values = <_ReplayValue>[];
      void add(int index, SignalType type, String label) {
        if (index < 0 || index >= row.length) return;
        final value = double.tryParse('${row[index]}');
        if (value != null && value.isFinite) {
          values.add(_ReplayValue(type, label, value, marker));
        }
      }

      add(ppgIndex, SignalType.ppg, 'PPG');
      add(ecgIndex, SignalType.ecg, 'ECG');
      if (ppgIndex < 0 && ecgIndex < 0) {
        add(
          valueIndex,
          valueColumnType,
          valueColumnType == SignalType.ppg ? 'PPG' : 'ECG',
        );
      }
      if (values.isNotEmpty) {
        parsed.add((time: absolute, seconds: seconds, values: values));
      }
    }
    if (parsed.isEmpty) {
      throw const FormatException('Replay CSV contains no finite samples.');
    }

    final firstTime = parsed.first.time;
    final firstSeconds = parsed.first.seconds;
    final output = <HeartSyncReplayDatum>[];
    for (final item in parsed) {
      final offsetSeconds = firstTime != null && item.time != null
          ? item.time!.difference(firstTime).inMicroseconds / 1000000
          : (item.seconds! - firstSeconds!);
      if (offsetSeconds < 0) continue;
      final offset = Duration(microseconds: (offsetSeconds * 1000000).round());
      for (final value in item.values) {
        output.add(
          HeartSyncReplayDatum(
            offset: offset,
            signalType: value.type,
            channelName: value.label,
            value: value.value,
            markerCode: value.marker,
          ),
        );
      }
    }
    return output;
  }

  static int _firstIndex(List<String> headers, List<String> candidates) {
    for (final candidate in candidates) {
      final index = headers.indexOf(candidate);
      if (index >= 0) return index;
    }
    return -1;
  }

  static String _normalized(String value) =>
      value.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
}

class _ReplayValue {
  const _ReplayValue(this.type, this.label, this.value, this.marker);

  final SignalType type;
  final String label;
  final double value;
  final int? marker;
}
