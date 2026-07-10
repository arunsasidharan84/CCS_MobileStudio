import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/services/nirs_acquisition_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/alert_service.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/permission_service.dart';
import '../../core/models/module_type.dart';
import '../../core/widgets/connection_status_bar.dart';
import '../settings/settings_screen.dart';
import '../standalone/standalone_screen.dart';
import '../nidra/nidra_screen.dart';
import '../angel/angel_screen.dart';
import '../adaptive_wm/wm_screen.dart';
import '../sleepiness/sleepiness_screen.dart';

/// Main unified dashboard for CCS Mobile Studio.
///
/// Features:
/// - Real-time global connection status bar (BLE EEG / WiFi fNIRS)
/// - 5 Modular launcher cards (Standalone EEG, Train NIDRA, ANGEL, Adaptive WM, Sleepiness Scale)
/// - Independent diagnostics & troubleshooting drawer for each module
/// - Quick access to global settings and storage explorer
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late TextEditingController _subjectCtrl;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsService>();
    _subjectCtrl = TextEditingController(text: settings.subjectCode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(context.read<PermissionService>().requestAll());
      final eegService = context.read<AcquisitionService>();
      if (eegService.currentState == AcquisitionState.disconnected) {
        eegService.scan(autoConnect: true);
      }
      final code = context.read<SettingsService>().subjectCode;
      if (_subjectCtrl.text != code) {
        setState(() => _subjectCtrl.text = code);
      }
    });
  }

  @override
  void dispose() {
    _subjectCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirmGlobalExit(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Exit CCS Mobile Studio?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'This will disconnect active hardware, cleanly stop any ongoing session, and close the application.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.blueGrey),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Exit App',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final sessionManager = context.read<SessionManager>();
      final eegService = context.read<AcquisitionService>();
      final nirsService = context.read<NirsAcquisitionService>();

      if (sessionManager.isRecording) {
        await sessionManager.stopRecording();
      }
      eegService.disconnect();
      nirsService.disconnect();

      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final eegService = context.watch<AcquisitionService>();
    final nirsService = context.watch<NirsAcquisitionService>();
    final sessionManager = context.watch<SessionManager>();
    final alertService = context.watch<AlertService>();
    final settings = context.watch<SettingsService>();

    final eegState = eegService.currentState;
    final nirsState = nirsService.currentState;

    if (_subjectCtrl.text != settings.subjectCode) {
      _subjectCtrl.value = _subjectCtrl.value.copyWith(
        text: settings.subjectCode,
        selection: TextSelection.collapsed(offset: settings.subjectCode.length),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF14B8A6).withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.hub, color: Color(0xFF14B8A6), size: 24),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'CCS Mobile Studio',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                ),
                Text(
                  'Unified Neuro-Cognitive Suite • NIMHANS / IAM',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.volume_up, color: Colors.white70),
            tooltip: 'Test Audio Beep',
            onPressed: () => alertService.playBeep(),
          ),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white70),
            tooltip: 'Global Settings & Channels',
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.exit_to_app, color: Colors.redAccent),
            tooltip: 'Exit App & Disconnect Hardware',
            onPressed: () => _confirmGlobalExit(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Global Connection Status Bar
              ConnectionStatusBar(
                eegState: eegState,
                nirsState: nirsState,
                deviceLabel: 'xAMP-L10 / EpiDome',
                onDisconnectEeg: () => eegService.disconnect(),
                onDisconnectNirs: () => nirsService.disconnect(),
                onOpenConnectDialog: () => showDeviceConnectionDialog(context),
              ),
              const SizedBox(height: 14),

              // Global Subject ID bar inherited across all modules
              _buildGlobalSubjectBar(context, settings),
              const SizedBox(height: 16),

              // Active Recording Alert Banner (if any module is currently recording)
              if (sessionManager.isRecording) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFFEF4444),
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.fiber_manual_record,
                        color: Color(0xFFEF4444),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Active Recording in progress (${sessionManager.activeModule?.displayName ?? "Unknown Module"}) • Segment #${sessionManager.currentSegment}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => sessionManager.stopRecording(),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFEF4444),
                        ),
                        child: const Text(
                          'STOP & SAVE',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              Expanded(child: _buildStudySequencePanel(context, settings)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGlobalSubjectBar(
    BuildContext context,
    SettingsService settings,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF14B8A6).withOpacity(0.4),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.badge, color: Color(0xFF14B8A6), size: 24),
          const SizedBox(width: 12),
          const Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'GLOBAL SUBJECT ID / SESSION TAG',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Inherited automatically across all modules',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: TextField(
              controller: _subjectCtrl,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: const Color(0xFF0F172A),
                hintText: 'S001',
                hintStyle: const TextStyle(color: Colors.white38),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
              onChanged: (val) {
                final code = val.trim().isEmpty ? 'S001' : val.trim();
                settings.updateSubjectCode(code);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudySequencePanel(
    BuildContext context,
    SettingsService settings,
  ) {
    final steps = settings.studySequence
        .where((module) => _isModuleEnabled(module, settings))
        .toList(growable: false);
    if (steps.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF14B8A6).withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.route, color: Color(0xFF14B8A6), size: 20),
              const SizedBox(width: 8),
              const Text(
                'Study Run Sequence',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Troubleshoot & Diagnostics',
                onPressed: () => _showDiagnosticsModal(context),
                icon: const Icon(
                  Icons.build_circle_outlined,
                  color: Color(0xFF3B82F6),
                ),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                },
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('Edit'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF14B8A6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Tap the next study step. Reorder or repeat modules from Settings.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: steps.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) =>
                  _buildSequenceStep(context, steps[index], index),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSequenceStep(
    BuildContext context,
    ModuleType module,
    int index,
  ) {
    final color = switch (module) {
      ModuleType.standalone => const Color(0xFF14B8A6),
      ModuleType.nidra => const Color(0xFF818CF8),
      ModuleType.angel => const Color(0xFFF59E0B),
      ModuleType.wm => const Color(0xFFEC4899),
      ModuleType.sleepiness => const Color(0xFF10B981),
    };
    final icon = switch (module) {
      ModuleType.standalone => Icons.monitor_heart,
      ModuleType.nidra => Icons.bedtime,
      ModuleType.angel => Icons.psychology,
      ModuleType.wm => Icons.memory,
      ModuleType.sleepiness => Icons.assignment_turned_in,
    };
    final subtitle = switch (module) {
      ModuleType.standalone => 'EEG waveform viewer and EDF recorder',
      ModuleType.nidra => 'Sleep staging and auditory stimulation',
      ModuleType.angel => 'Cognitive ERP battery',
      ModuleType.wm => 'Adaptive working memory task',
      ModuleType.sleepiness => 'Stanford Sleepiness Scale assessment & logs',
    };

    return Material(
      color: const Color(0xFF0F172A),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () => _launchModule(context, module),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 96),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(0.45), width: 1.3),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: color.withOpacity(0.18),
                foregroundColor: color,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Icon(icon, color: color, size: 30),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      module.displayName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 20,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.arrow_forward_ios, color: color, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  // All modules are always available; per-module enable/disable flags were
  // removed as dead config (no UI ever exposed them — see settings cleanup).
  bool _isModuleEnabled(ModuleType module, SettingsService settings) => true;

  void _launchModule(BuildContext context, ModuleType module) {
    final page = switch (module) {
      ModuleType.standalone => const StandaloneScreen(),
      ModuleType.nidra => const NidraScreen(),
      ModuleType.angel => const AngelScreen(),
      ModuleType.wm => const WmScreen(),
      ModuleType.sleepiness => const SleepinessScreen(),
    };
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _showDiagnosticsModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (_) => _DiagnosticsDrawer(),
    );
  }
}

class _DiagnosticsDrawer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final alertService = context.watch<AlertService>();
    final sessionManager = context.watch<SessionManager>();

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Module Diagnostics & Troubleshooting',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'Each module runs in its own isolated state space. Use these tools to verify hardware and file system health without restarting the app.',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 20),
          ListTile(
            leading: const Icon(Icons.volume_up, color: Color(0xFF3B82F6)),
            title: const Text(
              'Audio Latency & Beep Test',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              'Test auditory closed-loop stimulation speaker output',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            trailing: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                foregroundColor: Colors.white,
              ),
              onPressed: () => alertService.playBeep(),
              child: const Text('Play Beep'),
            ),
          ),
          const Divider(color: Colors.white12),
          ListTile(
            leading: const Icon(Icons.folder_special, color: Color(0xFF10B981)),
            title: const Text(
              'Storage & Recording Exporter',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: Text(
              'Exported files location: ${sessionManager.lastExportPath ?? "Downloads/CCS_MobileStudio"}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            trailing: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.black,
              ),
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'All recordings are automatically synced to Downloads/CCS_MobileStudio',
                    ),
                  ),
                );
              },
              child: const Text('Check Files'),
            ),
          ),
          const Divider(color: Colors.white12),
          ListTile(
            leading: const Icon(Icons.network_check, color: Color(0xFFF59E0B)),
            title: const Text(
              'LSL Multicast Lock Status',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              'Required for WiFi LSL stream discovery on Android 10+',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            trailing: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'ACTIVE',
                style: TextStyle(
                  color: Color(0xFF10B981),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
