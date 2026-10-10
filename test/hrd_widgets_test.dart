import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_mobile_studio/modules/hrd/hrd_feedback_widgets.dart';
import 'package:ccs_mobile_studio/modules/hrd/hrd_models.dart';

void main() {
  test('slider encoding is bipolar and neutral cannot submit', () {
    expect(() => HrdSliderAnswer(0), throwsArgumentError);
    expect(() => HrdSliderAnswer(double.nan), throwsArgumentError);
    expect(HrdSliderAnswer(-6).response, 0);
    expect(HrdSliderAnswer(-6).confidence, 6);
    expect(HrdSliderAnswer(9).response, 1);
    expect(HrdSliderAnswer(9).confidence, 9);
    expect(const HrdConfig().toJson()['responseMode'], 'buttons');
  });
  testWidgets('slider requires an explicit direction and confirmation', (
    tester,
  ) async {
    HrdSliderAnswer? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HrdCombinedResponse(onConfirm: (v) => selected = v),
        ),
      ),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('hrd-confirm-slider')))
          .onPressed,
      isNull,
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(6);
    await tester.pump();
    expect(selected, isNull);
    await tester.tap(find.byKey(const Key('hrd-confirm-slider')));
    expect(selected!.response, 1);
    expect(selected!.confidence, 6);
  });
  testWidgets(
    'results label axes, explain uncertainty, and reveal selected rounds without overflow',
    (tester) async {
      final rows = List.generate(
        10,
        (i) => <String, Object?>{
          'Trial': i + 1,
          'TrialType': i == 0 || i == 8 ? 'catch' : 'psi',
          'ActualRate': 72.0 + i % 3,
          'PresentedRate': 60.0 + i,
          'PsiDeltaRate': -12.0 + i,
          'SubjResponse': i == 7 ? null : i % 2,
          'SubjRating': 6,
          'EstimatedRateMean': i == 0 ? double.nan : -10.0 + i / 2,
          'EstimatedRateLow': -14.0 + i / 2,
          'EstimatedRateHigh': -6.0 + i / 2,
        },
      );
      if (Platform.environment['HRD_REVIEW_OUTPUT'] != null) {
        await tester.runAsync(() async {
          for (final entry in {
            'ReviewFont': '/System/Library/Fonts/Supplemental/Arial.ttf',
            'MaterialIcons':
                '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          }.entries) {
            final loader = FontLoader(entry.key)
              ..addFont(
                File(
                  entry.value,
                ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
              );
            await loader.load();
          }
        });
      }
      final boundary = GlobalKey();
      Future<void> show(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true).copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: Platform.environment['HRD_REVIEW_OUTPUT'] != null
                    ? 'ReviewFont'
                    : null,
              ),
            ),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: SingleChildScrollView(
                  child: HrdResultsPanel(
                    rows: rows,
                    estimate: const [-5.5, -7, -4, 5.2],
                    paths: const [],
                    complete: true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(const Size(1200, 1000));
      expect(find.text('Estimated rate offset'), findsOneWidget);
      expect(find.textContaining('not a 95%'), findsOneWidget);
      final output = Platform.environment['HRD_REVIEW_OUTPUT'];
      if (output != null) {
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(output).create(recursive: true);
          await File(
            '$output/results.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('Heart & feedback'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Compare the measured heart rate with the feedback rate on each round.',
        ),
        findsOneWidget,
      );
      final chart = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is HrdAccessibleChart,
      );
      await tester.tapAt(tester.getCenter(chart));
      await tester.pump();
      expect(find.textContaining('Requested difference'), findsOneWidget);
      await show(const Size(390, 1100));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('journey rewards completion without accuracy feedback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: HrdJourneyProgress(
            completed: 3,
            total: 10,
            stage: 'Focus on your heart',
            collecting: true,
            fraction: 0.5,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3 of 10 rounds completed'), findsOneWidget);
    expect(find.text('50% of this listening window'), findsOneWidget);
    expect(find.textContaining('accuracy'), findsNothing);
  });
}
