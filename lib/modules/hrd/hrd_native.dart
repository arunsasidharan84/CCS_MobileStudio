import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

DynamicLibrary _library() {
  if (Platform.isAndroid) return DynamicLibrary.open('libtrain_nidra_core.so');
  if (Platform.isWindows) return DynamicLibrary.open('train_nidra_core.dll');
  if (Platform.isIOS) return DynamicLibrary.process();
  if (Platform.isMacOS) {
    final folder = File(Platform.resolvedExecutable).parent.parent.path;
    try {
      return DynamicLibrary.open(
        '$folder/Frameworks/libtrain_nidra_core.dylib',
      );
    } catch (_) {
      return DynamicLibrary.open('rust/target/debug/libtrain_nidra_core.dylib');
    }
  }
  return DynamicLibrary.open('rust/target/debug/libtrain_nidra_core.so');
}

/// Called in a background isolate. Native handles never cross isolate boundaries.
Map<String, Object> hrdCompute(Map<String, Object> request) {
  final lib = _library();
  if (request['simulation'] == true) {
    final simulate = lib
        .lookupFunction<
          IntPtr Function(Double, Double, Bool, Pointer<Double>, IntPtr),
          int Function(double, double, bool, Pointer<Double>, int)
        >('tn_hrd_simulate');
    final fs = request['sampleRate'] as double;
    final seconds = request['seconds'] as double;
    final ecg = request['ecg'] as bool;
    final n = simulate(fs, seconds, ecg, nullptr, 0);
    if (n == 0) throw StateError('Invalid simulation configuration');
    final out = calloc<Double>(n);
    try {
      simulate(fs, seconds, ecg, out, n);
      return {'samples': out.asTypedList(n).toList()};
    } finally {
      calloc.free(out);
    }
  }
  final create = lib
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'tn_hrd_create',
      );
  final free = lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('tn_hrd_free');
  final update = lib
      .lookupFunction<
        Bool Function(Pointer<Void>, Double, Int32),
        bool Function(Pointer<Void>, double, int)
      >('tn_hrd_update');
  final next = lib
      .lookupFunction<
        Double Function(Pointer<Void>),
        double Function(Pointer<Void>)
      >('tn_hrd_next');
  final estimate = lib
      .lookupFunction<
        Bool Function(Pointer<Void>, Pointer<Double>),
        bool Function(Pointer<Void>, Pointer<Double>)
      >('tn_hrd_estimate');
  final state = create();
  final out = calloc<Double>(5);
  try {
    final history = request['history'] as List<List<double>>;
    for (final row in history) {
      if (!update(state, row[0], row[1].toInt())) {
        throw StateError('Invalid Psi response');
      }
    }
    estimate(state, out);
    final result = <String, Object>{'estimate': out.asTypedList(4).toList()};
    if (request.containsKey('samples')) {
      final values = request['samples'] as List<double>;
      final input = calloc<Double>(values.length);
      final cleaned = calloc<Double>(values.length);
      final peaks = calloc<Double>(values.length);
      try {
        input.asTypedList(values.length).setAll(0, values);
        final analyze = lib
            .lookupFunction<
              Bool Function(
                Pointer<Double>,
                IntPtr,
                Double,
                Bool,
                Pointer<Double>,
                Pointer<Double>,
                Pointer<Double>,
              ),
              bool Function(
                Pointer<Double>,
                int,
                double,
                bool,
                Pointer<Double>,
                Pointer<Double>,
                Pointer<Double>,
              )
            >('tn_hrd_analyze');
        if (!analyze(
          input,
          values.length,
          request['sampleRate'] as double,
          request['ecg'] as bool,
          cleaned,
          peaks,
          out,
        )) {
          throw StateError('Insufficient or invalid cardiac samples');
        }
        result['stats'] = out.asTypedList(5).toList();
        final rates = calloc<Double>(values.length);
        try {
          final rate = lib
              .lookupFunction<
                Bool Function(
                  Pointer<Double>,
                  IntPtr,
                  Double,
                  Double,
                  Bool,
                  Pointer<Double>,
                ),
                bool Function(
                  Pointer<Double>,
                  int,
                  double,
                  double,
                  bool,
                  Pointer<Double>,
                )
              >('tn_hrd_rates');
          rate(
            peaks,
            values.length,
            request['sampleRate'] as double,
            out[0],
            request['ecg'] as bool,
            rates,
          );
          result['rates'] = rates.asTypedList(values.length).toList();
        } finally {
          calloc.free(rates);
        }

        result['cleaned'] = cleaned.asTypedList(values.length).toList();
        result['peaks'] = peaks.asTypedList(values.length).toList();
        result['delta'] = request['catchDelta'] ?? next(state);
      } finally {
        calloc.free(input);
        calloc.free(cleaned);
        calloc.free(peaks);
      }
    }
    if (request.containsKey('bpm')) {
      final bpm = request['bpm'] as double;
      final seconds = request['seconds'] as double;
      final audio = lib
          .lookupFunction<
            IntPtr Function(Double, Double, Pointer<Int16>, IntPtr),
            int Function(double, double, Pointer<Int16>, int)
          >('tn_hrd_audio');
      final count = audio(bpm, seconds, nullptr, 0);
      if (count == 0) throw StateError('Invalid audio rate');
      final pcm = calloc<Int16>(count);
      try {
        audio(bpm, seconds, pcm, count);
        final bytes = ByteData(44 + count * 2);
        void text(int offset, String s) {
          for (var i = 0; i < s.length; i++) {
            bytes.setUint8(offset + i, s.codeUnitAt(i));
          }
        }

        text(0, 'RIFF');
        bytes.setUint32(4, 36 + count * 2, Endian.little);
        text(8, 'WAVE');
        text(12, 'fmt ');
        bytes.setUint32(16, 16, Endian.little);
        bytes.setUint16(20, 1, Endian.little);
        bytes.setUint16(22, 1, Endian.little);
        bytes.setUint32(24, 44100, Endian.little);
        bytes.setUint32(28, 88200, Endian.little);
        bytes.setUint16(32, 2, Endian.little);
        bytes.setUint16(34, 16, Endian.little);
        text(36, 'data');
        bytes.setUint32(40, count * 2, Endian.little);
        for (var i = 0; i < count; i++) {
          bytes.setInt16(44 + i * 2, pcm[i], Endian.little);
        }
        result['audio'] = bytes.buffer.asUint8List();
      } finally {
        calloc.free(pcm);
      }
    }
    return result;
  } finally {
    free(state);
    calloc.free(out);
  }
}
