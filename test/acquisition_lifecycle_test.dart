import 'package:ccs_mobile_studio/core/eeg/acquisition_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'stream becomes ready only after a valid sample and disconnect is final',
    () async {
      final service = AcquisitionService()..addSyntheticDevice();
      final device = service.discoveredDevices.single;

      expect(service.isStreamReady, isFalse);
      final connected = await service.connect(device);
      expect(connected, isTrue);
      expect(service.isStreamReady, isTrue);
      expect(service.hasReceivedSamples, isTrue);

      // A duplicate request for the same device is idempotent.
      expect(await service.connect(device), isTrue);

      await service.disconnect();
      expect(service.currentState, AcquisitionState.disconnected);
      expect(service.isStreamReady, isFalse);
      expect(service.connectedDeviceId, isNull);
      expect(service.isRecovering, isFalse);

      service.dispose();
    },
  );
}
