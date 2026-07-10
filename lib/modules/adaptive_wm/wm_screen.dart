import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/widgets/connection_status_bar.dart';
import '../../core/models/module_type.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/channel_config_service.dart';
import '../../core/services/permission_service.dart';
import '../standalone/standalone_screen.dart';
import '../home/home_screen.dart';
import 'wm_experiment_screen.dart';
import 'wm_module.dart';

class WmScreen extends StatefulWidget {
  const WmScreen({super.key});

  @override
  State<WmScreen> createState() => _WmScreenState();
}

class _WmScreenState extends State<WmScreen> {
  final _subjectController = TextEditingController(text: 'S001');
  int _totalTrials = 60;
  int _fixationDuration = 500;
  int _cueDuration = 300;
  int _encodingDuration = 300;
  int _delayDuration = 1000;
  bool _recordEeg = true;

  late WmModule _module;

  @override
  void initState() {
    super.initState();
    final sessionManager = context.read<SessionManager>();
    _module = WmModule(sessionManager: sessionManager);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final settings = context.read<SettingsService>();
      final code = settings.subjectCode;
      if (code.isNotEmpty && _subjectController.text != code) {
        setState(() => _subjectController.text = code);
      }
      setState(() {
        _totalTrials = settings.wmTotalTrials;
        _fixationDuration = settings.wmFixationDurationMs;
        _cueDuration = settings.wmCueDurationMs;
        _encodingDuration = settings.wmEncodingDurationMs;
        _delayDuration = settings.wmDelayDurationMs;
        _recordEeg = settings.wmRecordEeg;
      });
    });
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _module.dispose();
    super.dispose();
  }

  void _startSession() async {
    final hasStorage = await context.read<PermissionService>().requestManageExternalStorage(context);
    if (!hasStorage) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot start session: storage permission is required.')),
        );
      }
      return;
    }

    final participant = _subjectController.text.trim().isEmpty
        ? 'S001'
        : _subjectController.text.trim();
    if (context.mounted) {
      context.read<SettingsService>().updateSubjectCode(participant);
    }
    context.read<SettingsService>().update((settings) {
      settings.wmTotalTrials = _totalTrials;
      settings.wmFixationDurationMs = _fixationDuration;
      settings.wmCueDurationMs = _cueDuration;
      settings.wmEncodingDurationMs = _encodingDuration;
      settings.wmDelayDurationMs = _delayDuration;
      settings.wmRecordEeg = _recordEeg;
    });

    if (!mounted) return;

    _module.setRecordEeg(_recordEeg);
    _module.configure(
      totalTrials: _totalTrials,
      fixationDurationMs: _fixationDuration,
      cueDurationMs: _cueDuration,
      encodingDurationMs: _encodingDuration,
      delayDurationMs: _delayDuration,
    );
    final channelConfig = context.read<ChannelConfigService>();

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => WmExperimentScreen(
          module: _module,
          sessionManager: ctx.read<SessionManager>(),
          acquisitionService: ctx.read<AcquisitionService>(),
          subjectId: participant,
          channelLabels: channelConfig.labels,
          enabledChannels: channelConfig.enabled,
        ),
      ),
    );

    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final acq = context.watch<AcquisitionService>();
    final settings = context.watch<SettingsService>();
    final lightTeal = const Color(0xFF14B8A6);

    if (_subjectController.text != settings.subjectCode) {
      _subjectController.value = _subjectController.value.copyWith(
        text: settings.subjectCode,
        selection: TextSelection.collapsed(offset: settings.subjectCode.length),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const HomeScreen()),
            (route) => false,
          );
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0F19),
        appBar: AppBar(
          title: const Text(
            'Adaptive Working Memory (N-Back)',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: const Color(0xFF111827),
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: ConnectionStatusBar(
                        eegState: acq.currentState,
                        deviceLabel: 'xAMP-L10',
                        onDisconnectEeg: () => acq.disconnect(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const StandaloneScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.waves, size: 18),
                      label: const Text('Full EEG Viewer (Signal Check)'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1E293B),
                        foregroundColor: lightTeal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: lightTeal.withOpacity(0.3)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Core Paradigm Settings
                _buildSectionCard(
                  title: 'Participant & Paradigm Setup',
                  icon: Icons.psychology,
                  children: [
                    TextField(
                      controller: _subjectController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Participant ID',
                        labelStyle: const TextStyle(color: Colors.white70),
                        filled: true,
                        fillColor: const Color(0xFF0B0F19),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onChanged: (val) {
                        final code = val.trim().isEmpty ? 'S001' : val.trim();
                        settings.updateSubjectCode(code);
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildDropdown(
                      label: 'Total Trials',
                      value: _totalTrials,
                      options: const [20, 40, 60, 80, 100],
                      suffix: 'trials',
                      onChanged: (val) {
                        setState(() => _totalTrials = val!);
                        context.read<SettingsService>().update((s) => s.wmTotalTrials = val!);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Timing Configuration
                _buildSectionCard(
                  title: 'Trial Timing Configuration (ms)',
                  icon: Icons.timer,
                  children: [
                    _buildDropdown(
                      label: 'Fixation Duration',
                      value: _fixationDuration,
                      options: const [300, 500, 700, 1000],
                      suffix: 'ms',
                      onChanged: (val) {
                        setState(() => _fixationDuration = val!);
                        context.read<SettingsService>().update((s) => s.wmFixationDurationMs = val!);
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildDropdown(
                      label: 'Cue Duration',
                      value: _cueDuration,
                      options: const [200, 300, 500],
                      suffix: 'ms',
                      onChanged: (val) {
                        setState(() => _cueDuration = val!);
                        context.read<SettingsService>().update((s) => s.wmCueDurationMs = val!);
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildDropdown(
                      label: 'Encoding Duration',
                      value: _encodingDuration,
                      options: const [200, 300, 500, 800],
                      suffix: 'ms',
                      onChanged: (val) {
                        setState(() => _encodingDuration = val!);
                        context.read<SettingsService>().update((s) => s.wmEncodingDurationMs = val!);
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildDropdown(
                      label: 'Delay Duration',
                      value: _delayDuration,
                      options: const [500, 1000, 1500, 2000, 3000],
                      suffix: 'ms',
                      onChanged: (val) {
                        setState(() => _delayDuration = val!);
                        context.read<SettingsService>().update((s) => s.wmDelayDurationMs = val!);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Recording Configuration
                _buildSectionCard(
                  title: 'Data Recording',
                  icon: Icons.electrical_services,
                  children: [
                    SwitchListTile(
                      title: const Text(
                        'Record Synchronized EEG (EDF)',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Logs LSL markers and continuous EEG waveforms',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      value: _recordEeg,
                      activeColor: lightTeal,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (val) {
                        setState(() => _recordEeg = val);
                        context.read<SettingsService>().update((s) => s.wmRecordEeg = val);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 32),

                // Launch Button
                ElevatedButton.icon(
                  onPressed: _startSession,
                  icon: const Icon(
                    Icons.play_arrow,
                    size: 28,
                    color: Colors.black,
                  ),
                  label: const Text(
                    'Start Adaptive WM Battery',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: lightTeal,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 6,
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFF14B8A6), size: 22),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required String label,
    required int value,
    required List<int> options,
    required String suffix,
    required ValueChanged<int?> onChanged,
  }) {
    return DropdownButtonFormField<int>(
      value: value,
      items: options
          .map(
            (item) => DropdownMenuItem(
              value: item,
              child: Text(
                '$item $suffix',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          )
          .toList(),
      onChanged: onChanged,
      dropdownColor: const Color(0xFF1E293B),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: const Color(0xFF0B0F19),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
    );
  }
}
