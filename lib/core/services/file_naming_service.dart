import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/module_type.dart';

/// Centralised file naming service.
///
/// All output files follow the convention:
///   `subject_MODULE_yyyyMMdd_HHmmss[_partN].ext`
///
/// where MODULE is one of: NIDRA, ANGEL, WM, EEG.
class FileNamingService {
  static String? _configuredOutputDirectory;

  /// Sets the operator-visible root used for exported session folders.
  /// Passing null or an empty string restores the platform default.
  static void configureOutputDirectory(String? path) {
    final trimmed = path?.trim() ?? '';
    _configuredOutputDirectory = trimmed.isEmpty ? null : trimmed;
  }

  /// The folder shown in Settings. Session exports are organized below this
  /// root as `<subject>/<session stem>/...`.
  static Future<Directory> outputRootDirectory() async {
    final configured = _configuredOutputDirectory;
    if (configured != null) {
      final dir = Directory(configured);
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download/CCS_MobileStudio');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }
    final documents = await getApplicationDocumentsDirectory();
    final dir = Directory('${documents.path}/CCS_MobileStudio_Output');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
  // ── Timestamp helpers ───────────────────────────────────────────────────────

  /// Format a [DateTime] as a filesystem-safe timestamp.
  /// Result: `yyyyMMdd_HHmmss`
  static String formatTimestamp(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '${y}${mo}${d}_$h$mi$s';
  }

  /// Sanitise a subject/participant code for use in file names.
  /// Allows only [A-Za-z0-9_-]; everything else becomes `_`.
  static String sanitizeSubject(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 'unknown';
    return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
  }

  /// Build the base stem used by all files for a session.
  /// e.g. `S004_ANGEL_20260630_063720`
  static String stem(String subject, ModuleType module, DateTime sessionStart) {
    return '${sanitizeSubject(subject)}_${module.fileTag}_${formatTimestamp(sessionStart)}';
  }

  // ── Path builders ───────────────────────────────────────────────────────────

  /// EDF recording directory (internal app storage).
  static Future<Directory> _recordingsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/recordings');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Behavioural data directory (internal app storage).
  static Future<Directory> _dataDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/data');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Build an EDF file path for a recording segment.
  ///
  /// [part] – segment number:
  ///   - `1` → first segment (no suffix).
  ///   - `2+` → reconnect continuation: `_part<N>` appended.
  static Future<String> edfPath(
    String subject,
    ModuleType module,
    DateTime sessionStart, {
    int part = 1,
    String? deviceName,
  }) async {
    final dir = await _recordingsDir();
    return '${dir.path}/${edfFilename(subject, module, sessionStart, part: part, deviceName: deviceName)}';
  }

  static String edfFilename(
    String subject,
    ModuleType module,
    DateTime sessionStart, {
    int part = 1,
    String? deviceName,
  }) {
    final base = stem(subject, module, sessionStart);
    final device = deviceName == null || deviceName.trim().isEmpty
        ? ''
        : '_device-${sanitizeSubject(deviceName)}';
    final suffix = part > 1 ? '_part$part' : '';
    return '$base$device$suffix.edf';
  }

  /// EDF path for fNIRS data (adds `_nirs` to distinguish from EEG EDF).
  static Future<String> nirsEdfPath(
    String subject,
    ModuleType module,
    DateTime sessionStart, {
    int part = 1,
  }) async {
    final dir = await _recordingsDir();
    final base = stem(subject, module, sessionStart);
    final suffix = part > 1 ? '_part$part' : '';
    return '${dir.path}/${base}_nirs$suffix.edf';
  }

  /// EDF path for a separately clocked configured signal stream.
  static Future<String> streamEdfPath(
    String subject,
    ModuleType module,
    DateTime sessionStart,
    String streamId, {
    int part = 1,
    String? deviceName,
    String? streamName,
  }) async {
    final dir = await _recordingsDir();
    return '${dir.path}/${streamEdfFilename(subject, module, sessionStart, streamId, part: part, deviceName: deviceName, streamName: streamName)}';
  }

  static String streamEdfFilename(
    String subject,
    ModuleType module,
    DateTime sessionStart,
    String streamId, {
    int part = 1,
    String? deviceName,
    String? streamName,
  }) {
    final base = stem(subject, module, sessionStart);
    final safeStream = sanitizeSubject(streamId);
    final device = deviceName == null || deviceName.trim().isEmpty
        ? ''
        : '_device-${sanitizeSubject(deviceName)}';
    final displayStream = streamName == null || streamName.trim().isEmpty
        ? safeStream
        : sanitizeSubject(streamName);
    final suffix = part > 1 ? '_part$part' : '';
    return '${base}${device}_stream-$displayStream$suffix.edf';
  }

  /// CSV behavioural log path.
  static Future<String> csvPath(
    String subject,
    ModuleType module,
    DateTime sessionStart,
  ) async {
    final dir = await _dataDir();
    return '${dir.path}/${stem(subject, module, sessionStart)}.csv';
  }

  static Future<String> markerCsvPath(
    String subject,
    ModuleType module,
    DateTime sessionStart,
  ) async {
    final dir = await _dataDir();
    return '${dir.path}/${stem(subject, module, sessionStart)}_markers.csv';
  }

  /// JSON epoch/score log path.
  static Future<String> jsonPath(
    String subject,
    ModuleType module,
    DateTime sessionStart,
  ) async {
    final dir = await _dataDir();
    return '${dir.path}/${stem(subject, module, sessionStart)}.json';
  }

  /// PDF summary path.
  static Future<String> pdfPath(
    String subject,
    ModuleType module,
    DateTime sessionStart,
  ) async {
    final dir = await _dataDir();
    return '${dir.path}/${stem(subject, module, sessionStart)}.pdf';
  }

  // ── Export helpers (copy to the operator-visible output folder) ─────────────

  static String sessionStemFromFilename(String filename) {
    final withoutExt = filename.replaceFirst(RegExp(r'\.[^.]+$'), '');
    return withoutExt
        .replaceFirst(RegExp(r'_stream-[A-Za-z0-9_-]+(_part\d+)?$'), '')
        .replaceFirst(RegExp(r'_device-[A-Za-z0-9_-]+(_part\d+)?$'), '')
        .replaceFirst(RegExp(r'_nirs(_part\d+)?$'), '')
        .replaceFirst(RegExp(r'_markers$'), '')
        .replaceFirst(RegExp(r'_part\d+$'), '');
  }

  static String subjectFromStem(String stem) {
    for (final module in ModuleType.values) {
      final separator = '_${module.fileTag}_';
      final index = stem.indexOf(separator);
      if (index > 0) return sanitizeSubject(stem.substring(0, index));
    }
    final parts = stem.split('_');
    return parts.isEmpty ? 'unknown' : sanitizeSubject(parts.first);
  }

  /// Copies files left in app-private storage to the public session folders.
  ///
  /// A hard shutdown cannot run the normal stop/export path. The native EDF
  /// writer keeps completed records valid on disk, so the next app launch can
  /// recover those files by exporting them here. Existing identical exports
  /// are skipped; a different-sized destination is replaced with the private
  /// source, which is the most recently written copy.
  static Future<List<String>> recoverPendingFiles() async {
    final recovered = <String>[];
    final recordingsDir = await _recordingsDir();
    final dataDir = await _dataDir();
    final sources = <Directory>[recordingsDir, dataDir];

    for (final sourceDir in sources) {
      await for (final entity in sourceDir.list()) {
        if (entity is! File) continue;
        final filename = entity.path.split('/').last;
        if (sourceDir.path == dataDir.path &&
            !_hasCanonicalSessionFilename(filename)) {
          continue;
        }
        final stem = sessionStemFromFilename(filename);
        final subject = subjectFromStem(stem);
        try {
          final destinationDir = await _downloadDir(
            subject: subject,
            sessionStem: stem,
          );
          final destination = File('${destinationDir.path}/$filename');
          final sourceSize = await entity.length();
          if (await destination.exists() &&
              await destination.length() == sourceSize) {
            continue;
          }
          await entity.copy(destination.path);
          recovered.add(destination.path);
        } catch (_) {
          // Recovery is best-effort and will be retried on the next launch.
        }
      }
    }
    return recovered;
  }

  static bool _hasCanonicalSessionFilename(String filename) {
    final tags = ModuleType.values.map((module) => module.fileTag).join('|');
    return RegExp(
      '^.+_($tags)_[0-9]{8}_[0-9]{6}(?:_markers|_part[0-9]+)?\\.(?:csv|json|pdf)\$',
    ).hasMatch(filename);
  }

  static Future<Directory> _downloadDir({
    String? subject,
    String? sessionStem,
  }) async {
    final safeSubject = sanitizeSubject(subject ?? 'unknown');
    final safeSession = sanitizeSubject(sessionStem ?? 'unsorted');
    final outputRoot = await outputRootDirectory();
    final dir = Directory('${outputRoot.path}/$safeSubject/$safeSession');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Copy a file to the configured output folder for easy access.
  /// Returns the destination path, or null if copy failed.
  static Future<String?> exportToDownloads(
    String sourcePath, {
    String? subject,
    String? sessionStem,
  }) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) return null;
      final filename = sourcePath.split('/').last;
      final stem = sessionStem ?? sessionStemFromFilename(filename);
      final dir = await _downloadDir(
        subject: subject ?? subjectFromStem(stem),
        sessionStem: stem,
      );
      final dest = '${dir.path}/$filename';
      await sourceFile.copy(dest);
      return dest;
    } catch (e) {
      return null;
    }
  }
}
