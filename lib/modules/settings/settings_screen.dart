import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/settings_service.dart';
import '../../core/services/channel_config_service.dart';
import '../../core/services/alert_service.dart';
import '../../core/services/permission_service.dart';
import '../../core/models/module_type.dart';
import '../../core/eeg/acquisition_service.dart';

/// Global settings & channel configuration screen.
///
/// Controls LSL streaming properties, EEG/fNIRS channel names and enablement,
/// and auditory alert test functions.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late TextEditingController _xampPrefixCtrl;
  late TextEditingController _eegStreamNameCtrl;
  late TextEditingController _eegStreamTypeCtrl;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    final settings = context.read<SettingsService>();
    _xampPrefixCtrl = TextEditingController(text: settings.xampPrefix);
    _eegStreamNameCtrl = TextEditingController(
      text: settings.lslConfig.eegStreamName,
    );
    _eegStreamTypeCtrl = TextEditingController(
      text: settings.lslConfig.eegStreamType,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _xampPrefixCtrl.dispose();
    _eegStreamNameCtrl.dispose();
    _eegStreamTypeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channelConfig = context.watch<ChannelConfigService>();
    final settings = context.watch<SettingsService>();
    final alertService = context.watch<AlertService>();
    final lightTeal = const Color(0xFF14B8A6);

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        title: const Text(
          'Global Settings & Channels',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFF111827),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: lightTeal,
          labelColor: lightTeal,
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(text: 'Channel Configuration'),
            Tab(text: 'Device & Network Settings'),
            Tab(text: 'Study Flow'),
          ],
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildChannelTab(channelConfig, lightTeal),
            _buildLslTab(settings, alertService, lightTeal),
            _buildStudyFlowTab(settings, lightTeal),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelTab(ChannelConfigService config, Color lightTeal) {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '16-Channel xAMP-L10 / EpiDome Montage',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => config.applyDefaults(16),
                icon: const Icon(Icons.restore, size: 16),
                label: const Text('Reset 10-20 Defaults'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1E293B),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Uncheck noisy or disconnected channels to exclude them from real-time display and metrics calculation.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: ListView.separated(
              itemCount: config.labels.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final label = config.labels[index];
                final enabled = config.enabled[index];
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: enabled
                          ? lightTeal.withOpacity(0.3)
                          : Colors.white10,
                    ),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 45,
                        child: Text(
                          'Ch ${index + 1}',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(
                            color: enabled ? Colors.white : Colors.white38,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.edit_outlined,
                          color: Colors.white54,
                          size: 20,
                        ),
                        tooltip: 'Rename channel',
                        onPressed: () =>
                            _showRenameChannelDialog(context, config, index),
                      ),
                      Switch(
                        value: enabled,
                        activeColor: lightTeal,
                        onChanged: (val) => config.setEnabled(index, val),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLslTab(
    SettingsService settings,
    AlertService alertService,
    Color lightTeal,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'BLE Target Device Configuration',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Set the specific amplifier prefix or MAC address (e.g., AXXSPU00002, AXXSPU00003) to prevent cross-connecting when multiple amplifiers are nearby.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 20),
          _buildTextField('xAMP / BLE Device Target Prefix', _xampPrefixCtrl, (
            val,
          ) {
            settings.update((s) => s.xampPrefix = val);
          }),
          const SizedBox(height: 16),
          _buildSwitchTile(
            title: 'Reconnect warning beep',
            subtitle:
                'Play repeated alert tones while auto-reconnect is failing',
            value: settings.reconnectBeepEnabled,
            color: lightTeal,
            onChanged: (val) =>
                settings.update((s) => s.reconnectBeepEnabled = val),
          ),
          const SizedBox(height: 16),
          _buildDisconnectionTimeoutTile(settings, lightTeal),
          const SizedBox(height: 32),
          const Text(
            'Lab Streaming Layer (LSL) Discovery',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Configure target stream properties for WiFi EEG and fNIRS synchronization.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 20),
          _buildTextField('EEG Stream Name (Optional)', _eegStreamNameCtrl, (
            val,
          ) {
            settings.updateLslConfig(
              settings.lslConfig.copyWith(eegStreamName: val),
            );
          }),
          const SizedBox(height: 16),
          _buildTextField('EEG Stream Type', _eegStreamTypeCtrl, (val) {
            settings.updateLslConfig(
              settings.lslConfig.copyWith(eegStreamType: val),
            );
          }),
          const SizedBox(height: 32),
          const Text(
            'Auditory & Alert Verification',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.surround_sound,
                  color: Color(0xFF3B82F6),
                  size: 28,
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'System Beep & Audio Stim',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Verify sound output for sleep and cognitive feedback',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF3B82F6),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => alertService.playBeep(),
                  child: const Text('Test Sound'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          const Text(
            'Hardware Simulation & Bench Testing',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.waves, color: Color(0xFF38BDF8), size: 28),
                const SizedBox(width: 16),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Synthetic EEG Mode (16-ch EpiDome Sim)',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Simulates 16 frontal/parietal channels at 250 Hz for bench testing without hardware',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: settings.syntheticMode,
                  activeColor: const Color(0xFF38BDF8),
                  onChanged: (val) {
                    settings.updateSyntheticMode(val);
                    if (val) {
                      final eeg = context.read<AcquisitionService>();
                      eeg.addSyntheticDevice();
                      final synth = eeg.discoveredDevices.firstWhere(
                        (d) => d.kind == DeviceKind.synthetic,
                      );
                      eeg.connect(synth);
                    } else {
                      context.read<AcquisitionService>().disconnect();
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showRenameChannelDialog(
    BuildContext context,
    ChannelConfigService config,
    int index,
  ) {
    final controller = TextEditingController(text: config.labels[index]);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(
          'Rename Ch ${index + 1}',
          style: const TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Channel label',
            labelStyle: TextStyle(color: Colors.white70),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final label = controller.text.trim();
              if (label.isNotEmpty) config.setLabel(index, label);
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _buildStudyFlowTab(SettingsService settings, Color lightTeal) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Study Run Order',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Configure the exact module order for non-technical operators. Modules can appear more than once.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 16),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: settings.studySequence.length,
            onReorder: (oldIndex, newIndex) {
              final next = List<ModuleType>.from(settings.studySequence);
              if (newIndex > oldIndex) newIndex -= 1;
              final item = next.removeAt(oldIndex);
              next.insert(newIndex, item);
              settings.setStudySequence(next);
            },
            itemBuilder: (context, index) {
              final module = settings.studySequence[index];
              return ListTile(
                key: ValueKey('study-step-$index-${module.name}'),
                tileColor: const Color(0xFF1E293B),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                leading: CircleAvatar(
                  backgroundColor: lightTeal.withOpacity(0.15),
                  foregroundColor: lightTeal,
                  child: Text('${index + 1}'),
                ),
                title: Text(
                  module.displayName,
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  module.fileTag,
                  style: const TextStyle(color: Colors.white54),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.white54),
                  onPressed: () {
                    final next = List<ModuleType>.from(settings.studySequence)
                      ..removeAt(index);
                    settings.setStudySequence(next);
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: ModuleType.values.map((module) {
              return OutlinedButton.icon(
                onPressed: () {
                  final next = List<ModuleType>.from(settings.studySequence)
                    ..add(module);
                  settings.setStudySequence(next);
                },
                icon: const Icon(Icons.add, size: 18),
                label: Text(module.displayName),
                style: OutlinedButton.styleFrom(
                  foregroundColor: lightTeal,
                  side: BorderSide(color: lightTeal.withOpacity(0.5)),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          const Text(
            'Backup / Export All Settings',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Save or load all configuration parameters (including channel configurations, hardware preferences, and individual cognitive battery settings) to sync settings across tablets.',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      final hasStorage = await context.read<PermissionService>().requestManageExternalStorage(context);
                      if (!hasStorage) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Cannot export settings: storage permission is required.')),
                          );
                        }
                        return;
                      }
                      final path = await settings.exportJson();
                      if (!mounted || path == null) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('All settings successfully exported to $path')),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to save settings: $e')),
                      );
                    }
                  },
                  icon: const Icon(Icons.backup),
                  label: const Text('Export Backup'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E293B),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      final hasStorage = await context.read<PermissionService>().requestManageExternalStorage(context);
                      if (!hasStorage) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Cannot import settings: storage permission is required.')),
                          );
                        }
                        return;
                      }
                      final loaded = await settings.importJson();
                      if (!mounted) return;
                      _xampPrefixCtrl.text = settings.xampPrefix;
                      _eegStreamNameCtrl.text =
                          settings.lslConfig.eegStreamName;
                      _eegStreamTypeCtrl.text =
                          settings.lslConfig.eegStreamType;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            loaded ? 'All settings successfully loaded & applied' : 'Load cancelled',
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to load settings: $e')),
                      );
                    }
                  },
                  icon: const Icon(Icons.settings_backup_restore),
                  label: const Text('Import Backup'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: lightTeal,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDisconnectionTimeoutTile(SettingsService settings, Color color) {
    const options = [2, 3, 5, 8, 10, 15, 20, 30];
    final current = options.contains(settings.disconnectionTimeoutSeconds)
        ? settings.disconnectionTimeoutSeconds
        : 5;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Disconnection detection speed',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
                const SizedBox(height: 4),
                const Text(
                  'How long without EEG samples before the app declares a disconnect, pauses the recording timer, and starts the beep + on-screen alert. Applies to NIDRA, ANGEL, Adaptive WM, and the EEG recorder.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          DropdownButton<int>(
            value: current,
            dropdownColor: const Color(0xFF1E293B),
            style: TextStyle(color: color, fontWeight: FontWeight.bold),
            underline: Container(height: 1, color: color.withOpacity(0.4)),
            items: options
                .map(
                  (secs) => DropdownMenuItem(
                    value: secs,
                    child: Text('${secs}s'),
                  ),
                )
                .toList(),
            onChanged: (val) {
              if (val == null) return;
              settings.update((s) => s.disconnectionTimeoutSeconds = val);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required Color color,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: SwitchListTile(
        title: Text(
          title,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        value: value,
        activeColor: color,
        contentPadding: EdgeInsets.zero,
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller,
    Function(String) onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF1E293B),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Colors.white10),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: Color(0xFF14B8A6)),
            ),
          ),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
