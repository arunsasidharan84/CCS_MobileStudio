import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/eeg/acquisition_service.dart';
import 'core/eeg/edf_recorder.dart';
import 'core/eeg/lsl_eeg_acquisition_service.dart';
import 'core/eeg/native_core.dart';
import 'core/eeg/display_filter.dart';
import 'core/services/ble_coordinator.dart';
import 'core/services/settings_service.dart';
import 'core/services/channel_config_service.dart';
import 'core/services/permission_service.dart';
import 'core/services/session_manager.dart';
import 'core/services/alert_service.dart';
import 'core/services/nirs_acquisition_service.dart';
import 'core/eeg/nirs_edf_recorder.dart';
import 'modules/home/home_screen.dart';
import 'modules/standalone/standalone_screen.dart';
import 'modules/nidra/nidra_screen.dart';
import 'modules/angel/angel_screen.dart';
import 'modules/adaptive_wm/wm_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CcsMobileStudioApp());
}

class CcsMobileStudioApp extends StatelessWidget {
  const CcsMobileStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // ── Core singletons ──────────────────────────────────────────────
        Provider<NativeCore>(
          create: (_) => NativeCore.instance,
        ),
        ChangeNotifierProvider<SettingsService>(
          create: (_) => SettingsService()..load(),
        ),
        ChangeNotifierProxyProvider<SettingsService, ChannelConfigService>(
          create: (_) => ChannelConfigService(),
          update: (_, settings, prev) => (prev ?? ChannelConfigService())
            ..updateSettings(settings),
        ),
        Provider<PermissionService>(
          create: (_) => PermissionService(),
        ),
        Provider<AlertService>(
          create: (_) => AlertService(),
        ),

        // ── EEG Acquisition (shared singleton) ───────────────────────────
        ChangeNotifierProxyProvider2<AlertService, SettingsService, AcquisitionService>(
          create: (_) => AcquisitionService(),
          update: (_, alert, settings, prev) => (prev ?? AcquisitionService())
            ..updateAlertService(alert)
            ..updateSettings(settings),
        ),
        ChangeNotifierProvider<LslEegAcquisitionService>(
          create: (_) => LslEegAcquisitionService(),
        ),
        ChangeNotifierProvider<NirsAcquisitionService>(
          create: (_) => NirsAcquisitionService(),
        ),

        // ── Recorders ────────────────────────────────────────────────────
        ChangeNotifierProvider<EdfRecorder>(
          create: (_) => EdfRecorder(),
        ),
        ChangeNotifierProvider<NirsEdfRecorder>(
          create: (_) => NirsEdfRecorder(),
        ),

        // ── BLE Coordinator (exclusive streaming access) ─────────────────
        ChangeNotifierProxyProvider<AcquisitionService, BleCoordinator>(
          create: (_) => BleCoordinator(),
          update: (_, acq, prev) => (prev ?? BleCoordinator())..updateAcquisition(acq),
        ),

        // ── Session Manager (EDF lifecycle, segment tracking) ─────────────
        ChangeNotifierProxyProvider3<
          AcquisitionService,
          EdfRecorder,
          SettingsService,
          SessionManager>(
          create: (_) => SessionManager(),
          update: (_, acq, rec, settings, prev) =>
              (prev ?? SessionManager())..update(acq, rec, settings),
        ),
      ],
      child: MaterialApp(
        title: 'CCS Mobile Studio',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1565C0),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          fontFamily: 'Roboto',
        ),
        home: const HomeScreen(),
        routes: {
          '/standalone': (_) => const StandaloneScreen(),
          '/nidra': (_) => const NidraScreen(),
          '/angel': (_) => const AngelScreen(),
          '/wm': (_) => const WmScreen(),
        },
      ),
    );
  }
}
