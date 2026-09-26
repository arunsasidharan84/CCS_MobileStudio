import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/services/session_manager.dart';
import '../../core/widgets/connection_status_bar.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/channel_config_service.dart';
import '../../core/services/permission_service.dart';
import '../standalone/standalone_screen.dart';
import '../home/home_screen.dart';
import 'experiment_screen.dart';

class AngelScreen extends StatefulWidget {
  const AngelScreen({super.key});

  @override
  State<AngelScreen> createState() => _AngelScreenState();
}

class _AngelScreenState extends State<AngelScreen> {
  final _participantController = TextEditingController(text: 'S001');
  String _level = '1,2';
  String _language = 'English';
  int _blocksCount = 2;
  String _trialsOption = '25+3';
  int _practiceCount = 2;
  String _categorySet = 'all';
  String _cdSchedule = 'by-block';
  String _toneOffsetMode = 'continuous';
  String _tonePlaybackMode = 'async';
  bool _level2Cd = true;
  bool _intermixLevelBlocks = true;
  bool _recordEeg = true;
  bool _audioInstructions = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final code = context.read<SettingsService>().subjectCode;
      final settings = context.read<SettingsService>();
      if (code.isNotEmpty && _participantController.text != code) {
        setState(() => _participantController.text = code);
      }
      setState(() {
        _level = settings.angelLevel;
        _language = settings.angelLanguage;
        _blocksCount = settings.angelBlocksCount;
        _trialsOption = settings.angelTrialsOption;
        _practiceCount = settings.angelPracticeCount;
        _categorySet = settings.angelCategorySet;
        _cdSchedule = settings.angelCdSchedule;
        _toneOffsetMode = settings.angelToneOffsetMode;
        _tonePlaybackMode = settings.angelTonePlaybackMode;
        _level2Cd = settings.angelLevel2Cd;
        _intermixLevelBlocks = settings.angelIntermixLevelBlocks;
        _recordEeg = settings.angelRecordEeg;
        _audioInstructions = settings.angelAudioInstructionsEnabled;
      });
    });
  }

  @override
  void dispose() {
    _participantController.dispose();
    super.dispose();
  }

  void _startSession() async {
    final hasStorage = await context
        .read<PermissionService>()
        .requestManageExternalStorage(context);
    if (!hasStorage) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cannot start session: storage permission is required.',
            ),
          ),
        );
      }
      return;
    }

    final participant = _participantController.text.trim().isEmpty
        ? 'S001'
        : _participantController.text.trim();
    if (context.mounted) {
      context.read<SettingsService>().updateSubjectCode(participant);
    }
    context.read<SettingsService>().update((settings) {
      settings.angelLevel = _level;
      settings.angelLanguage = _language;
      settings.angelBlocksCount = _blocksCount;
      settings.angelTrialsOption = _trialsOption;
      settings.angelPracticeCount = _practiceCount;
      settings.angelCategorySet = _categorySet;
      settings.angelCdSchedule = _cdSchedule;
      settings.angelToneOffsetMode = _toneOffsetMode;
      settings.angelTonePlaybackMode = _tonePlaybackMode;
      settings.angelLevel2Cd = _level2Cd;
      settings.angelIntermixLevelBlocks = _intermixLevelBlocks;
      settings.angelRecordEeg = _recordEeg;
      settings.angelAudioInstructionsEnabled = _audioInstructions;
    });

    if (!mounted) return;

    final sessionManager = context.read<SessionManager>();
    final acqService = context.read<AcquisitionService>();
    final channelConfig = context.read<ChannelConfigService>();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ExperimentScreen(
          sessionManager: sessionManager,
          acquisitionService: acqService,
          level: _level,
          language: _language,
          participant: participant,
          blocksCount: _blocksCount,
          trialsPerBlockOption: _trialsOption.toString(),
          practiceCount: _practiceCount,
          categorySet: _categorySet,
          cdSchedule: _cdSchedule,
          pairedToneOffsetMode: _toneOffsetMode,
          tonePlaybackMode: _tonePlaybackMode,
          level2Cd: _level2Cd,
          intermixLevelBlocks: _intermixLevelBlocks,
          recordEeg: _recordEeg,
          audioInstructionsEnabled: _audioInstructions,
          channelLabels: channelConfig.labels,
          enabledChannels: channelConfig.enabled,
          visualStimulusFolder: context
              .read<SettingsService>()
              .angelVisualStimulusFolder,
          auditoryStimulusFolder: context
              .read<SettingsService>()
              .angelAuditoryStimulusFolder,
          stimulusFiles: context.read<SettingsService>().angelStimulusFiles.map(
            (key, value) => MapEntry(key, List<String>.from(value)),
          ),
          erpComponent: context
              .read<SettingsService>()
              .angelRealtimeErpComponent,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final acq = context.watch<AcquisitionService>();
    final settings = context.watch<SettingsService>();
    final lightTeal = const Color(0xFF14B8A6);

    if (_participantController.text != settings.subjectCode) {
      _participantController.value = _participantController.value.copyWith(
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
            'ANGEL • Cognitive Task Battery',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: const Color(0xFF111827),
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(
              MediaQuery.sizeOf(context).width < 600 ? 12 : 20,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final connection = ConnectionStatusBar(
                      eegState: acq.currentState,
                      deviceLabel: acq.connectedDeviceLabel,
                      onDisconnectEeg: () => acq.disconnect(),
                    );
                    final viewerButton = ElevatedButton.icon(
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
                    );
                    if (constraints.maxWidth < 700) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          connection,
                          const SizedBox(height: 8),
                          viewerButton,
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: connection),
                        const SizedBox(width: 12),
                        viewerButton,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),

                // Core Paradigm Settings
                _buildSectionCard(
                  title: 'Core Paradigm Settings',
                  icon: Icons.psychology,
                  children: [
                    TextField(
                      controller: _participantController,
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
                    ),
                    const SizedBox(height: 16),
                    _buildSectionCard(
                      title: 'Cognitive Battery Parameters',
                      icon: Icons.psychology_alt,
                      children: [
                        _buildDropdown<String>(
                          label: 'Instruction Load Level',
                          value: _level,
                          items: const [
                            DropdownMenuItem(
                              value: '1,2',
                              child: Text('Levels 1 & 2 Intermixed'),
                            ),
                            DropdownMenuItem(
                              value: '1',
                              child: Text('Level 1 Only'),
                            ),
                            DropdownMenuItem(
                              value: '2',
                              child: Text('Level 2 Only'),
                            ),
                          ],
                          onChanged: (val) {
                            setState(() => _level = val!);
                            context.read<SettingsService>().update(
                              (s) => s.angelLevel = val!,
                            );
                          },
                        ),
                        const SizedBox(height: 16),
                        _buildDropdown(
                          label: 'Instructions Language',
                          value: _language,
                          items: const [
                            DropdownMenuItem(
                              value: 'English',
                              child: Text('English'),
                            ),
                            DropdownMenuItem(
                              value: 'Hindi',
                              child: Text('Hindi'),
                            ),
                            DropdownMenuItem(
                              value: 'Kannada',
                              child: Text('Kannada'),
                            ),
                          ],
                          onChanged: (val) {
                            setState(() => _language = val!);
                            context.read<SettingsService>().update(
                              (s) => s.angelLanguage = val!,
                            );
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Experimental Structure
                _buildSectionCard(
                  title: 'Experimental Structure',
                  icon: Icons.tune,
                  children: [
                    _buildDropdown<int>(
                      label: 'Blocks Count',
                      value: _blocksCount,
                      items: const [
                        DropdownMenuItem(
                          value: 1,
                          child: Text('1 Block (Quick Test)'),
                        ),
                        DropdownMenuItem(
                          value: 2,
                          child: Text('2 Blocks (Standard)'),
                        ),
                        DropdownMenuItem(value: 4, child: Text('4 Blocks')),
                        DropdownMenuItem(value: 8, child: Text('8 Blocks')),
                        DropdownMenuItem(value: 12, child: Text('12 Blocks')),
                        DropdownMenuItem(
                          value: 16,
                          child: Text('16 Blocks (Full Run)'),
                        ),
                        DropdownMenuItem(value: 20, child: Text('20 Blocks')),
                      ],
                      onChanged: (val) {
                        setState(() => _blocksCount = val!);
                        context.read<SettingsService>().update(
                          (s) => s.angelBlocksCount = val!,
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildDropdown<String>(
                      label: 'Trials Per Block',
                      value: _trialsOption,
                      items: const [
                        DropdownMenuItem(
                          value: '20+3',
                          child: Text('20 Active + 3 Base'),
                        ),
                        DropdownMenuItem(
                          value: '25+3',
                          child: Text('25 Active + 3 Base (Parity)'),
                        ),
                      ],
                      onChanged: (val) {
                        setState(() => _trialsOption = val!);
                        context.read<SettingsService>().update(
                          (s) => s.angelTrialsOption = val!,
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildDropdown<int>(
                      label: 'Practice Trials Count',
                      value: _practiceCount,
                      items: const [
                        DropdownMenuItem(value: 2, child: Text('2 Trials')),
                        DropdownMenuItem(
                          value: 4,
                          child: Text('4 Trials (Standard)'),
                        ),
                        DropdownMenuItem(value: 6, child: Text('6 Trials')),
                        DropdownMenuItem(value: 8, child: Text('8 Trials')),
                      ],
                      onChanged: (val) {
                        setState(() => _practiceCount = val!);
                        context.read<SettingsService>().update(
                          (s) => s.angelPracticeCount = val!,
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildDropdown<String>(
                      label: 'Visual Categories Set',
                      value: _categorySet,
                      items: const [
                        DropdownMenuItem(
                          value: 'all',
                          child: Text('Salient Stimuli Types 1 & 2'),
                        ),
                        DropdownMenuItem(
                          value: 'face',
                          child: Text('Salient Stimuli Type 1'),
                        ),
                        DropdownMenuItem(
                          value: 'shape',
                          child: Text('Salient Stimuli Type 2'),
                        ),
                      ],
                      onChanged: (val) {
                        setState(() => _categorySet = val!);
                        context.read<SettingsService>().update(
                          (s) => s.angelCategorySet = val!,
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildStimulusFolderPicker(
                      label: 'Visual stimulus folder',
                      path: settings.angelVisualStimulusFolder,
                      icon: Icons.image_outlined,
                      onPressed: () => _pickStimulusFolder(visual: true),
                    ),
                    const SizedBox(height: 10),
                    _buildStimulusFolderPicker(
                      label: 'Auditory stimulus folder',
                      path: settings.angelAuditoryStimulusFolder,
                      icon: Icons.audio_file_outlined,
                      onPressed: () => _pickStimulusFolder(visual: false),
                    ),
                    const SizedBox(height: 10),
                    _buildStimulusMappingSummary(settings),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: settings.angelRealtimeErpComponent,
                      decoration: const InputDecoration(
                        labelText: 'Realtime ERP waveform',
                      ),
                      items: const ['P300', 'N170']
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) {
                          settings.update(
                            (s) => s.angelRealtimeErpComponent = value,
                          );
                        }
                      },
                    ),
                    const Text(
                      'Mapped files take priority. Folder selection remains available for bulk import; unmapped stimulus types use the bundled defaults.',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text(
                        'Intermix Level Blocks',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Alternate Level 1 and 2 if multiple blocks',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      value: _intermixLevelBlocks,
                      activeColor: lightTeal,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (val) {
                        setState(() => _intermixLevelBlocks = val);
                        context.read<SettingsService>().update(
                          (s) => s.angelIntermixLevelBlocks = val,
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Auditory Tone & CD Settings
                _buildSectionCard(
                  title: 'Auditory Tone & CD Settings',
                  icon: Icons.volume_up,
                  children: [
                    _buildDropdown(
                      label: 'CD Presentation Schedule',
                      value: _cdSchedule,
                      items: const [
                        DropdownMenuItem(
                          value: 'by-block',
                          child: Text('By Block'),
                        ),
                        DropdownMenuItem(
                          value: 'intermixed',
                          child: Text('Intermixed in Trials'),
                        ),
                      ],
                      onChanged: (val) {
                        setState(() => _cdSchedule = val!);
                        context.read<SettingsService>().update(
                          (s) => s.angelCdSchedule = val!,
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildDropdown(
                      label: 'Paired Tone Offset Mode',
                      value: _toneOffsetMode,
                      items: const [
                        DropdownMenuItem(
                          value: 'continuous',
                          child: Text('Continuous / Variable'),
                        ),
                        DropdownMenuItem(
                          value: 'fixed',
                          child: Text('Fixed Latency'),
                        ),
                      ],
                      onChanged: (val) {
                        setState(() => _toneOffsetMode = val!);
                        context.read<SettingsService>().update(
                          (s) => s.angelToneOffsetMode = val!,
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildDropdown(
                      label: 'Tone Playback Mode',
                      value: _tonePlaybackMode,
                      items: const [
                        DropdownMenuItem(
                          value: 'async',
                          child: Text('Async (Non-blocking)'),
                        ),
                        DropdownMenuItem(
                          value: 'sync',
                          child: Text('Sync (Blocking)'),
                        ),
                      ],
                      onChanged: (val) {
                        setState(() => _tonePlaybackMode = val!);
                        context.read<SettingsService>().update(
                          (s) => s.angelTonePlaybackMode = val!,
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text(
                        'Enable CD for Level 2',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Play continuous distraction during high load',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      value: _level2Cd,
                      activeColor: lightTeal,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (val) {
                        setState(() => _level2Cd = val);
                        context.read<SettingsService>().update(
                          (s) => s.angelLevel2Cd = val,
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Hardware & Recording
                _buildSectionCard(
                  title: 'Hardware & Recording',
                  icon: Icons.electrical_services,
                  children: [
                    SwitchListTile(
                      title: const Text(
                        'Record Connected Biopotentials',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'On: save enabled EEG/ECG/EMG/PPG/fNIRS streams. '
                        'Off: run task-only and still save behavioral results.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      value: _recordEeg,
                      activeColor: lightTeal,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (val) {
                        setState(() => _recordEeg = val);
                        context.read<SettingsService>().update(
                          (s) => s.angelRecordEeg = val,
                        );
                      },
                    ),
                    SwitchListTile(
                      title: const Text(
                        'Audio Instructions',
                        style: TextStyle(color: Colors.white, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Play spoken guide audio during ANGEL instruction slides',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      value: _audioInstructions,
                      activeColor: lightTeal,
                      contentPadding: EdgeInsets.zero,
                      onChanged: (val) => setState(() {
                        _audioInstructions = val;
                        context.read<SettingsService>().update(
                          (s) => s.angelAudioInstructionsEnabled = val,
                        );
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                ElevatedButton.icon(
                  onPressed: _startSession,
                  icon: const Icon(Icons.play_arrow, size: 22),
                  label: const Text(
                    'START ANGEL TASK',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.1,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF14B8A6),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 4,
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

  Widget _buildStimulusFolderPicker({
    required String label,
    required String path,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            path.isEmpty ? '$label: bundled default' : '$label: $path',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
        OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: const Text('Choose folder'),
        ),
      ],
    );
  }

  Widget _buildStimulusMappingSummary(SettingsService settings) {
    final assigned = settings.angelStimulusFiles.values.fold<int>(
      0,
      (total, files) => total + files.length,
    );
    final mappedTypes = settings.angelStimulusFiles.values
        .where((files) => files.isNotEmpty)
        .length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          const Icon(Icons.account_tree_outlined, color: Color(0xFF14B8A6)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Stimulus type mapping',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  assigned == 0
                      ? 'Using bundled defaults'
                      : '$assigned files assigned across $mappedTypes types',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ],
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: () => _showStimulusMappingDialog(settings),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Map files'),
          ),
        ],
      ),
    );
  }

  Future<void> _showStimulusMappingDialog(SettingsService settings) async {
    const labels = <String, String>{
      'visual_salient_1': 'Visual: Salient type 1',
      'visual_control_1': 'Visual: Control type 1',
      'visual_salient_2': 'Visual: Salient type 2',
      'visual_control_2': 'Visual: Control type 2',
      'auditory_standard': 'Auditory: Standard',
      'auditory_deviant': 'Auditory: Deviant',
      'auditory_corollary': 'Auditory: Corollary',
      'auditory_no_corollary': 'Auditory: No corollary',
    };
    final mapped = settings.angelStimulusFiles.map(
      (key, files) => MapEntry(key, List<String>.from(files)),
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text(
            'Map files to stimulus types',
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 700,
            height: 520,
            child: ListView(
              children: labels.entries.map((entry) {
                final files = mapped[entry.key] ?? const <String>[];
                final isVisual = entry.key.startsWith('visual_');
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    isVisual ? Icons.image_outlined : Icons.audio_file_outlined,
                    color: const Color(0xFF14B8A6),
                  ),
                  title: Text(
                    entry.value,
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    files.isEmpty
                        ? 'Bundled default'
                        : files
                              .map(
                                (path) =>
                                    path.split(Platform.pathSeparator).last,
                              )
                              .join(', '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60),
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      if (files.isNotEmpty)
                        IconButton(
                          tooltip: 'Use bundled default',
                          onPressed: () =>
                              setDialogState(() => mapped.remove(entry.key)),
                          icon: const Icon(Icons.clear, color: Colors.white70),
                        ),
                      OutlinedButton(
                        onPressed: () async {
                          final result = await FilePicker.platform.pickFiles(
                            allowMultiple: true,
                            dialogTitle: 'Choose ${entry.value} files',
                            type: FileType.custom,
                            allowedExtensions: isVisual
                                ? const ['png', 'jpg', 'jpeg', 'bmp']
                                : const ['wav', 'mp3', 'm4a', 'aac'],
                          );
                          final paths = result?.paths
                              .whereType<String>()
                              .toList();
                          if (paths == null ||
                              paths.isEmpty ||
                              !dialogContext.mounted) {
                            return;
                          }
                          setDialogState(() => mapped[entry.key] = paths);
                        },
                        child: Text(files.isEmpty ? 'Choose files' : 'Replace'),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Save mapping'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    settings.update((value) {
      value.angelStimulusFiles = mapped
        ..removeWhere((key, files) => files.isEmpty);
    });
  }

  Future<void> _pickStimulusFolder({required bool visual}) async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: visual
          ? 'Choose ANGEL visual stimulus folder'
          : 'Choose ANGEL auditory stimulus folder',
    );
    if (path == null || !mounted) return;
    context.read<SettingsService>().update((settings) {
      if (visual) {
        settings.angelVisualStimulusFolder = path;
      } else {
        settings.angelAuditoryStimulusFolder = path;
      }
    });
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

  Widget _buildDropdown<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return DropdownButtonFormField<T>(
      value: value,
      items: items,
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
