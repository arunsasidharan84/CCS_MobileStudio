import 'package:flutter/foundation.dart';

import '../models/module_type.dart';
import '../eeg/acquisition_service.dart';

/// Manages exclusive BLE streaming access across all modules.
///
/// Only one module can own EEG streaming at a time. This prevents two
/// modules from simultaneously using the BLE connection to the xAMP-L10.
class BleCoordinator extends ChangeNotifier {
  ModuleType? _owner;
  AcquisitionService? _acq;

  /// The module currently holding the streaming lock, or null if none.
  ModuleType? get currentOwner => _owner;

  /// True if no module holds the lock.
  bool get isFree => _owner == null;

  void updateAcquisition(AcquisitionService acq) {
    _acq = acq;
  }

  /// Request exclusive EEG streaming for [module].
  ///
  /// Returns `true` if the lock was granted (nobody else holds it, or the
  /// calling module already holds it).
  /// Returns `false` if another module holds the lock.
  bool requestLock(ModuleType module) {
    if (_owner == null || _owner == module) {
      _owner = module;
      notifyListeners();
      return true;
    }
    debugPrint(
      '[BleCoordinator] Lock denied for ${module.displayName}: '
      '${_owner!.displayName} is currently streaming.',
    );
    return false;
  }

  /// Release the streaming lock held by [module].
  /// Silently ignored if [module] does not hold the lock.
  void releaseLock(ModuleType module) {
    if (_owner == module) {
      _owner = null;
      notifyListeners();
      debugPrint('[BleCoordinator] Lock released by ${module.displayName}.');
    }
  }

  /// Force-release the lock regardless of who holds it.
  /// Use only in emergency / settings reset scenarios.
  void forceRelease() {
    if (_owner != null) {
      debugPrint(
        '[BleCoordinator] Force-releasing lock from ${_owner!.displayName}.',
      );
      _owner = null;
      notifyListeners();
    }
  }

  /// Human-readable description of current lock state.
  String get statusText {
    if (_owner == null) return 'No module streaming';
    return '${_owner!.displayName} is streaming EEG';
  }
}
