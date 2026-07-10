import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../eeg/acquisition_service.dart';
import '../eeg/lsl_eeg_acquisition_service.dart';
import '../eeg/display_filter.dart';
import '../models/eeg_sample.dart';
import '../models/nirs_sample.dart';
import '../services/nirs_acquisition_service.dart';
import 'waveform_painter.dart';
import 'nirs_waveform_painter.dart';

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
    this.initialDurationSeconds = 4,
    this.showControls = true,
    this.showMetrics = true,
  });

  final AcquisitionService? eegService;
  final LslEegAcquisitionService? lslEegService;
  final NirsAcquisitionService? nirsService;
  final int initialDurationSeconds;
  final bool showControls;
  final bool showMetrics;

  @override
  State<EegViewer> createState() => _EegViewerState();
}

class _EegViewerState extends State<EegViewer> with SingleTickerProviderStateMixin {
  late TabController? _tabController;
  final List<List<double>> _eegBuffers = [];
  final List<List<double>> _nirsBuffers = [];
  final List<String> _eegChannelLabels = [];
  final List<String> _nirsChannelLabels = [];
  final Set<int> _hiddenNirsChannels = {};
  final List<bool> _visibleEegChannels = [];

  StreamSubscription<EegSample>? _btEegSub;
  StreamSubscription<EegSample>? _lslEegSub;
  StreamSubscription<NirsSample>? _nirsSub;

  // Display filtering
  final DisplayFilter _displayFilter = DisplayFilter();
  final List<double> _runningMeans = [];
  bool _notchEnabled = true;
  bool _bandpassEnabled = true;
  bool _autoscale = true;
  double _gain = 1.2;
  late int _durationSeconds;

  // Signal quality metrics
  double _peakToPeakUv = 0.0;
  double _artifactRatio = 0.0;
  bool _signalStable = false;

  bool _hasEeg = false;
  bool _hasNirs = false;
  final List<String> _tabs = [];

  @override
  void initState() {
    super.initState();
    _durationSeconds = widget.initialDurationSeconds;
    _hasEeg = widget.eegService != null || widget.lslEegService != null;
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

    // 3. fNIRS
    if (widget.nirsService != null) {
      _nirsSub = widget.nirsService!.samples.listen(_processNirsSample);
    }
  }

  void _processEegSample(EegSample sample) {
    if (!mounted) return;
    setState(() {
      final chCount = sample.channels.length;
      while (_eegBuffers.length < chCount) {
        _eegBuffers.add([]);
        _runningMeans.add(0.0);
        _visibleEegChannels.add(true);
        _eegChannelLabels.add('Ch ${_eegBuffers.length}');
      }
      if (_eegChannelLabels.length == chCount && widget.lslEegService != null) {
        final names = widget.lslEegService!.channelNames;
        if (names.length == chCount) {
          for (var i = 0; i < chCount; i++) _eegChannelLabels[i] = names[i];
        }
      }

      final filtered = _displayFilter.process(
        sample.channels,
        notch: _notchEnabled,
        bandpass: _bandpassEnabled,
      );

      for (var i = 0; i < chCount; i++) {
        final val = filtered[i];
        if (_eegBuffers[i].isEmpty) {
          _runningMeans[i] = val;
        } else {
          _runningMeans[i] = _runningMeans[i] * 0.998 + val * 0.002;
        }
        final zeroCentered = val - _runningMeans[i];

        _eegBuffers[i].add(zeroCentered);
        final maxBuf = (250 * 20).toInt(); // Keep up to 20s at 250Hz
        if (_eegBuffers[i].length > maxBuf) {
          _eegBuffers[i].removeAt(0);
        }
      }
      _calculateMetrics();
    });
  }

  void _processNirsSample(NirsSample sample) {
    if (!mounted) return;
    setState(() {
      final chCount = sample.channels.length;
      while (_nirsBuffers.length < chCount) {
        _nirsBuffers.add([]);
      }
      if (sample.channelNames.length == chCount) {
        _nirsChannelLabels.clear();
        _nirsChannelLabels.addAll(sample.channelNames);
      } else while (_nirsChannelLabels.length < chCount) {
        _nirsChannelLabels.add('NIRS ${_nirsChannelLabels.length + 1}');
      }

      for (var i = 0; i < chCount; i++) {
        _nirsBuffers[i].add(sample.channels[i]);
        if (_nirsBuffers[i].length > 500) {
          _nirsBuffers[i].removeAt(0);
        }
      }
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
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lightTeal = const Color(0xFF14B8A6);

    if (_tabs.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white12),
        ),
        child: const Center(
          child: Text('No EEG or fNIRS service attached', style: TextStyle(color: Colors.white54)),
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
      child: Row(
        children: [
          const Text('Time:', style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(width: 6),
          DropdownButton<int>(
            value: _durationSeconds,
            dropdownColor: const Color(0xFF1E293B),
            style: const TextStyle(color: Colors.white, fontSize: 12),
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 2, child: Text('2s')),
              DropdownMenuItem(value: 4, child: Text('4s')),
              DropdownMenuItem(value: 8, child: Text('8s')),
              DropdownMenuItem(value: 16, child: Text('16s')),
            ],
            onChanged: (val) => setState(() => _durationSeconds = val ?? 4),
          ),
          const Spacer(),
          const Text('Notch', style: TextStyle(color: Colors.white70, fontSize: 12)),
          SizedBox(
            height: 24,
            width: 32,
            child: Checkbox(
              value: _notchEnabled,
              activeColor: activeColor,
              onChanged: (val) => setState(() => _notchEnabled = val ?? false),
            ),
          ),
          const SizedBox(width: 8),
          const Text('BP', style: TextStyle(color: Colors.white70, fontSize: 12)),
          SizedBox(
            height: 24,
            width: 32,
            child: Checkbox(
              value: _bandpassEnabled,
              activeColor: activeColor,
              onChanged: (val) => setState(() => _bandpassEnabled = val ?? false),
            ),
          ),
          const SizedBox(width: 8),
          const Text('Auto', style: TextStyle(color: Colors.white70, fontSize: 12)),
          SizedBox(
            height: 24,
            width: 32,
            child: Checkbox(
              value: _autoscale,
              activeColor: activeColor,
              onChanged: (val) => setState(() => _autoscale = val ?? true),
            ),
          ),
        ],
      ),
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
                child: CustomPaint(
                  painter: WaveformPainter(
                    channels: _eegBuffers,
                    visibleChannels: _visibleEegChannels.isNotEmpty
                        ? _visibleEegChannels
                        : List.filled(_eegBuffers.length, true),
                    stacked: true,
                    selectedChannel: 0,
                    gain: _gain,
                    sampleRate: 250,
                    durationSeconds: _durationSeconds,
                    autoscale: _autoscale,
                    channelLabels: _eegChannelLabels,
                  ),
                ),
              )
            : Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: lightTeal),
                    const SizedBox(height: 12),
                    const Text('Waiting for EEG stream...', style: TextStyle(color: Colors.white54, fontSize: 13)),
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
                    Text('Waiting for fNIRS stream...', style: TextStyle(color: Colors.white54, fontSize: 13)),
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
                  child: Text('EEG Waveforms', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
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
                  child: Text('fNIRS Waveforms', style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMetricsPanel() {
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
              _peakToPeakUv < 150 ? const Color(0xFF10B981) : const Color(0xFFFBBF24),
            ),
            _buildMetricItem(
              'Artifact Ratio',
              '${(_artifactRatio * 100).toStringAsFixed(1)}%',
              _artifactRatio < 0.1 ? const Color(0xFF10B981) : const Color(0xFFEF4444),
            ),
            _buildMetricItem(
              'EEG Sensor Status',
              _signalStable ? 'GOOD (STABLE)' : 'NOISY',
              _signalStable ? const Color(0xFF10B981) : const Color(0xFFEF4444),
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
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
      ],
    );
  }
}
