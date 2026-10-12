import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ccs_mobile_studio/core/services/settings_service.dart';
import 'package:ccs_mobile_studio/modules/resonance/resonance_screen.dart';

void main() {
  for (final width in [390.0, 1200.0]) {
    testWidgets('assessment setup is usable at width $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: SettingsService(),
          child: MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: const ResonanceScreen(),
          ),
        ),
      );
      expect(find.text('Quick sweep'), findsOneWidget);
      await tester.tap(find.text('Adaptive Ψ'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Experimental Bayesian assessment:'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('xAMP-L10 · ECG'));
      await tester.tap(find.text('xAMP-L10 · ECG'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('resonance-channel')))
            .controller!
            .text,
        'ECG',
      );
      await tester.ensureVisible(find.text('Timing and pacing'));
      await tester.tap(find.text('Timing and pacing'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('resonance-measureSeconds')),
        '180',
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('30s settling + 180s measurement'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Scientific references'));
      await tester.tap(find.text('Scientific references'));
      await tester.pumpAndSettle();
      expect(find.text('Shaffer & Meehan (2020)'), findsOneWidget);
      expect(find.text('Kontsevich & Tyler (1999)'), findsOneWidget);
      expect(find.text('Prins (2013)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
