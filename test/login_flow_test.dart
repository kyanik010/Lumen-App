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
    expect(find.text('LIVE · FILMS · SERIES'), findsOneWidget);
    expect(find.text('ترفيهك، في مكان واحد'), findsOneWidget);
    expect(find.text('تسجيل الدخول'), findsNWidgets(2));
    expect(find.text('أدخل بيانات حسابك للمتابعة إلى التطبيق.'), findsOneWidget);
    expect(find.text('اسم المستخدم'), findsNWidgets(2));
    expect(find.text('كلمة المرور'), findsNWidgets(2));
    expect(find.text('لتفعيل التطبيق أو الحصول على اشتراك IPTV،'), findsOneWidget);
    expect(find.text('تواصل مع الدعم عبر مسح رمز QR.'), findsOneWidget);
    expect(find.text('امسح الرمز للتواصل مع الدعم'), findsOneWidget);
    expect(find.text('هل تحتاج إلى تفعيل التطبيق؟'), findsNothing);
    expect(find.byType(TextField), findsNWidgets(2));
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

    final password = find.byType(TextField).at(1);
    expect(tester.widget<TextField>(password).obscureText, isTrue);

    await tester.tap(find.byTooltip('إظهار كلمة المرور'));
    await tester.pump();
    expect(tester.widget<TextField>(password).obscureText, isFalse);

    await tester.tap(find.byTooltip('إخفاء كلمة المرور'));
    await tester.pump();
    expect(tester.widget<TextField>(password).obscureText, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login button validates fields and calls activation resolver', (
    tester,
  ) async {
    XtreamCredentials? loggedIn;
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
        home: LoginScreen(
          onLogin: (credentials) => loggedIn = credentials,
          activationResolver: (_, __) async => throw const ActivationApiException(
            'بيانات الاشتراك غير صحيحة أو غير مفعّلة على الهوستات.',
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('login-submit')));
    await tester.pump();
    expect(find.text('أدخل اسم المستخدم وكلمة المرور.'), findsOneWidget);
    expect(loggedIn, isNull);

    await tester.enterText(find.byType(TextField).at(0), 'viewer');
    await tester.enterText(find.byType(TextField).at(1), 'secret');
    await tester.tap(find.byKey(const ValueKey('login-submit')));
    await tester.pump();

    await tester.pumpAndSettle();
    expect(
      find.text('بيانات الاشتراك غير صحيحة أو غير مفعّلة على الهوستات.'),
      findsOneWidget,
    );
    expect(loggedIn, isNull);
    expect(tester.takeException(), isNull);
  });
}
