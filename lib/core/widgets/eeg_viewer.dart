import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../eeg/acquisition_service.dart';
import '../eeg/lsl_eeg_acquisition_service.dart';
import '../eeg/display_filter.dart';
import '../models/eeg_sample.dart';
import '../models/device_profile.dart';
import '../models/nirs_sample.dart';
import '../models/signal_stream_sample.dart';
import '../services/nirs_acquisition_service.dart';
import '../services/settings_service.dart';
import 'waveform_painter.dart';
import 'nirs_waveform_painter.dart';
import 'waveform_scale_snapshot.dart';

/// Unified EEG & fNIRS viewer widget.
///
/// Automatically subscribes to any provided [AcquisitionService],
/// [LslEegAcquisitionService], and [NirsAcquisitionService], buffers incoming
/// samples, applies display filtering (notch + bandpass), calculates real-time
/// quality metrics (peak-to-peak amplitude, artifact ratio, sensor stability),
/// and renders multi-channel waveforms with interactive controls (time window,
/// gain, autoscale, channel visibility, and filter toggles).
class EegViewer extends StatefulWidget {
  const EegViewer({
    super.key,
    this.eegService,
    this.lslEegService,
    this.nirsService,
    this.signalStream,
    this.signalProfile,
    this.displayStateKey,
    this.initialDurationSeconds = 4,
    this.showControls = true,
    this.showMetrics = true,
  });

  final AcquisitionService? eegService;
  final LslEegAcquisitionService? lslEegService;
  final NirsAcquisitionService? nirsService;
  final Stream<SignalStreamSample>? signalStream;
  final SignalStreamProfile? signalProfile;
  final String? displayStateKey;
  final int initialDurationSeconds;
  final bool showControls;
  final bool showMetrics;

  @override
  State<EegViewer> createState() => _EegViewerState();
}

class _EegViewerState extends State<EegViewer>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late TabController? _tabController;
  final List<List<double>> _eegBuffers = [];
  final List<List<double>> _nirsBuffers = [];
  final List<String> _eegChannelLabels = [];
  final List<String> _nirsChannelLabels = [];
  final Set<int> _hiddenNirsChannels = {};
  final List<bool> _visibleEegChannels = [];
  final List<SignalType> _eegChannelTypes = [];

  StreamSubscription<EegSample>? _btEegSub;
  StreamSubscription<EegSample>? _lslEegSub;
  StreamSubscription<NirsSample>? _nirsSub;
  StreamSubscription<SignalStreamSample>? _signalSub;
  Timer? _repaintTimer;
  DateTime _lastRepaintAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Display filtering
  final DisplayFilter _displayFilter = DisplayFilter();
  final List<double> _runningMeans = [];
  bool _notchEnabled = true;
  bool _bandpassEnabled = true;
  late DisplayFilterSettings _filterSettings;
  Map<String, String> _montageReferences = {};
  Set<String> _hiddenChannelLabels = {};
  bool _autoscale = true;
  double _gain = 1.2;
  late int _durationSeconds;
  String _viewMode = 'rolling';
  double _eegFixedScale = 150.0;
  double _ecgFixedScale = 2000.0;
  double _ppgFixedScale = 100.0;
  double _eegAutoScale = 150.0;
  double _ecgAutoScale = 2000.0;
  double _ppgAutoScale = 100.0;
  int _pageSampleCount = 0;
  int _samplesSinceScaleUpdate = 0;
  int _autoscaleSuppressionSamples = 0;

  // Signal quality metrics
  double _peakToPeakUv = 0.0;
  double _artifactRatio = 0.0;
  bool _signalStable = false;

  bool _hasEeg = false;
  bool _hasNirs = false;
  final List<String> _tabs = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsService>();
    final savedDisplay = settings.viewerDisplayProfile(widget.displayStateKey);
    const supportedDurations = [2, 4, 8, 10, 20, 30];
    final savedDuration =
        savedDisplay['durationSeconds'] as int? ??
        settings.waveformDurationSeconds;
    _durationSeconds = supportedDurations.contains(savedDuration)
        ? savedDuration
        : (supportedDurations.contains(widget.initialDurationSeconds)
              ? widget.initialDurationSeconds
              : 10);
    _notchEnabled =
        savedDisplay['notchEnabled'] as bool? ?? settings.notchEnabled;
    _bandpassEnabled =
        savedDisplay['bandpassEnabled'] as bool? ?? settings.bandpassEnabled;
    _filterSettings = _displayFilterSettingsFrom(settings, savedDisplay);
    _montageReferences = Map<String, String>.from(
      savedDisplay['montageReferences'] as Map? ??
          settings.displayMontageReferences,
    );
    _hiddenChannelLabels = List<String>.from(
      savedDisplay['hiddenChannelLabels'] as List? ??
          settings.displayHiddenChannelLabels,
    ).toSet();
    _autoscale =
        savedDisplay['autoscale'] as bool? ?? settings.waveformAutoscaleV2;
    _gain = (savedDisplay['gain'] as num?)?.toDouble() ?? settings.waveformGain;
    _viewMode = savedDisplay.containsKey('viewMode')
        ? (savedDisplay['viewMode'] == 'page' ? 'page' : 'rolling')
        : settings.waveformViewMode;
    _eegFixedScale =
        (savedDisplay['eegScale'] as num?)?.toDouble() ??
        settings.eegDisplayScaleUv;
    _ecgFixedScale =
        (savedDisplay['ecgScale'] as num?)?.toDouble() ??
        settings.ecgDisplayScaleUv;
    _ppgFixedScale =
        (savedDisplay['ppgScale'] as num?)?.toDouble() ??
        settings.ppgDisplayScale;
    _eegAutoScale = _eegFixedScale;
    _ecgAutoScale = _ecgFixedScale;
    _ppgAutoScale = _ppgFixedScale;
    _hasEeg =
        widget.eegService != null ||
        widget.lslEegService != null ||
        widget.signalStream != null;
    _hasNirs = widget.nirsService != null;

    if (_hasEeg) _tabs.add('EEG');
    if (_hasNirs) _tabs.add('fNIRS');
    if (_hasEeg && _hasNirs) _tabs.add('Dual View');

    if (_tabs.length > 1) {
      _tabController = TabController(length: _tabs.length, vsync: this);
    } else {
      _tabController = null;
    }

    _initStreams();
  }

  void _initStreams() {
    // 1. Bluetooth EEG
    if (widget.eegService != null) {
      _btEegSub = widget.eegService!.samples.listen(_processEegSample);
    }

    // 2. LSL EEG
    if (widget.lslEegService != null) {
      _lslEegSub = widget.lslEegService!.samples.listen(_processEegSample);
    }

    if (widget.signalStream != null) {
      _signalSub = widget.signalStream!.listen(_processSignalStreamSample);
    }

    // 3. fNIRS
    if (widget.nirsService != null) {
      _nirsSub = widget.nirsService!.samples.listen(_processNirsSample);
    }
  }

  void _processEegSample(EegSample sample) {
    _processEegSampleWithMetadata(sample);
  }

  void _processEegSampleWithMetadata(
    EegSample sample, {
    List<String>? explicitLabels,
    List<SignalType>? explicitTypes,
  }) {
    if (!mounted) return;
    {
      final chCount = sample.channels.length;
      final sampleRate = _eegSampleRate;
      if (_viewMode == 'page' &&
          _pageSampleCount >= sampleRate * _durationSeconds) {
        for (final buffer in _eegBuffers) {
          buffer.clear();
        }
        _pageSampleCount = 0;
      }
      while (_eegBuffers.length < chCount) {
        _eegBuffers.add([]);
        _runningMeans.add(double.nan);
        _visibleEegChannels.add(true);
        _eegChannelLabels.add('Ch ${_eegBuffers.length}');
      }
      if (explicitLabels != null) {
        for (var i = 0; i < chCount; i++) {
          _eegChannelLabels[i] = i < explicitLabels.length
              ? explicitLabels[i]
              : 'Ch ${i + 1}';
        }
        _eegChannelTypes
          ..clear()
          ..addAll(
            SignalStreamProfile.normalizeChannelTypes(
              _eegChannelLabels,
              explicitTypes,
            ),
          );
      } else if (_eegChannelLabels.length == chCount &&
          widget.eegService != null) {
        final names = widget.eegService!.displayChannelLabels(chCount);
        final types = widget.eegService!.displayChannelTypes(chCount);
        for (var i = 0; i < chCount; i++) {
          _eegChannelLabels[i] = names[i];
        }
        _eegChannelTypes
          ..clear()
          ..addAll(types);
      } else if (_eegChannelLabels.length == chCount &&
          widget.lslEegService != null) {
        final names = widget.lslEegService!.channelNames;
        if (names.length == chCount) {
          for (var i = 0; i < chCount; i++) {
            _eegChannelLabels[i] = names[i];
          }
        }
      }
      for (var i = 0; i < chCount; i++) {
        _visibleEegChannels[i] = !_hiddenChannelLabels.contains(
          _eegChannelLabels[i],
        );
      }

      final montageValues = DisplayMontage.apply(
        sample.channels,
        _eegChannelLabels,
        _montageReferences,
      );
      final filtered = _displayFilter.process(
        montageValues,
        labels: _eegChannelLabels,
        channelTypes: _eegChannelTypes,
        sampleRate: sampleRate.toDouble(),
        notch: _notchEnabled,
        bandpass: _bandpassEnabled,
        settings: _filterSettings,
      );

      for (var i = 0; i < chCount; i++) {
        final val = filtered[i];
        final type = i < _eegChannelTypes.length
            ? biosignalTypeForSignalType(_eegChannelTypes[i])
            : biosignalTypeForLabel(_eegChannelLabels[i]);
        final hasActiveBandpass =
            _bandpassEnabled && _filterSettings.bandFor(type) != null;
        final alreadyCentered = hasActiveBandpass || type == BiosignalType.ppg;
        // EEG/EOG/EMG band-pass filters and the Orbit PPG decoder already
        // remove DC. Applying this second, slow moving-average subtraction to
        // the 62.5 Hz PPG stream caused another several-second startup ramp.
        // Retain centering only for genuinely raw/unfiltered channels.
        if (!alreadyCentered) {
          if (!_runningMeans[i].isFinite) {
            _runningMeans[i] = val;
          } else {
            _runningMeans[i] = _runningMeans[i] * 0.998 + val * 0.002;
          }
        }
        final zeroCentered = alreadyCentered ? val : val - _runningMeans[i];

        _eegBuffers[i].add(zeroCentered);
        final maxBuf = sampleRate * math.max(30, _durationSeconds);
        if (_eegBuffers[i].length > maxBuf) {
          _eegBuffers[i].removeAt(0);
        }
      }
      _pageSampleCount++;
      _samplesSinceScaleUpdate++;
      if (_autoscaleSuppressionSamples > 0) {
        _autoscaleSuppressionSamples--;
      }
      if (_autoscale && _samplesSinceScaleUpdate >= 25) {
        _samplesSinceScaleUpdate = 0;
        _updateAutomaticScales();
      }
      _calculateMetrics();
    }
    _requestRepaint();
  }

  void _processSignalStreamSample(SignalStreamSample sample) {
    final profile = widget.signalProfile;
    if (profile != null && sample.streamId != profile.id) return;
    final labels = sample.channelLabels.length == sample.channels.length
        ? sample.channelLabels
        : List<String>.generate(sample.channels.length, (index) {
            if (index < sample.channelLabels.length) {
              return sample.channelLabels[index];
            }
            return 'Ch ${index + 1}';
          });
    _processEegSampleWithMetadata(
      EegSample(
        channels: sample.channels,
        sampleRate: sample.sampleRate,
        timestamp: sample.timestamp,
        source: profile?.name ?? sample.streamId,
      ),
      explicitLabels: labels,
      explicitTypes: sample.channelTypes,
    );
  }

  int get _eegSampleRate =>
      (widget.eegService?.sampleRate ??
              widget.lslEegService?.sampleRate ??
              widget.signalProfile?.sampleRate ??
              250)
          .round()
          .clamp(1, 4000);

  bool _isPpgLabel(String label) => label.toUpperCase().contains('PPG');

  bool _isEcgLabel(String label) => label.toUpperCase().contains('ECG');

  List<String> get _displayChannelLabels =>
      DisplayMontage.labels(_eegChannelLabels, _montageReferences);

  DisplayFilterSettings _displayFilterSettingsFrom(
    SettingsService settings, [
    Map<String, dynamic> saved = const {},
  ]) {
    double value(String key, double fallback) =>
        (saved[key] as num?)?.toDouble() ?? fallback;
    return DisplayFilterSettings(
      eegHighPassHz: value('eegHighPassHz', settings.eegDisplayHighPassHz),
      eegLowPassHz: value('eegLowPassHz', settings.eegDisplayLowPassHz),
      eogHighPassHz: value('eogHighPassHz', settings.eogDisplayHighPassHz),
      eogLowPassHz: value('eogLowPassHz', settings.eogDisplayLowPassHz),
      emgHighPassHz: value('emgHighPassHz', settings.emgDisplayHighPassHz),
      emgLowPassHz: value('emgLowPassHz', settings.emgDisplayLowPassHz),
      ecgHighPassHz: value('ecgHighPassHz', settings.ecgDisplayHighPassHz),
      ecgLowPassHz: value('ecgLowPassHz', settings.ecgDisplayLowPassHz),
      notchFrequencyHz: value(
        'notchFrequencyHz',
        settings.displayNotchFrequencyHz,
      ),
    );
  }

  void _persistDisplaySettings() {
    final settings = context.read<SettingsService>();
    final hidden = _hiddenChannelLabels.toList()..sort();
    final profile = <String, dynamic>{
      'durationSeconds': _durationSeconds,
      'viewMode': _viewMode,
      'autoscale': _autoscale,
      'notchEnabled': _notchEnabled,
      'bandpassEnabled': _bandpassEnabled,
      'gain': _gain,
      'eegScale': _eegFixedScale,
      'ecgScale': _ecgFixedScale,
      'ppgScale': _ppgFixedScale,
      'eegHighPassHz': _filterSettings.eegHighPassHz,
      'eegLowPassHz': _filterSettings.eegLowPassHz,
      'eogHighPassHz': _filterSettings.eogHighPassHz,
      'eogLowPassHz': _filterSettings.eogLowPassHz,
      'emgHighPassHz': _filterSettings.emgHighPassHz,
      'emgLowPassHz': _filterSettings.emgLowPassHz,
      'ecgHighPassHz': _filterSettings.ecgHighPassHz,
      'ecgLowPassHz': _filterSettings.ecgLowPassHz,
      'notchFrequencyHz': _filterSettings.notchFrequencyHz,
      'montageReferences': Map<String, String>.of(_montageReferences),
      'hiddenChannelLabels': hidden,
    };
    final key = widget.displayStateKey;
    if (key != null && key.trim().isNotEmpty) {
      settings.updateViewerDisplayProfile(key, profile);
      return;
    }
    settings.update((settings) {
      settings.waveformDurationSeconds = _durationSeconds;
      settings.waveformViewMode = _viewMode;
      settings.waveformAutoscaleV2 = _autoscale;
      settings.notchEnabled = _notchEnabled;
      settings.bandpassEnabled = _bandpassEnabled;
      settings.waveformGain = _gain;
      settings.eegDisplayScaleUv = _eegFixedScale;
      settings.ecgDisplayScaleUv = _ecgFixedScale;
      settings.ppgDisplayScale = _ppgFixedScale;
      settings.eegDisplayHighPassHz = _filterSettings.eegHighPassHz;
      settings.eegDisplayLowPassHz = _filterSettings.eegLowPassHz;
      settings.eogDisplayHighPassHz = _filterSettings.eogHighPassHz;
      settings.eogDisplayLowPassHz = _filterSettings.eogLowPassHz;
      settings.emgDisplayHighPassHz = _filterSettings.emgHighPassHz;
      settings.emgDisplayLowPassHz = _filterSettings.emgLowPassHz;
      settings.ecgDisplayHighPassHz = _filterSettings.ecgHighPassHz;
      settings.ecgDisplayLowPassHz = _filterSettings.ecgLowPassHz;
      settings.displayNotchFrequencyHz = _filterSettings.notchFrequencyHz;
      settings.displayMontageReferences = Map.of(_montageReferences);
      settings.displayHiddenChannelLabels = hidden;
    });
  }

  void _resetDisplayFilterForControlChange() {
    _displayFilter.reset();
    for (var i = 0; i < _runningMeans.length; i++) {
      _runningMeans[i] = double.nan;
    }
    _autoscaleSuppressionSamples = _eegSampleRate;
  }

  void _updateAutomaticScales({bool force = false}) {
    if (_autoscaleSuppressionSamples > 0 && !force) return;
    var eeg = 20.0;
    var ecg = 100.0;
    var ppg = 5.0;
    final points = _eegSampleRate * _durationSeconds;
    for (var i = 0; i < _eegBuffers.length; i++) {
      final data = _eegBuffers[i];
      if (data.length < math.min(_eegSampleRate, points)) continue;
      final peak = RobustWaveformAutoscale.amplitude(
        data,
        visiblePoints: points,
      );
      final label = i < _eegChannelLabels.length ? _eegChannelLabels[i] : '';
      if (_isPpgLabel(label)) {
        ppg = math.max(ppg, peak * 1.15);
      } else if (_isEcgLabel(label)) {
        ecg = math.max(ecg, peak * 1.15);
      } else {
        eeg = math.max(eeg, peak * 1.15);
      }
    }
    _eegAutoScale = eeg;
    _ecgAutoScale = ecg;
    _ppgAutoScale = ppg;
  }

  List<double> get _channelScaleFactors =>
      List.generate(_eegBuffers.length, (index) {
        final label = index < _eegChannelLabels.length
            ? _eegChannelLabels[index]
            : '';
        if (_isPpgLabel(label)) {
          return _autoscale ? _ppgAutoScale : _ppgFixedScale;
        }
        if (_isEcgLabel(label)) {
          return _autoscale ? _ecgAutoScale : _ecgFixedScale;
        }
        return _autoscale ? _eegAutoScale : _eegFixedScale;
      });

  void _processNirsSample(NirsSample sample) {
    if (!mounted) return;
    {
      final chCount = sample.channels.length;
      while (_nirsBuffers.length < chCount) {
        _nirsBuffers.add([]);
      }
      if (sample.channelNames.length == chCount) {
        _nirsChannelLabels.clear();
        _nirsChannelLabels.addAll(sample.channelNames);
      } else {
        while (_nirsChannelLabels.length < chCount) {
          _nirsChannelLabels.add('NIRS ${_nirsChannelLabels.length + 1}');
        }
      }

      for (var i = 0; i < chCount; i++) {
        _nirsBuffers[i].add(sample.channels[i]);
        if (_nirsBuffers[i].length > 500) {
          _nirsBuffers[i].removeAt(0);
        }
      }
    }
    _requestRepaint();
  }

  void _requestRepaint() {
    if (!mounted || _repaintTimer != null) return;
    const interval = Duration(milliseconds: 40);
    final elapsed = DateTime.now().difference(_lastRepaintAt);
    if (elapsed >= interval) {
      _lastRepaintAt = DateTime.now();
      setState(() {});
      return;
    }
    _repaintTimer = Timer(interval - elapsed, () {
      _repaintTimer = null;
      if (!mounted) return;
      _lastRepaintAt = DateTime.now();
      setState(() {});
    });
  }

  void _calculateMetrics() {
    if (_eegBuffers.isEmpty || _eegBuffers[0].isEmpty) return;
    final data = _eegBuffers[0];
    final mean = data.reduce((a, b) => a + b) / data.length;
    final maxVal = data.reduce(math.max);
    final minVal = data.reduce(math.min);
    _peakToPeakUv = maxVal - minVal;

    final outliers = data.where((v) => (v - mean).abs() > 200.0).length;
    _artifactRatio = outliers / data.length;
    _signalStable = _peakToPeakUv < 150.0 && _artifactRatio < 0.10;
  }

  @override
  void dispose() {
    _btEegSub?.cancel();
    _lslEegSub?.cancel();
    _nirsSub?.cancel();
    _signalSub?.cancel();
    _repaintTimer?.cancel();
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lightTeal = const Color(0xFF14B8A6);

    if (_tabs.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: const Center(
          child: Text(
            'No EEG or fNIRS service attached',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }

    return Column(
      children: [
        if (_tabs.length > 1)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(10),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorColor: lightTeal,
              labelColor: lightTeal,
              unselectedLabelColor: Colors.white54,
              indicatorSize: TabBarIndicatorSize.tab,
              tabs: _tabs.map((name) => Tab(text: name, height: 38)).toList(),
            ),
          ),

        if (widget.showControls && _hasEeg) _buildControlsBar(lightTeal),

        Expanded(
          child: _tabs.length > 1
              ? TabBarView(
                  controller: _tabController,
                  physics: const NeverScrollableScrollPhysics(),
                  children: _tabs.map((tab) {
                    if (tab == 'EEG') return _buildEegView(lightTeal);
                    if (tab == 'fNIRS') return _buildNirsView();
                    return _buildDualView(lightTeal);
                  }).toList(),
                )
              : (_hasEeg ? _buildEegView(lightTeal) : _buildNirsView()),
        ),

        if (widget.showMetrics) ...[
          const SizedBox(height: 12),
          _buildMetricsPanel(),
        ],
      ],
    );
  }

  Widget _buildControlsBar(Color activeColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Text(
              'Epoch',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(width: 4),
            DropdownButton<int>(
              value: _durationSeconds,
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              underline: const SizedBox(),
              items: const [2, 4, 8, 10, 20, 30]
                  .map(
                    (seconds) => DropdownMenuItem(
                      value: seconds,
                      child: Text('${seconds}s'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                setState(() {
                  _durationSeconds = value;
                  _pageSampleCount = 0;
                  if (_viewMode == 'page') {
                    for (final buffer in _eegBuffers) {
                      buffer.clear();
                    }
                  }
                });
                _persistDisplaySettings();
              },
            ),
            const SizedBox(width: 10),
            DropdownButton<String>(
              value: _viewMode,
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 'rolling', child: Text('Rolling')),
                DropdownMenuItem(value: 'page', child: Text('Page')),
              ],
              onChanged: (value) {
                if (value != null) _setViewMode(value);
              },
            ),
            const SizedBox(width: 6),
            const Text(
              'Auto',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            _compactCheckbox(
              value: _autoscale,
              activeColor: activeColor,
              onChanged: _setAutoscale,
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: activeColor,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              onPressed: () => _showScaleSettings(activeColor),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Manual scale'),
            ),
            IconButton(
              tooltip: 'Magnify waveforms and use manual scale',
              visualDensity: VisualDensity.compact,
              color: activeColor,
              onPressed: () => _refineManualScale(0.8),
              icon: const Icon(Icons.zoom_in, size: 20),
            ),
            IconButton(
              tooltip: 'Reduce waveforms and use manual scale',
              visualDensity: VisualDensity.compact,
              color: activeColor,
              onPressed: () => _refineManualScale(1.25),
              icon: const Icon(Icons.zoom_out, size: 20),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: activeColor,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              onPressed: () => _showFilterSettings(activeColor),
              icon: const Icon(Icons.filter_alt_outlined, size: 18),
              label: const Text('Filters'),
            ),
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: activeColor,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              onPressed: _eegChannelLabels.length > 1
                  ? () => _showMontageSettings(activeColor)
                  : null,
              icon: const Icon(Icons.compare_arrows, size: 18),
              label: const Text('Montage'),
            ),
            const SizedBox(width: 6),
            const Text(
              'Notch',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            _compactCheckbox(
              value: _notchEnabled,
              activeColor: activeColor,
              onChanged: (value) {
                setState(() => _notchEnabled = value);
                _resetDisplayFilterForControlChange();
                _persistDisplaySettings();
              },
            ),
            const SizedBox(width: 4),
            const Text(
              'BP',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            _compactCheckbox(
              value: _bandpassEnabled,
              activeColor: activeColor,
              onChanged: (value) {
                setState(() => _bandpassEnabled = value);
                _resetDisplayFilterForControlChange();
                _persistDisplaySettings();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _compactCheckbox({
    required bool value,
    required Color activeColor,
    required ValueChanged<bool> onChanged,
  }) {
    return SizedBox(
      height: 24,
      width: 32,
      child: Checkbox(
        value: value,
        activeColor: activeColor,
        onChanged: (next) => onChanged(next ?? false),
      ),
    );
  }

  Future<void> _showFilterSettings(Color activeColor) async {
    var selected = _filterSettings;
    const eegBands = [(0.3, 35.0), (0.3, 30.0), (1.0, 70.0)];
    const eogBands = [(0.3, 15.0), (0.1, 15.0), (0.3, 35.0)];
    const emgBands = [(10.0, 100.0), (20.0, 100.0), (10.0, 70.0)];
    var notchHz = selected.notchFrequencyHz == 60 ? 60.0 : 50.0;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) {
          Widget bandPicker(
            String title,
            (double, double) value,
            List<(double, double)> options,
            ValueChanged<(double, double)> onChanged,
          ) {
            final current = options.contains(value) ? value : options.first;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(title, style: const TextStyle(color: Colors.white)),
              trailing: DropdownButton<(double, double)>(
                value: current,
                dropdownColor: const Color(0xFF1E293B),
                style: const TextStyle(color: Colors.white),
                items: options
                    .map(
                      (band) => DropdownMenuItem(
                        value: band,
                        child: Text('${band.$1}–${band.$2} Hz'),
                      ),
                    )
                    .toList(),
                onChanged: (band) {
                  if (band != null) onChanged(band);
                },
              ),
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Display filters by signal type',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'These filters affect the viewer only. EDF data stays raw.',
                    style: TextStyle(color: Colors.white54),
                  ),
                  bandPicker(
                    'EEG',
                    (selected.eegHighPassHz, selected.eegLowPassHz),
                    eegBands,
                    (band) => updateSheet(
                      () => selected = DisplayFilterSettings(
                        eegHighPassHz: band.$1,
                        eegLowPassHz: band.$2,
                        eogHighPassHz: selected.eogHighPassHz,
                        eogLowPassHz: selected.eogLowPassHz,
                        emgHighPassHz: selected.emgHighPassHz,
                        emgLowPassHz: selected.emgLowPassHz,
                        ecgHighPassHz: selected.ecgHighPassHz,
                        ecgLowPassHz: selected.ecgLowPassHz,
                        notchFrequencyHz: notchHz,
                      ),
                    ),
                  ),
                  bandPicker(
                    'EOG',
                    (selected.eogHighPassHz, selected.eogLowPassHz),
                    eogBands,
                    (band) => updateSheet(
                      () => selected = DisplayFilterSettings(
                        eegHighPassHz: selected.eegHighPassHz,
                        eegLowPassHz: selected.eegLowPassHz,
                        eogHighPassHz: band.$1,
                        eogLowPassHz: band.$2,
                        emgHighPassHz: selected.emgHighPassHz,
                        emgLowPassHz: selected.emgLowPassHz,
                        ecgHighPassHz: selected.ecgHighPassHz,
                        ecgLowPassHz: selected.ecgLowPassHz,
                        notchFrequencyHz: notchHz,
                      ),
                    ),
                  ),
                  bandPicker(
                    'EMG',
                    (selected.emgHighPassHz, selected.emgLowPassHz),
                    emgBands,
                    (band) => updateSheet(
                      () => selected = DisplayFilterSettings(
                        eegHighPassHz: selected.eegHighPassHz,
                        eegLowPassHz: selected.eegLowPassHz,
                        eogHighPassHz: selected.eogHighPassHz,
                        eogLowPassHz: selected.eogLowPassHz,
                        emgHighPassHz: band.$1,
                        emgLowPassHz: band.$2,
                        ecgHighPassHz: selected.ecgHighPassHz,
                        ecgLowPassHz: selected.ecgLowPassHz,
                        notchFrequencyHz: notchHz,
                      ),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Mains notch',
                      style: TextStyle(color: Colors.white),
                    ),
                    trailing: DropdownButton<double>(
                      value: notchHz,
                      dropdownColor: const Color(0xFF1E293B),
                      style: const TextStyle(color: Colors.white),
                      items: const [
                        DropdownMenuItem(value: 50, child: Text('50 Hz')),
                        DropdownMenuItem(value: 60, child: Text('60 Hz')),
                      ],
                      onChanged: (value) {
                        if (value != null) updateSheet(() => notchHz = value);
                      },
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () {
                        selected = DisplayFilterSettings(
                          eegHighPassHz: selected.eegHighPassHz,
                          eegLowPassHz: selected.eegLowPassHz,
                          eogHighPassHz: selected.eogHighPassHz,
                          eogLowPassHz: selected.eogLowPassHz,
                          emgHighPassHz: selected.emgHighPassHz,
                          emgLowPassHz: selected.emgLowPassHz,
                          ecgHighPassHz: selected.ecgHighPassHz,
                          ecgLowPassHz: selected.ecgLowPassHz,
                          notchFrequencyHz: notchHz,
                        );
                        setState(() {
                          _filterSettings = selected;
                        });
                        _resetDisplayFilterForControlChange();
                        _persistDisplaySettings();
                        Navigator.pop(sheetContext);
                      },
                      child: const Text('Apply'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _showMontageSettings(Color activeColor) async {
    final references = Map<String, String>.of(_montageReferences);
    final hidden = Set<String>.of(_hiddenChannelLabels);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Display montage',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text(
                  'Enable the traces you need and choose a reference (A − reference). '
                  'These are display settings only; capture is controlled in the device profile.',
                  style: TextStyle(color: Colors.white54),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: _eegChannelLabels.map((label) {
                      final candidates = _eegChannelLabels
                          .where((candidate) => candidate != label)
                          .toList();
                      final current = candidates.contains(references[label])
                          ? references[label]
                          : null;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Checkbox(
                          value: !hidden.contains(label),
                          activeColor: activeColor,
                          onChanged: (visible) => updateSheet(() {
                            if (visible ?? false) {
                              hidden.remove(label);
                            } else {
                              hidden.add(label);
                            }
                          }),
                        ),
                        title: Text(
                          label,
                          style: TextStyle(
                            color: hidden.contains(label)
                                ? Colors.white38
                                : Colors.white,
                          ),
                        ),
                        trailing: DropdownButton<String>(
                          value: current ?? '__none__',
                          onChanged: hidden.contains(label)
                              ? null
                              : (reference) => updateSheet(() {
                                  if (reference == null ||
                                      reference == '__none__') {
                                    references.remove(label);
                                  } else {
                                    references[label] = reference;
                                  }
                                }),
                          dropdownColor: const Color(0xFF1E293B),
                          style: const TextStyle(color: Colors.white),
                          items: [
                            const DropdownMenuItem(
                              value: '__none__',
                              child: Text('No reference'),
                            ),
                            ...candidates.map(
                              (candidate) => DropdownMenuItem(
                                value: candidate,
                                child: Text(candidate),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => updateSheet(references.clear),
                      child: const Text('Clear references'),
                    ),
                    TextButton(
                      onPressed: () => updateSheet(hidden.clear),
                      child: const Text('Show all'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () {
                        setState(() {
                          _montageReferences = Map.of(references);
                          _hiddenChannelLabels = Set.of(hidden);
                          for (var i = 0; i < _visibleEegChannels.length; i++) {
                            final label = i < _eegChannelLabels.length
                                ? _eegChannelLabels[i]
                                : 'Ch ${i + 1}';
                            _visibleEegChannels[i] = !hidden.contains(label);
                          }
                        });
                        _resetDisplayFilterForControlChange();
                        _persistDisplaySettings();
                        Navigator.pop(sheetContext);
                      },
                      child: const Text('Apply'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _setViewMode(String mode) {
    setState(() {
      _viewMode = mode == 'page' ? 'page' : 'rolling';
      if (_viewMode == 'page' && _durationSeconds < 10) {
        _durationSeconds = 10;
      }
      _pageSampleCount = 0;
      if (_viewMode == 'page') {
        for (final buffer in _eegBuffers) {
          buffer.clear();
        }
      }
    });
    _persistDisplaySettings();
  }

  void _setAutoscale(bool enabled) {
    setState(() {
      if (_autoscale && !enabled) {
        _captureAutomaticScale();
      }
      _autoscale = enabled;
      if (enabled) {
        _autoscaleSuppressionSamples = 0;
        _updateAutomaticScales(force: true);
      }
    });
    _persistDisplaySettings();
  }

  void _captureAutomaticScale() {
    _updateAutomaticScales();
    final snapshot = WaveformScaleSnapshot.capture(
      eegUv: _eegAutoScale,
      ecgUv: _ecgAutoScale,
      ppg: _ppgAutoScale,
    );
    _eegFixedScale = snapshot.eegUv;
    _ecgFixedScale = snapshot.ecgUv;
    _ppgFixedScale = snapshot.ppg;
  }

  void _refineManualScale(double factor) {
    setState(() {
      if (_autoscale) {
        _captureAutomaticScale();
        _autoscale = false;
      }
      _eegFixedScale = (_eegFixedScale * factor).clamp(10.0, 15000.0);
      _ecgFixedScale = (_ecgFixedScale * factor).clamp(100.0, 30000.0);
      _ppgFixedScale = (_ppgFixedScale * factor).clamp(5.0, 32768.0);
    });
    _persistDisplaySettings();
  }

  Future<void> _showScaleSettings(Color activeColor) async {
    var eegScale = _eegFixedScale;
    var ecgScale = _ecgFixedScale;
    var ppgScale = _ppgFixedScale;
    var automatic = _autoscale;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Waveform display scale',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Autoscale',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'Turning this off captures and keeps the current automatic scale.',
                    style: TextStyle(color: Colors.white54),
                  ),
                  activeThumbColor: activeColor,
                  value: automatic,
                  onChanged: (value) {
                    _setAutoscale(value);
                    updateSheet(() {
                      automatic = value;
                      eegScale = _eegFixedScale;
                      ecgScale = _ecgFixedScale;
                      ppgScale = _ppgFixedScale;
                    });
                  },
                ),
                _buildScaleSlider(
                  label: 'EEG full scale',
                  unit: 'µV',
                  value: eegScale,
                  minimum: 10,
                  maximum: 15000,
                  enabled: !automatic,
                  activeColor: activeColor,
                  onChanged: (value) {
                    updateSheet(() => eegScale = value);
                    setState(() => _eegFixedScale = value);
                  },
                ),
                _buildScaleSlider(
                  label: 'ECG full scale',
                  unit: 'µV',
                  value: ecgScale,
                  minimum: 100,
                  maximum: 30000,
                  enabled: !automatic,
                  activeColor: activeColor,
                  onChanged: (value) {
                    updateSheet(() => ecgScale = value);
                    setState(() => _ecgFixedScale = value);
                  },
                ),
                _buildScaleSlider(
                  label: 'PPG full scale',
                  unit: 'a.u.',
                  value: ppgScale,
                  minimum: 5,
                  maximum: 32768,
                  enabled: !automatic,
                  activeColor: activeColor,
                  onChanged: (value) {
                    updateSheet(() => ppgScale = value);
                    setState(() => _ppgFixedScale = value);
                  },
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () {
                      setState(() {
                        _autoscale = automatic;
                        _eegFixedScale = eegScale;
                        _ecgFixedScale = ecgScale;
                        _ppgFixedScale = ppgScale;
                      });
                      _persistDisplaySettings();
                      Navigator.pop(sheetContext);
                    },
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    _persistDisplaySettings();
  }

  Widget _buildScaleSlider({
    required String label,
    required String unit,
    required double value,
    required double minimum,
    required double maximum,
    required bool enabled,
    required Color activeColor,
    required ValueChanged<double> onChanged,
  }) {
    final normalized = (math.log(value / minimum) / math.log(maximum / minimum))
        .clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ±${value.round()} $unit',
          style: TextStyle(color: enabled ? Colors.white : Colors.white54),
        ),
        Slider(
          value: normalized,
          activeColor: activeColor,
          onChanged: enabled
              ? (position) => onChanged(
                  (minimum * math.pow(maximum / minimum, position)).toDouble(),
                )
              : null,
        ),
      ],
    );
  }

  Widget _buildEegView(Color lightTeal) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: _eegBuffers.isNotEmpty && _eegBuffers[0].isNotEmpty
            ? Padding(
                padding: const EdgeInsets.only(top: 10.0),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final visibility = _visibleEegChannels.isNotEmpty
                        ? _visibleEegChannels
                        : List.filled(_eegBuffers.length, true);
                    final visibleCount =
                        List.generate(
                          _eegBuffers.length,
                          (index) => index,
                        ).where((index) {
                          return index < visibility.length && visibility[index];
                        }).length;
                    final canvasHeight =
                        WaveformPainter.canvasHeightForChannels(
                          channelCount: visibleCount,
                          availableHeight: constraints.maxHeight,
                        );
                    return Scrollbar(
                      child: SingleChildScrollView(
                        child: SizedBox(
                          width: constraints.maxWidth,
                          height: canvasHeight,
                          child: CustomPaint(
                            painter: WaveformPainter(
                              channels: _eegBuffers,
                              visibleChannels: visibility,
                              stacked: true,
                              selectedChannel: 0,
                              gain: _gain,
                              sampleRate: _eegSampleRate.toDouble(),
                              durationSeconds: _durationSeconds,
                              autoscale: false,
                              channelLabels: _displayChannelLabels,
                              channelScaleFactors: _channelScaleFactors,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              )
            : Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: lightTeal),
                    const SizedBox(height: 12),
                    const Text(
                      'Waiting for EEG stream...',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildNirsView() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: _nirsBuffers.isNotEmpty && _nirsBuffers.any((b) => b.isNotEmpty)
            ? CustomPaint(
                painter: NirsWaveformPainter(
                  buffers: _nirsBuffers,
                  channelNames: _nirsChannelLabels,
                  hiddenChannels: _hiddenNirsChannels,
                ),
              )
            : const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFFB57BFF)),
                    SizedBox(height: 12),
                    Text(
                      'Waiting for fNIRS stream...',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildDualView(Color lightTeal) {
    return Column(
      children: [
        Expanded(
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Stack(
              children: [
                Positioned.fill(child: _buildEegView(lightTeal)),
                const Positioned(
                  left: 10,
                  top: 5,
                  child: Text(
                    'EEG Waveforms',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Stack(
              children: [
                Positioned.fill(child: _buildNirsView()),
                const Positioned(
                  left: 10,
                  top: 5,
                  child: Text(
                    'fNIRS Waveforms',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMetricsPanel() {
    final receivedRate = widget.eegService?.deliveredSampleRate;
    final expectedRate = widget.eegService?.sampleRate;
    final saturatedChannels =
        widget.eegService?.adcSaturatedChannelLabels ?? const <String>[];
    final rateRatio = receivedRate != null && expectedRate != null
        ? receivedRate / expectedRate
        : null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          if (_hasEeg) ...[
            _buildMetricItem(
              'Peak-to-Peak',
              '${_peakToPeakUv.toStringAsFixed(1)} µV',
              _peakToPeakUv < 150
                  ? const Color(0xFF10B981)
                  : const Color(0xFFFBBF24),
            ),
            _buildMetricItem(
              'Artifact Ratio',
              '${(_artifactRatio * 100).toStringAsFixed(1)}%',
              _artifactRatio < 0.1
                  ? const Color(0xFF10B981)
                  : const Color(0xFFEF4444),
            ),
            _buildMetricItem(
              'EEG Sensor Status',
              saturatedChannels.isNotEmpty
                  ? 'ADC SAT: ${saturatedChannels.join(', ')}'
                  : _signalStable
                  ? 'GOOD (STABLE)'
                  : 'NOISY',
              saturatedChannels.isNotEmpty
                  ? const Color(0xFFEF4444)
                  : _signalStable
                  ? const Color(0xFF10B981)
                  : const Color(0xFFEF4444),
            ),
            if (receivedRate != null)
              _buildMetricItem(
                'Received Rate',
                '${receivedRate.toStringAsFixed(0)} / '
                    '${expectedRate!.toStringAsFixed(0)} Hz',
                rateRatio! >= 0.9
                    ? const Color(0xFF10B981)
                    : rateRatio >= 0.75
                    ? const Color(0xFFFBBF24)
                    : const Color(0xFFEF4444),
              ),
          ],
          if (_hasNirs && !_hasEeg) ...[
            _buildMetricItem(
              'fNIRS Channels',
              '${widget.nirsService?.channelCount ?? 0} active',
              const Color(0xFF10B981),
            ),
            _buildMetricItem(
              'Stream Name',
              widget.nirsService?.connectedStreamName ?? 'N/A',
              const Color(0xFFB57BFF),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMetricItem(String label, String value, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 11,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}
