import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

enum UpdatePlatform { android, macos, windows, linux, unsupported }

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.sizeBytes,
    this.sha256,
  });

  final String name;
  final Uri downloadUrl;
  final int sizeBytes;
  final String? sha256;
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.hasUpdate,
    required this.releaseNotes,
    required this.releasePage,
    required this.asset,
  });

  final String currentVersion;
  final String latestVersion;
  final bool hasUpdate;
  final String releaseNotes;
  final Uri releasePage;
  final ReleaseAsset? asset;
}

class AppUpdateService {
  static const repository = 'arunsasidharan84/CCS_MobileStudio';
  static final releasesPage = Uri.parse(
    'https://github.com/$repository/releases',
  );

  static UpdatePlatform get currentPlatform {
    if (Platform.isAndroid) return UpdatePlatform.android;
    if (Platform.isMacOS) return UpdatePlatform.macos;
    if (Platform.isWindows) return UpdatePlatform.windows;
    if (Platform.isLinux) return UpdatePlatform.linux;
    return UpdatePlatform.unsupported;
  }

  static int compareVersions(String first, String second) {
    List<int> parts(String value) => RegExp(
      r'\d+',
    ).allMatches(value).map((match) => int.parse(match.group(0)!)).toList();

    final left = parts(first);
    final right = parts(second);
    final count = left.length > right.length ? left.length : right.length;
    for (var index = 0; index < count; index++) {
      final a = index < left.length ? left[index] : 0;
      final b = index < right.length ? right[index] : 0;
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  static ReleaseAsset? findAsset(
    List<dynamic> assets, {
    UpdatePlatform? platform,
  }) {
    final target = platform ?? currentPlatform;
    final parsed = assets
        .whereType<Map>()
        .map((raw) {
          final map = raw.map((key, value) => MapEntry(key.toString(), value));
          final name = map['name']?.toString() ?? '';
          final url = Uri.tryParse(
            map['browser_download_url']?.toString() ?? '',
          );
          final digest = map['digest']?.toString();
          return url == null || !url.hasScheme
              ? null
              : ReleaseAsset(
                  name: name,
                  downloadUrl: url,
                  sizeBytes: (map['size'] as num?)?.toInt() ?? 0,
                  sha256: digest?.startsWith('sha256:') == true
                      ? digest!.substring(7)
                      : null,
                );
        })
        .whereType<ReleaseAsset>()
        .toList();

    bool contains(ReleaseAsset asset, String value) =>
        asset.name.toLowerCase().contains(value);
    bool ends(ReleaseAsset asset, String value) =>
        asset.name.toLowerCase().endsWith(value);

    final preferred = switch (target) {
      UpdatePlatform.android => parsed.where((a) => ends(a, '.apk')),
      UpdatePlatform.macos => parsed.where(
        (a) =>
            (ends(a, '.zip') || ends(a, '.dmg')) &&
            (contains(a, 'macos') || contains(a, 'mac')),
      ),
      UpdatePlatform.windows => parsed.where(
        (a) =>
            (ends(a, '.exe') || ends(a, '.msix') || ends(a, '.zip')) &&
            (contains(a, 'windows') || contains(a, 'win')),
      ),
      UpdatePlatform.linux => parsed.where(
        (a) =>
            ends(a, '.deb') ||
            ends(a, '.rpm') ||
            ends(a, '.appimage') ||
            ends(a, '.tar.gz'),
      ),
      UpdatePlatform.unsupported => const Iterable<ReleaseAsset>.empty(),
    };
    return preferred.isEmpty ? null : preferred.first;
  }

  static Future<AppUpdateInfo> check() async {
    final package = await PackageInfo.fromPlatform();
    final current = package.buildNumber.isEmpty
        ? package.version
        : '${package.version}+${package.buildNumber}';
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$repository/releases/latest'),
      );
      request.headers
        ..set(
          HttpHeaders.userAgentHeader,
          'CCS-Mobile-Studio/${package.version}',
        )
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GitHub returned HTTP ${response.statusCode}',
          uri: request.uri,
        );
      }
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String? ?? '').trim();
      if (tag.isEmpty) {
        throw const FormatException('Release has no version tag');
      }
      final latest = tag.startsWith('v') ? tag.substring(1) : tag;
      return AppUpdateInfo(
        currentVersion: current,
        latestVersion: latest,
        hasUpdate: compareVersions(latest, current) > 0,
        releaseNotes: (json['body'] as String?)?.trim().isNotEmpty == true
            ? (json['body'] as String).trim()
            : 'No release notes were provided.',
        releasePage:
            Uri.tryParse(json['html_url'] as String? ?? '') ?? releasesPage,
        asset: findAsset(json['assets'] as List<dynamic>? ?? const []),
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<File> download(
    ReleaseAsset asset,
    void Function(double progress, int received, int total) onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    final directory = await getTemporaryDirectory();
    final safeName = asset.name.replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '_');
    final file = File('${directory.path}${Platform.pathSeparator}$safeName');
    IOSink? sink;
    try {
      final request = await client.getUrl(asset.downloadUrl);
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'CCS-Mobile-Studio-Updater',
      );
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Download returned HTTP ${response.statusCode}',
          uri: asset.downloadUrl,
        );
      }
      if (await file.exists()) await file.delete();
      sink = file.openWrite();
      final total = response.contentLength > 0
          ? response.contentLength
          : asset.sizeBytes;
      var received = 0;
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(
          total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0,
          received,
          total,
        );
      }
      await sink.flush();
      await sink.close();
      sink = null;
      final expected = asset.sha256;
      if (expected != null) {
        final actual = (await sha256.bind(file.openRead()).first).toString();
        if (actual.toLowerCase() != expected.toLowerCase()) {
          await file.delete();
          throw const FormatException(
            'Downloaded package checksum did not match',
          );
        }
      }
      return file;
    } catch (_) {
      await sink?.close();
      if (await file.exists()) await file.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> openReleasePage(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open the release page');
    }
  }

  static Future<String> install(File package) async {
    if (Platform.isAndroid) {
      final result = await OpenFilex.open(
        package.path,
        type: 'application/vnd.android.package-archive',
      );
      if (result.type != ResultType.done) {
        throw StateError(result.message);
      }
      return 'Android installer opened. Confirm the update when prompted.';
    }
    if (Platform.isMacOS && package.path.toLowerCase().endsWith('.zip')) {
      return _installMacOsZip(package);
    }
    if (Platform.isWindows && package.path.toLowerCase().endsWith('.zip')) {
      return _installWindowsZip(package);
    }
    final result = await OpenFilex.open(package.path);
    if (result.type != ResultType.done) throw StateError(result.message);
    return 'Installer opened. Follow the operating-system prompts.';
  }

  static String? _currentAppBundle() {
    var directory = File(Platform.resolvedExecutable).parent;
    while (directory.path != directory.parent.path) {
      if (directory.path.endsWith('.app')) return directory.path;
      directory = directory.parent;
    }
    return null;
  }

  static Future<String> _installMacOsZip(File archive) async {
    final currentApp = _currentAppBundle();
    if (currentApp == null) {
      await Process.run('open', ['-R', archive.path]);
      return 'Archive downloaded and revealed in Finder. Debug builds must be replaced manually.';
    }
    final temp = await Directory.systemTemp.createTemp('ccs_mobile_update_');
    final extract = await Process.run('ditto', [
      '-x',
      '-k',
      archive.path,
      temp.path,
    ]);
    if (extract.exitCode != 0) {
      throw StateError('Could not extract the macOS update package');
    }
    final apps = await temp
        .list(recursive: true)
        .where((entry) => entry is Directory && entry.path.endsWith('.app'))
        .cast<Directory>()
        .toList();
    if (apps.isEmpty) {
      throw const FormatException('Archive contains no app bundle');
    }
    apps.sort(
      (a, b) => a.uri.pathSegments.length.compareTo(b.uri.pathSegments.length),
    );
    final helper = File('${temp.path}/install_update.sh');
    await helper.writeAsString(r'''#!/bin/bash
set -u
PID="$1"
TARGET="$2"
SOURCE="$3"
WORK="$4"
ARCHIVE="$5"
BACKUP="${TARGET}.previous"
while kill -0 "$PID" 2>/dev/null; do sleep 0.25; done
rm -rf "$BACKUP"
if ! mv "$TARGET" "$BACKUP"; then
  open -R "$ARCHIVE"
  exit 1
fi
if cp -R "$SOURCE" "$TARGET"; then
  xattr -rd com.apple.quarantine "$TARGET" 2>/dev/null || true
  open "$TARGET"
  rm -rf "$BACKUP" "$WORK"
  rm -f "$ARCHIVE"
else
  rm -rf "$TARGET"
  mv "$BACKUP" "$TARGET" 2>/dev/null || true
  open -R "$SOURCE"
fi
''');
    await Process.run('chmod', ['+x', helper.path]);
    await Process.start('/bin/bash', [
      helper.path,
      '$pid',
      currentApp,
      apps.first.path,
      temp.path,
      archive.path,
    ], mode: ProcessStartMode.detached);
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 700), () => exit(0)),
    );
    return 'Update prepared. CCS Mobile Studio will restart automatically.';
  }

  static Future<String> _installWindowsZip(File archive) async {
    final executable = File(Platform.resolvedExecutable);
    final currentDir = executable.parent.path;
    final executableName = executable.uri.pathSegments.last;
    final temp = await Directory.systemTemp.createTemp('ccs_mobile_update_');
    final expanded = Directory('${temp.path}${Platform.pathSeparator}new');
    await expanded.create();
    final expand = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'Expand-Archive -LiteralPath $args[0] -DestinationPath $args[1] -Force',
      archive.path,
      expanded.path,
    ]);
    if (expand.exitCode != 0) {
      throw StateError('Could not extract the Windows update package');
    }
    var source = expanded.path;
    final children = expanded.listSync();
    if (children.length == 1 && children.single is Directory) {
      source = children.single.path;
    }
    final script = File(
      '${temp.path}${Platform.pathSeparator}install_update.ps1',
    );
    await script.writeAsString(r'''
param($PidToWait, $Target, $Source, $ExeName, $Work, $Archive)
Wait-Process -Id $PidToWait -ErrorAction SilentlyContinue
$Backup = "$Target.previous"
$MovedCurrentApp = $false
Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue
try {
  Move-Item -LiteralPath $Target -Destination $Backup -Force
  $MovedCurrentApp = $true
  Copy-Item -LiteralPath $Source -Destination $Target -Recurse -Force
  Start-Process -FilePath (Join-Path $Target $ExeName)
  Remove-Item -LiteralPath $Backup -Recurse -Force
  Remove-Item -LiteralPath $Archive -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
} catch {
  if ($MovedCurrentApp) {
    Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $Backup -Destination $Target -Force -ErrorAction SilentlyContinue
  }
  Start-Process explorer.exe -ArgumentList "/select,`"$Archive`""
}
''');
    await Process.start('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script.path,
      '$pid',
      currentDir,
      source,
      executableName,
      temp.path,
      archive.path,
    ], mode: ProcessStartMode.detached);
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 700), () => exit(0)),
    );
    return 'Update prepared. CCS Mobile Studio will restart automatically.';
  }
}

Future<void> showAppUpdateFlow(BuildContext context) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(
      child: Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Checking for updates…'),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    final info = await AppUpdateService.check();
    if (!context.mounted) return;
    Navigator.pop(context);
    await showDialog<void>(
      context: context,
      builder: (_) => AppUpdateDialog(info: info),
    );
  } catch (error) {
    if (!context.mounted) return;
    Navigator.pop(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Could not check for updates'),
        content: Text('$error\n\nCheck the internet connection and try again.'),
        actions: [
          TextButton(
            onPressed: () =>
                AppUpdateService.openReleasePage(AppUpdateService.releasesPage),
            child: const Text('Open releases'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({super.key, required this.info});

  final AppUpdateInfo info;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool downloading = false;
  double progress = 0;
  String status = '';

  Future<void> _downloadAndInstall() async {
    final asset = widget.info.asset;
    if (asset == null) return;
    setState(() {
      downloading = true;
      status = 'Starting download…';
    });
    try {
      final file = await AppUpdateService.download(asset, (
        value,
        received,
        total,
      ) {
        if (!mounted) return;
        setState(() {
          progress = value;
          final receivedMb = (received / 1048576).toStringAsFixed(1);
          final totalMb = total > 0
              ? (total / 1048576).toStringAsFixed(1)
              : '?';
          status = 'Downloading $receivedMb / $totalMb MB';
        });
      });
      if (!mounted) return;
      setState(() => status = 'Download verified. Preparing installation…');
      final message = await AppUpdateService.install(file);
      if (mounted) setState(() => status = message);
    } catch (error) {
      if (mounted) setState(() => status = 'Update failed: $error');
    } finally {
      if (mounted) setState(() => downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      title: Row(
        children: [
          Icon(
            info.hasUpdate ? Icons.system_update_alt : Icons.verified_outlined,
            color: info.hasUpdate ? Colors.tealAccent : Colors.greenAccent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              info.hasUpdate
                  ? 'Update available'
                  : 'CCS Mobile Studio is current',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Installed: ${info.currentVersion}   •   Latest: ${info.latestVersion}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 14),
            const Text(
              'What’s new',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 230),
              child: SingleChildScrollView(
                child: SelectableText(
                  info.releaseNotes,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
            if (downloading || status.isNotEmpty) ...[
              const SizedBox(height: 16),
              if (downloading)
                LinearProgressIndicator(value: progress > 0 ? progress : null),
              const SizedBox(height: 8),
              Text(status, style: const TextStyle(color: Colors.white70)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: downloading
              ? null
              : () => AppUpdateService.openReleasePage(info.releasePage),
          child: const Text('Release page'),
        ),
        TextButton(
          onPressed: downloading ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (info.hasUpdate && info.asset != null)
          FilledButton.icon(
            onPressed: downloading ? null : _downloadAndInstall,
            icon: const Icon(Icons.download),
            label: Text(downloading ? 'Downloading…' : 'Download and update'),
          ),
      ],
    );
  }
}
