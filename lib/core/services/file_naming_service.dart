import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/module_type.dart';

/// Centralised file naming service.
///
/// All output files follow the convention:
///   <subj>_<MODULE>_<yyyyMMdd_HHmmss>[_part<N>].<ext>
///
/// where MODULE is one of: NIDRA, ANGEL, WM, EEG.
class FileNamingService {
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
  }) async {
    final dir = await _recordingsDir();
    final base = stem(subject, module, sessionStart);
    final suffix = part > 1 ? '_part$part' : '';
    return '${dir.path}/$base$suffix.edf';
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

  /// CSV behavioural log path.
  static Future<String> csvPath(
    String subject,
    ModuleType module,
    DateTime sessionStart,
  ) async {
    final dir = await _dataDir();
    return '${dir.path}/${stem(subject, module, sessionStart)}.csv';
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

  // ── Export helpers (copy to Download folder on Android) ─────────────────────

  static String sessionStemFromFilename(String filename) {
    final withoutExt = filename.replaceFirst(RegExp(r'\.[^.]+$'), '');
    return withoutExt
        .replaceFirst(RegExp(r'_nirs(_part\d+)?$'), '')
        .replaceFirst(RegExp(r'_part\d+$'), '');
  }

  static String subjectFromStem(String stem) {
    final parts = stem.split('_');
    return parts.isEmpty ? 'unknown' : sanitizeSubject(parts.first);
  }

  static Future<Directory> _downloadDir({
    String? subject,
    String? sessionStem,
  }) async {
    final safeSubject = sanitizeSubject(subject ?? 'unknown');
    final safeSession = sanitizeSubject(sessionStem ?? 'unsorted');
    final dir = Directory(
      '/storage/emulated/0/Download/CCS_MobileStudio/$safeSubject/$safeSession',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Copy a file to the Android Download folder for easy access.
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
