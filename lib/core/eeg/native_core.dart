import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../models/sleep_score.dart';

final class _NativeSleepScore extends Struct {
  @Bool()
  external bool ready;

  @Int32()
  external int stage;

  @Double()
  external double confidence;

  @Uint64()
  external int epochIndex;

  @Double()
  external double deltaPower;

  @Double()
  external double thetaPower;

  @Double()
  external double alphaPower;

  @Double()
  external double betaPower;

  @Double()
  external double artifactRatio;

  @Double()
  external double probWake;

  @Double()
  external double probN1;

  @Double()
  external double probN2;

  @Double()
  external double probN3;

  @Double()
  external double probREM;
}

class NativeCore {
  NativeCore._() {
    _lib = _openLibrary();
    _createSleepState = _lib
        .lookupFunction<
          Pointer<Void> Function(Double),
          Pointer<Void> Function(double)
        >('tn_create_sleep_state');
    _createSleepStateWithModel = _lib
        .lookupFunction<
          Pointer<Void> Function(Double, Pointer<Utf8>),
          Pointer<Void> Function(double, Pointer<Utf8>)
        >('tn_create_sleep_state_with_model');
    _freeSleepState = _lib
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('tn_free_sleep_state');
    _sleepStateUsesModel = _lib
        .lookupFunction<
          Bool Function(Pointer<Void>),
          bool Function(Pointer<Void>)
        >('tn_sleep_state_uses_model');
    _pushSample = _lib
        .lookupFunction<
          Bool Function(Pointer<Void>, Double, Pointer<_NativeSleepScore>),
          bool Function(Pointer<Void>, double, Pointer<_NativeSleepScore>)
        >('tn_push_sample');
    _edfOpen = _lib
        .lookupFunction<
          Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, IntPtr, IntPtr),
          Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, int, int)
        >('tn_edf_open');
    _edfPush = _lib
        .lookupFunction<
          Bool Function(Pointer<Void>, Pointer<Double>, IntPtr),
          bool Function(Pointer<Void>, Pointer<Double>, int)
        >('tn_edf_push_sample');
    _edfClose = _lib
        .lookupFunction<
          Bool Function(Pointer<Void>),
          bool Function(Pointer<Void>)
        >('tn_edf_close');
    _setScoringStep = _lib
        .lookupFunction<
          Void Function(Pointer<Void>, Double),
          void Function(Pointer<Void>, double)
        >('tn_set_scoring_step');
    try {
      _edfOpenWithLabels = _lib
          .lookupFunction<
            Pointer<Void> Function(
              Pointer<Utf8>, // path
              Pointer<Utf8>, // subject
              Pointer<Pointer<Utf8>>, // channelNames
              Pointer<Pointer<Utf8>>, // physicalDimensions
              Pointer<Pointer<Utf8>>, // prefilters
              Pointer<Pointer<Utf8>>, // transducers
              IntPtr, // channelCount
              IntPtr, // sampleRate
            ),
            Pointer<Void> Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              int,
              int,
            )
          >('tn_edf_open_with_labels');
    } catch (_) {}
    try {
      _edfOpenWithLabelsAndRanges = _lib
          .lookupFunction<
            Pointer<Void> Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Double>,
              Pointer<Double>,
              IntPtr,
              IntPtr,
            ),
            Pointer<Void> Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Double>,
              Pointer<Double>,
              int,
              int,
            )
          >('tn_edf_open_with_labels_and_ranges');
    } catch (_) {}
    try {
      _edfOpenWithLabelsAndRangesF64 = _lib
          .lookupFunction<
            Pointer<Void> Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Double>,
              Pointer<Double>,
              IntPtr,
              Double,
            ),
            Pointer<Void> Function(
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Pointer<Utf8>>,
              Pointer<Double>,
              Pointer<Double>,
              int,
              double,
            )
          >('tn_edf_open_with_labels_and_ranges_f64');
    } catch (_) {}
  }

  static final NativeCore instance = NativeCore._();

  late final DynamicLibrary _lib;
  late final Pointer<Void> Function(double) _createSleepState;
  late final Pointer<Void> Function(double, Pointer<Utf8>)
  _createSleepStateWithModel;
  late final void Function(Pointer<Void>) _freeSleepState;
  late final bool Function(Pointer<Void>) _sleepStateUsesModel;
  late final bool Function(Pointer<Void>, double, Pointer<_NativeSleepScore>)
  _pushSample;
  late final Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, int, int)
  _edfOpen;
  late final bool Function(Pointer<Void>, Pointer<Double>, int) _edfPush;
  late final bool Function(Pointer<Void>) _edfClose;
  late final void Function(Pointer<Void>, double) _setScoringStep;
  Pointer<Void> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    int,
    int,
  )?
  _edfOpenWithLabels;
  Pointer<Void> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Pointer<Double>,
    Pointer<Double>,
    int,
    int,
  )?
  _edfOpenWithLabelsAndRanges;
  Pointer<Void> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Pointer<Double>,
    Pointer<Double>,
    int,
    double,
  )?
  _edfOpenWithLabelsAndRangesF64;

  DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libtrain_nidra_core.so');
    }
    if (Platform.isMacOS) {
      final executableDirectory = File(Platform.resolvedExecutable).parent;
      final bundledLibrary = File(
        '${executableDirectory.parent.path}/Frameworks/'
        'libtrain_nidra_core.dylib',
      );
      try {
        return DynamicLibrary.open(bundledLibrary.path);
      } catch (_) {
        // Keep command-line and local debug execution convenient.
        return DynamicLibrary.open(
          'rust/target/debug/libtrain_nidra_core.dylib',
        );
      }
    }
    if (Platform.isIOS) return DynamicLibrary.process();
    if (Platform.isWindows) {
      return DynamicLibrary.open('train_nidra_core.dll');
    }
    if (Platform.isLinux) {
      return DynamicLibrary.open('rust/target/debug/libtrain_nidra_core.so');
    }
    return DynamicLibrary.process();
  }

  Pointer<Void> createSleepState(double sampleRate, {String? modelPath}) {
    if (modelPath == null || modelPath.isEmpty) {
      return _createSleepState(sampleRate);
    }
    final modelPathPtr = modelPath.toNativeUtf8();
    try {
      return _createSleepStateWithModel(sampleRate, modelPathPtr);
    } finally {
      calloc.free(modelPathPtr);
    }
  }

  void freeSleepState(Pointer<Void> state) {
    if (state != nullptr) {
      _freeSleepState(state);
    }
  }

  bool sleepStateUsesModel(Pointer<Void> state) {
    if (state != nullptr) {
      return _sleepStateUsesModel(state);
    }
    return false;
  }

  void setScoringStep(Pointer<Void> state, double stepSeconds) {
    if (state != nullptr) {
      _setScoringStep(state, stepSeconds);
    }
  }

  SleepScoreResult? pushSample(Pointer<Void> state, double sampleUv) {
    if (state == nullptr) return null;
    final out = calloc<_NativeSleepScore>();
    try {
      final ready = _pushSample(state, sampleUv, out);
      if (!ready || !out.ref.ready) return null;
      return SleepScoreResult(
        stage: SleepStage.fromIndex(out.ref.stage),
        confidence: out.ref.confidence,
        epochIndex: out.ref.epochIndex,
        deltaPower: out.ref.deltaPower,
        thetaPower: out.ref.thetaPower,
        alphaPower: out.ref.alphaPower,
        betaPower: out.ref.betaPower,
        artifactRatio: out.ref.artifactRatio,
        probWake: out.ref.probWake,
        probN1: out.ref.probN1,
        probN2: out.ref.probN2,
        probN3: out.ref.probN3,
        probREM: out.ref.probREM,
      );
    } finally {
      calloc.free(out);
    }
  }

  Pointer<Void> openEdf({
    required String path,
    required String subject,
    required int channelCount,
    required int sampleRate,
  }) {
    final pathPtr = path.toNativeUtf8();
    final subjectPtr = subject.toNativeUtf8();
    try {
      return _edfOpen(pathPtr, subjectPtr, channelCount, sampleRate);
    } finally {
      calloc.free(pathPtr);
      calloc.free(subjectPtr);
    }
  }

  bool pushEdfSample(Pointer<Void> writer, List<double> samples) {
    if (writer == nullptr) return false;
    final ptr = calloc<Double>(samples.length);
    try {
      for (var i = 0; i < samples.length; i++) {
        ptr[i] = samples[i];
      }
      return _edfPush(writer, ptr, samples.length);
    } finally {
      calloc.free(ptr);
    }
  }

  bool closeEdf(Pointer<Void> writer) {
    if (writer == nullptr) return false;
    return _edfClose(writer);
  }

  Pointer<Void> openEdfWithLabels(
    String path,
    String subject,
    int channelCount,
    int sampleRate,
    List<String> channelNames,
    List<String> physicalDimensions,
    List<String> prefilters,
    List<String> transducers, {
    List<double>? physicalMinimums,
    List<double>? physicalMaximums,
  }) {
    final fn = _edfOpenWithLabels;
    if (fn == null) {
      return openEdf(
        path: path,
        subject: subject,
        channelCount: channelCount,
        sampleRate: sampleRate,
      );
    }

    Pointer<Pointer<Utf8>> _allocStringArray(List<String> strings) {
      final arr = calloc<Pointer<Utf8>>(strings.length);
      for (var i = 0; i < strings.length; i++) {
        arr[i] = strings[i].toNativeUtf8();
      }
      return arr;
    }

    void _freeStringArray(Pointer<Pointer<Utf8>> arr, int length) {
      for (var i = 0; i < length; i++) {
        calloc.free(arr[i]);
      }
      calloc.free(arr);
    }

    final pathPtr = path.toNativeUtf8();
    final subjectPtr = subject.toNativeUtf8();
    final namesArr = _allocStringArray(channelNames);
    final dimsArr = _allocStringArray(physicalDimensions);
    final prefsArr = _allocStringArray(prefilters);
    final transArr = _allocStringArray(transducers);
    final minArr = calloc<Double>(channelCount);
    final maxArr = calloc<Double>(channelCount);
    for (var i = 0; i < channelCount; i++) {
      minArr[i] = physicalMinimums != null && i < physicalMinimums.length
          ? physicalMinimums[i]
          : -250000.0;
      maxArr[i] = physicalMaximums != null && i < physicalMaximums.length
          ? physicalMaximums[i]
          : 250000.0;
    }

    try {
      final rangedFn = _edfOpenWithLabelsAndRanges;
      if (rangedFn != null) {
        return rangedFn(
          pathPtr,
          subjectPtr,
          namesArr,
          dimsArr,
          prefsArr,
          transArr,
          minArr,
          maxArr,
          channelCount,
          sampleRate,
        );
      }
      return fn(
        pathPtr,
        subjectPtr,
        namesArr,
        dimsArr,
        prefsArr,
        transArr,
        channelCount,
        sampleRate,
      );
    } finally {
      calloc.free(pathPtr);
      calloc.free(subjectPtr);
      _freeStringArray(namesArr, channelNames.length);
      _freeStringArray(dimsArr, physicalDimensions.length);
      _freeStringArray(prefsArr, prefilters.length);
      _freeStringArray(transArr, transducers.length);
      calloc.free(minArr);
      calloc.free(maxArr);
    }
  }

  Pointer<Void> openEdfWithLabelsAtRate(
    String path,
    String subject,
    int channelCount,
    double sampleRate,
    List<String> channelNames,
    List<String> physicalDimensions,
    List<String> prefilters,
    List<String> transducers, {
    required List<double> physicalMinimums,
    required List<double> physicalMaximums,
  }) {
    final fn = _edfOpenWithLabelsAndRangesF64;
    if (fn == null) {
      return openEdfWithLabels(
        path,
        subject,
        channelCount,
        sampleRate.round(),
        channelNames,
        physicalDimensions,
        prefilters,
        transducers,
        physicalMinimums: physicalMinimums,
        physicalMaximums: physicalMaximums,
      );
    }

    Pointer<Pointer<Utf8>> allocStrings(List<String> values) {
      final array = calloc<Pointer<Utf8>>(values.length);
      for (var i = 0; i < values.length; i++) {
        array[i] = values[i].toNativeUtf8();
      }
      return array;
    }

    void freeStrings(Pointer<Pointer<Utf8>> values, int count) {
      for (var i = 0; i < count; i++) {
        calloc.free(values[i]);
      }
      calloc.free(values);
    }

    final pathPtr = path.toNativeUtf8();
    final subjectPtr = subject.toNativeUtf8();
    final names = allocStrings(channelNames);
    final dimensions = allocStrings(physicalDimensions);
    final filters = allocStrings(prefilters);
    final sensors = allocStrings(transducers);
    final minimums = calloc<Double>(channelCount);
    final maximums = calloc<Double>(channelCount);
    for (var i = 0; i < channelCount; i++) {
      minimums[i] = physicalMinimums[i];
      maximums[i] = physicalMaximums[i];
    }
    try {
      return fn(
        pathPtr,
        subjectPtr,
        names,
        dimensions,
        filters,
        sensors,
        minimums,
        maximums,
        channelCount,
        sampleRate,
      );
    } finally {
      calloc.free(pathPtr);
      calloc.free(subjectPtr);
      freeStrings(names, channelNames.length);
      freeStrings(dimensions, physicalDimensions.length);
      freeStrings(filters, prefilters.length);
      freeStrings(sensors, transducers.length);
      calloc.free(minimums);
      calloc.free(maximums);
    }
  }
}
