import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen_tv/activation_api.dart';
import 'package:lumen_tv/models.dart';
import 'package:lumen_tv/screens/login_screen.dart';
import 'package:lumen_tv/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    activePalette = darkPalette;
  });

  Future<void> pumpEagleLogin(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(darkPalette),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: LoginScreen(onLogin: (_) {}),
      ),
    );
    await tester.pump();
  }

  testWidgets('shows Eagle X Arabic login and support QR', (tester) async {
    await pumpEagleLogin(tester);

    expect(find.text('EAGLE X'), findsOneWidget);
    expect(find.text('لديك فترة تجريبية 30 يوم'), findsOneWidget);
    expect(find.text('اضغط هنا لتبدأ'), findsOneWidget);
    expect(find.text('لتفعيل التطبيق او الحصول على اشتراك IPTV'), findsOneWidget);
    expect(find.text('تواصل مع الدعم عبر مسح رمز QR'), findsOneWidget);
    expect(find.text('امسح الرمز للتواصل مع الدعم'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const ValueKey('login-submit')));
    await tester.pump();
    expect(find.text('إضافة الاشتراك'), findsOneWidget);
    expect(find.text('هوست'), findsOneWidget);
    expect(find.text('يوزر'), findsOneWidget);
    expect(find.text('باسورد'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName == 'assets/eagle_x_qr.png',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('password visibility control toggles obscuring', (tester) async {
    await pumpEagleLogin(tester);

    await tester.tap(find.byKey(const ValueKey('login-submit')));
    await tester.pump();
    final password = find.byType(TextField).at(2);
    expect(tester.widget<TextField>(password).obscureText, isTrue);

    await tester.tap(find.byTooltip('إظهار كلمة المرور'));
    await tester.pump();
    expect(tester.widget<TextField>(password).obscureText, isFalse);

    await tester.tap(find.byTooltip('إخفاء كلمة المرور'));
    await tester.pump();
    expect(tester.widget<TextField>(password).obscureText, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('subscription form validates host and required credentials', (
    tester,
  ) async {
    XtreamCredentials? loggedIn;
    await pumpEagleLogin(tester);

    await tester.tap(find.byKey(const ValueKey('login-submit')));
    await tester.pump();
    expect(find.text('إضافة الاشتراك'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('login-submit')));
    await tester.pump();
    expect(find.text('أدخل هوست صالحًا يبدأ بـ http:// أو https://.'), findsOneWidget);
    expect(loggedIn, isNull);

    await tester.enterText(find.byType(TextField).at(0), 'https://provider.example');
    await tester.tap(find.byKey(const ValueKey('login-submit')));
    await tester.pump();
    expect(find.text('أدخل اليوزر والباسورد.'), findsOneWidget);
    expect(loggedIn, isNull);
    expect(tester.takeException(), isNull);
  });
}
