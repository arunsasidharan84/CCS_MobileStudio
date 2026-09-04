import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Handles runtime permission requests for Bluetooth and storage.
class PermissionService {
  /// Request all standard permissions needed for BLE and file I/O on startup.
  Future<bool> requestAll() async {
    // Desktop platforms use OS-managed Bluetooth prompts and user-selected
    // file access. Requesting Android permission groups on Windows/macOS can
    // incorrectly report a denial and block otherwise valid desktop flows.
    if (!Platform.isAndroid) return true;

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.storage,
      // Android 13+: required for the ongoing "recording in progress"
      // notification shown by the background foreground-service wake lock.
      // The service still runs and protects the recording even if this is
      // denied — it just means the user won't see the notification.
      Permission.notification,
    ].request();
    final allGranted = statuses.values.every(
      (s) => s == PermissionStatus.granted || s == PermissionStatus.limited,
    );
    if (!allGranted) {
      debugPrint('[Permissions] Some permissions denied: $statuses');
    }
    return allGranted;
  }

  /// Request Android 11+ Manage External Storage permission with explanation dialog.
  Future<bool> requestManageExternalStorage(BuildContext context) async {
    if (!Platform.isAndroid) return true;

    if (await Permission.manageExternalStorage.isGranted) {
      return true;
    }

    final proceed =
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: const Text(
              'Manage Files Access Required',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            content: const Text(
              'To export research EDF recordings and hypnogram JSON logs to the public "Download/CCS_MobileStudio" folder, the app needs "All Files Access" permission.\n\nPlease enable it on the next settings screen.',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text(
                  'Cancel',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text(
                  'Grant Access',
                  style: TextStyle(
                    color: Color(0xFF14B8A6),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ) ??
        false;

    if (!proceed) return false;

    final status = await Permission.manageExternalStorage.request();
    return status.isGranted;
  }

  /// Check whether Bluetooth permissions are already granted.
  Future<bool> hasBluetooth() async {
    if (!Platform.isAndroid) return true;

    final scan = await Permission.bluetoothScan.isGranted;
    final connect = await Permission.bluetoothConnect.isGranted;
    return scan && connect;
  }
}
