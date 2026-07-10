import 'package:flutter/foundation.dart';

import '../../core/services/session_manager.dart';
import '../../core/services/alert_service.dart';
import 'erp_engine.dart';

/// Module controller for ANGEL Cognitive ERP Paradigm.
class AngelModule extends ChangeNotifier {
  AngelModule({
    required this.sessionManager,
    required this.alertService,
  });

  final SessionManager sessionManager;
  final AlertService alertService;

  ErpEngine? _activeEngine;
  bool _isSessionRunning = false;

  bool get isSessionRunning => _isSessionRunning;
  ErpEngine? get activeEngine => _activeEngine;

  void startSession(ErpEngine engine) {
    _activeEngine = engine;
    _isSessionRunning = true;
    notifyListeners();
  }

  void endSession() {
    _isSessionRunning = false;
    _activeEngine = null;
    notifyListeners();
  }
}
