import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen_tv/device_profile.dart';
import 'package:lumen_tv/diagnostics.dart';
import 'package:lumen_tv/models.dart';
import 'package:lumen_tv/screens/diagnostics_screen.dart';
import 'package:lumen_tv/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppDiagnostics.instance.clearForTesting();
    DeviceProfile.isTelevision = false;
    activePalette = darkPalette;
  });

  tearDown(() {
    DeviceProfile.isTelevision = false;
  });

  test('diagnostic redaction removes endpoints and common secrets', () {
    const source =
        'Open http://user:pass@provider.example:8080/live?token=secret '
        'HTTPS · provider.example:443 username=talha password=hunter2 '
        'support@example.com 192.168.1.14:8002';
    final safe = redactDiagnosticText(source);

    expect(safe, isNot(contains('provider.example')));
    expect(safe, isNot(contains('192.168.1.14')));
    expect(safe, isNot(contains('support@example.com')));
    expect(safe, isNot(contains('hunter2')));
    expect(safe, isNot(contains('username=talha')));
    expect(safe, contains('[redacted'));
  });

  test(
    'generated report excludes active profile secrets and user history',
    () async {
      const credentials = XtreamCredentials(
        baseUrl: 'http://provider.example:8080',
        username: 'private-user-420',
        password: 'private-password-420',
      );
      AppDiagnostics.instance.record(
        'Session',
        'Provider http://provider.example:8080 opened',
      );

      final report = await AppDiagnostics.instance.buildReport(
        credentials: credentials,
        userNotes:
            'My username is private-user-420 and password=private-password-420',
      );

      expect(report, contains('Nothing was uploaded automatically.'));
      expect(report, contains('Source type: Provider account'));
      expect(report, isNot(contains(credentials.baseUrl)));
      expect(report, isNot(contains(credentials.username)));
      expect(report, isNot(contains(credentials.password)));
    },
  );

  test('generated report identifies the television device class', () async {
    DeviceProfile.isTelevision = true;
    final report = await AppDiagnostics.instance.buildReport(
      credentials: XtreamCredentials.demoProfile,
    );
    expect(report, contains('Class: Television'));
  });

  testWidgets('diagnostics screen is compact and exposes review actions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(darkPalette),
        home: const DiagnosticsScreen(
          credentials: XtreamCredentials(
            baseUrl: 'https://provider.example',
            username: 'test-user',
            password: 'test-password',
          ),
        ),
      ),
    );
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find
          .textContaining('LUMEN DIAGNOSTIC REPORT')
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }

    expect(find.text('التشخيص والملاحظات'), findsOneWidget);
    expect(find.text('بياناتك خاصة حتى تختار مشاركتها'), findsOneWidget);
    expect(find.text('نسخ التقرير'), findsOneWidget);
    expect(find.text('مشاركة التقرير'), findsOneWidget);
    expect(find.text('مراسلة الدعم'), findsOneWidget);
    expect(find.text('ماذا حدث؟'), findsOneWidget);
    expect(find.text('معاينة التقرير'), findsOneWidget);
    expect(find.textContaining('provider.example'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('television diagnostics avoids keyboard-only notes', (
    tester,
  ) async {
    DeviceProfile.isTelevision = true;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(darkPalette),
        home: const DiagnosticsScreen(
          credentials: XtreamCredentials.demoProfile,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('ماذا حدث؟'), findsNothing);
    expect(find.text('مراسلة الدعم'), findsNothing);
    expect(find.text('نسخ التقرير'), findsOneWidget);
    expect(find.text('مشاركة التقرير'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
