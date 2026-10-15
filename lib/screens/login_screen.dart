// The Eagle X login UI is intentionally a branded placeholder while activation-panel
// authentication is pending; legacy login helpers remain for the integration follow-up.
// ignore_for_file: unused_field, unused_element

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../activation_api.dart';
import '../device_profile.dart';
import '../models.dart';
import '../distribution.dart';
import '../responsive.dart';
import '../store.dart';
import '../widgets.dart';
import '../theme.dart';
import '../xtream.dart';
import 'device_pairing_screen.dart';

typedef LoginClientFactory = XtreamClient Function(XtreamCredentials);
typedef LoginCredentialSaver = Future<void> Function(XtreamCredentials);
typedef LoginActivationResolver = Future<XtreamCredentials> Function(
  String username,
  String password,
);

class _LoginCancelled implements Exception {
  const _LoginCancelled();
}

class LoginScreen extends StatefulWidget {
  final void Function(XtreamCredentials) onLogin;
  final LoginClientFactory? clientFactory;
  final LoginCredentialSaver? credentialSaver;
  final LoginActivationResolver? activationResolver;
  final Duration connectionTimeout;
  final Duration storageTimeout;

  const LoginScreen({
    super.key,
    required this.onLogin,
    this.clientFactory,
    this.credentialSaver,
    this.activationResolver,
    this.connectionTimeout = const Duration(seconds: 18),
    this.storageTimeout = const Duration(seconds: 6),
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  late final FocusNode _urlFocus;
  late final FocusNode _userFocus;
  late final FocusNode _passFocus;
  late final FocusNode _submitFocus;
  late final FocusNode _playlistFocus;
  late final FocusNode _demoFocus;
  late final FocusNode _pairingFocus;
  bool get _canPair => DeviceProfile.isTelevision || DeviceProfile.isMobileApp;
  final Map<String, FocusNode> _profileFocus = {};
  bool _busy = false;
  bool _passwordVisible = false;
  String? _error;
  String? _status;
  List<XtreamCredentials> _profiles = [];
  XtreamClient? _pendingClient;
  Completer<dynamic>? _pendingWait;
  Timer? _pendingDeadline;
  int _connectAttempt = 0;

  @override
  void initState() {
    super.initState();
    _urlFocus = _createFocusNode('login-url');
    _userFocus = _createFocusNode('login-username');
    _passFocus = _createFocusNode('login-password');
    _submitFocus = _createFocusNode('login-submit');
    _playlistFocus = _createFocusNode('login-playlist');
    _demoFocus = _createFocusNode('login-demo');
    _pairingFocus = _createFocusNode('login-pairing');
    _urlFocus.onKeyEvent = (_, event) =>
        _moveFromField(event, up: _lastProfileFocus, down: _userFocus);
    _userFocus.onKeyEvent = (_, event) => _moveFromField(
      event,
      right: _passFocus,
      down: _submitFocus,
    );
    _passFocus.onKeyEvent = (_, event) => _moveFromField(
      event,
      up: _userFocus,
      left: _userFocus,
      down: _submitFocus,
    );
    _submitFocus.onKeyEvent = (_, event) =>
        _moveFromControl(event, up: _passFocus);
    _playlistFocus.onKeyEvent = (_, event) => _moveFromControl(
      event,
      up: _submitFocus,
      down: _canPair ? _pairingFocus : _demoFocus,
    );
    _pairingFocus.onKeyEvent = (_, event) =>
        _moveFromControl(event, up: _playlistFocus, down: _demoFocus);
    _demoFocus.onKeyEvent = (_, event) =>
        _moveFromControl(event, up: _canPair ? _pairingFocus : _playlistFocus);
    Store.savedProfiles().then((profiles) {
      if (!mounted) return;
      _syncProfileFocus(profiles);
      setState(() => _profiles = profiles);
    });
  }

  FocusNode _createFocusNode(String label) {
    late final FocusNode node;
    node = FocusNode(debugLabel: label);
    node.addListener(() {
      if (!node.hasFocus) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final focusContext = node.context;
        if (!mounted || focusContext == null) return;
        Scrollable.ensureVisible(
          focusContext,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      });
    });
    return node;
  }

  FocusNode? get _lastProfileFocus =>
      _profiles.isEmpty ? null : _profileFocus[_profileKey(_profiles.last)];

  String _profileKey(XtreamCredentials profile) =>
      '${profile.baseUrl}|${profile.username}|${profile.m3uUrl}|${profile.demo}';

  void _syncProfileFocus(List<XtreamCredentials> profiles) {
    final liveKeys = profiles.map(_profileKey).toSet();
    final removed = _profileFocus.keys
        .where((key) => !liveKeys.contains(key))
        .toList();
    for (final key in removed) {
      _profileFocus.remove(key)?.dispose();
    }
    for (var index = 0; index < profiles.length; index++) {
      final key = _profileKey(profiles[index]);
      final node = _profileFocus.putIfAbsent(
        key,
        () => _createFocusNode('saved-profile-$index'),
      );
      node.onKeyEvent = (_, event) => _moveFromControl(
        event,
        up: index == 0 ? null : _profileFocus[_profileKey(profiles[index - 1])],
        down: index == profiles.length - 1
            ? _urlFocus
            : _profileFocus[_profileKey(profiles[index + 1])],
      );
    }
  }

  bool _isNavigationKeyEvent(KeyEvent event) =>
      event is KeyDownEvent || event is KeyRepeatEvent;

  KeyEventResult _moveFromField(
    KeyEvent event, {
    FocusNode? up,
    FocusNode? down,
    FocusNode? left,
    FocusNode? right,
  }) {
    if (!_isNavigationKeyEvent(event)) return KeyEventResult.ignored;
    final key = event.logicalKey;
    FocusNode? target;
    if (key == LogicalKeyboardKey.arrowUp) {
      target = up;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      target = down;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      target = left;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      target = right;
    }
    if (target == null) return KeyEventResult.ignored;
    target.requestFocus();
    return KeyEventResult.handled;
  }

  KeyEventResult _moveFromControl(
    KeyEvent event, {
    FocusNode? up,
    FocusNode? down,
  }) {
    if (!_isNavigationKeyEvent(event)) return KeyEventResult.ignored;
    FocusNode? target;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      target = up;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      target = down;
    }
    if (target == null) return KeyEventResult.ignored;
    target.requestFocus();
    return KeyEventResult.handled;
  }

  Future<void> _connect(XtreamCredentials c) async {
    final validationError = _validate(c);
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    final attempt = ++_connectAttempt;
    _pendingClient?.close();
    final client = (widget.clientFactory ?? XtreamClient.new)(c);
    _pendingClient = client;
    setState(() {
      _busy = true;
      _error = null;
      _status = c.isDemo ? 'جارٍ فتح العرض التجريبي دون اتصال…' : 'جارٍ التحقق من مزوّد الخدمة…';
    });
    var authenticated = false;
    try {
      await _bounded(
        client.authenticate(),
        widget.connectionTimeout,
        'The provider did not respond within '
        '${_durationLabel(widget.connectionTimeout)}. '
        'Check the server address or try again.',
      );
      if (!mounted || attempt != _connectAttempt) return;
      setState(
        () => _status = c.isDemo
            ? 'جارٍ تجهيز المكتبة التجريبية…'
            : 'جارٍ تأمين هذا الحساب…',
      );
      final save = widget.credentialSaver ?? Store.setActive;
      await _bounded(
        save(c),
        widget.storageTimeout,
        'Lumen reached the provider but could not save this account. '
        'Restart the app and try again.',
      );
      if (!mounted || attempt != _connectAttempt) return;
      authenticated = true;
      setState(() => _status = 'جارٍ فتح مكتبتك…');
      widget.onLogin(c);
      if (mounted && attempt == _connectAttempt) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    } catch (e, stack) {
      if (!mounted || attempt != _connectAttempt) return;
      // Authentication and persistence have already succeeded. A failure in
      // the host's screen transition is not a provider/login failure, and
      // reporting it as one leaves users retrying valid credentials that will
      // appear signed in after restart.
      if (authenticated) {
        debugPrint('Post-login transition failed: $e\n$stack');
        setState(() {
          _busy = false;
          _status = null;
          _error = null;
        });
        return;
      }
      setState(() {
        _error = safeProviderError(e);
        _busy = false;
        _status = null;
      });
    } finally {
      client.close();
      if (identical(_pendingClient, client)) _pendingClient = null;
      if (!authenticated && mounted && attempt == _connectAttempt && _busy) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  String _durationLabel(Duration value) {
    final seconds = value.inSeconds.clamp(1, 999);
    return '$seconds ${seconds == 1 ? 'ثانية' : 'ثوانٍ'}';
  }

  Future<T> _bounded<T>(
    Future<T> operation,
    Duration timeout,
    String timeoutMessage,
  ) {
    final result = Completer<dynamic>();
    _pendingWait = result;
    late final Timer deadline;
    deadline = Timer(timeout, () {
      if (!result.isCompleted) {
        result.completeError(XtreamException(timeoutMessage));
      }
    });
    _pendingDeadline = deadline;
    operation.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    return result.future.then((value) => value as T).whenComplete(() {
      deadline.cancel();
      if (identical(_pendingDeadline, deadline)) _pendingDeadline = null;
      if (identical(_pendingWait, result)) _pendingWait = null;
    });
  }

  void _cancelPendingWait() {
    _pendingDeadline?.cancel();
    _pendingDeadline = null;
    final wait = _pendingWait;
    _pendingWait = null;
    if (wait != null && !wait.isCompleted) {
      wait.completeError(const _LoginCancelled());
    }
  }

  String? _validate(XtreamCredentials credentials) {
    if (credentials.isDemo) return null;
    if (credentials.isM3u) {
      final value = credentials.m3uUrl?.trim() ?? '';
      if (value.isEmpty || Uri.tryParse(value)?.host.isEmpty != false) {
        return 'أدخل رابط قائمة تشغيل صالحًا.';
      }
      return null;
    }
    if (credentials.baseUrl.trim().isEmpty ||
        Uri.tryParse(credentials.baseUrl)?.host.isEmpty != false) {
      return 'أدخل عنوان خادم صالحًا.';
    }
    if (credentials.username.trim().isEmpty || credentials.password.isEmpty) {
      return 'أدخل اسم المستخدم وكلمة المرور.';
    }
    return null;
  }

  void _cancelConnect() {
    if (!_busy) return;
    _connectAttempt++;
    _cancelPendingWait();
    _pendingClient?.close();
    _pendingClient = null;
    setState(() {
      _busy = false;
      _status = null;
      _error = 'تم إلغاء الاتصال. تحقق من البيانات وحاول مجددًا.';
    });
  }

  Future<void> _submitActivation() async {
    if (_busy) return;
    final username = _user.text.trim();
    final password = _pass.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'أدخل اسم المستخدم وكلمة المرور.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _status = 'جارٍ التحقق من الاشتراك والهوست...';
    });

    try {
      final resolve = widget.activationResolver ?? ActivationApi.activate;
      final credentials = await resolve(username, password).timeout(
        const Duration(seconds: 50),
      );
      if (!mounted) return;
      await _connect(credentials);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ActivationApiException
            ? e.message
            : 'تعذر التحقق من الاشتراك. تحقق من الإنترنت وحاول مرة أخرى.';
        _busy = false;
        _status = null;
      });
    }
  }

  Future<void> _startDemo() => _connect(XtreamCredentials.demoProfile);

  Future<void> _pairDevice() async {
    if (DeviceProfile.isTelevision) {
      final credentials = await Navigator.of(context).push<XtreamCredentials>(
        MaterialPageRoute(builder: (_) => const TvPairingScreen()),
      );
      if (!mounted) return;
      if (credentials != null) await _connect(credentials);
    } else {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => const PhonePairingScreen()),
      );
    }
    if (mounted) _pairingFocus.requestFocus();
  }

  @override
  void dispose() {
    _connectAttempt++;
    _cancelPendingWait();
    _pendingClient?.close();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _urlFocus.dispose();
    _userFocus.dispose();
    _passFocus.dispose();
    _submitFocus.dispose();
    _playlistFocus.dispose();
    _demoFocus.dispose();
    _pairingFocus.dispose();
    for (final node in _profileFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Add a playlist. Xtream-backed links open the full catalog; plain M3U
  /// links provide live channels.
  Future<void> _pasteUrl() async {
    final urlCtrl = TextEditingController();
    String? err;
    final creds = await showDialog<XtreamCredentials>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: surface,
          title: const Text('إضافة قائمة تشغيل M3U'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RemoteTextInput(
                child: TextField(
                  autofocus: true,
                  controller: urlCtrl,
                  readOnly: DeviceProfile.isTelevision,
                  enableInteractiveSelection: !DeviceProfile.isTelevision,
                  autocorrect: false,
                  enableSuggestions: false,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'رابط قائمة التشغيل',
                    hintText: 'https://…/playlist.m3u  or  get.php?username=…',
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'ملاحظة: روابط Xtream تعرض المكتبة كاملة، بينما روابط M3U العادية تعرض القنوات المباشرة.',
                style: TextStyle(color: subtle, fontSize: 11.5),
              ),
              if (err != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    err!,
                    style: TextStyle(color: dangerInk, fontSize: 13),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('إلغاء', style: TextStyle(color: muted)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: onAccent,
              ),
              onPressed: () {
                final raw = urlCtrl.text.trim();
                if (raw.isEmpty) {
                  setLocal(() => err = 'أدخل رابط قائمة تشغيل.');
                  return;
                }
                if (!isAllowedProviderUrl(raw)) {
                  setLocal(() => err = 'أدخل رابط HTTP أو HTTPS صالحًا.');
                  return;
                }
                // Xtream-backed link → full login.
                final x = credentialsFromUrl(raw);
                if (x != null) {
                  Navigator.pop(ctx, x);
                  return;
                }
                // Plain M3U playlist.
                Navigator.pop(
                  ctx,
                  XtreamCredentials(
                    baseUrl: raw,
                    username: Uri.tryParse(raw)?.host ?? 'playlist',
                    password: '',
                    m3uUrl: raw,
                  ),
                );
              },
              child: const Text('اتصال'),
            ),
          ],
        ),
      ),
    );
    if (creds != null) _connect(creds);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Aurora(),
          Positioned(
            top: -120,
            left: -80,
            child: _blob(accent.withValues(alpha: 0.18), 320),
          ),
          Positioned(
            bottom: -100,
            right: -60,
            child: _blob(accent2.withValues(alpha: 0.12), 280),
          ),
          Center(
            child: SingleChildScrollView(
              padding: pageInsets(context),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: _formCard(showWordmark: true),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _formCard({bool showWordmark = false}) => Glass(
    radius: 28,
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Image.asset(
            'assets/eagle_x_logo.png',
            width: 94,
            height: 94,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Icon(
              Icons.image_not_supported_outlined,
              size: 64,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'EAGLE X',
          textAlign: TextAlign.center,
          style: kDisplay().copyWith(fontSize: 32, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          'LIVE · FILMS · SERIES',
          textAlign: TextAlign.center,
          style: kSection(color: muted),
        ),
        const SizedBox(height: 7),
        Text(
          'ترفيهك، في مكان واحد',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted, fontSize: 13),
        ),
        const SizedBox(height: 24),
        Text(
          'تسجيل الدخول',
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          'أدخل بيانات حسابك للمتابعة إلى التطبيق.',
          textAlign: TextAlign.right,
          style: TextStyle(color: muted, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 18),
        _field(
          _user,
          'اسم المستخدم',
          focusNode: _userFocus,
          nextFocus: _passFocus,
          hint: 'اسم المستخدم',
        ),
        const SizedBox(height: 12),
        _field(
          _pass,
          'كلمة المرور',
          focusNode: _passFocus,
          nextFocus: _submitFocus,
          hint: 'كلمة المرور',
          obscure: !_passwordVisible,
          suffixIcon: IconButton(
            tooltip: _passwordVisible ? 'إخفاء كلمة المرور' : 'إظهار كلمة المرور',
            onPressed: () => setState(() => _passwordVisible = !_passwordVisible),
            icon: Icon(
              _passwordVisible ? Icons.visibility_off_rounded : Icons.visibility_rounded,
              color: muted,
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: dangerSurface,
              borderRadius: BorderRadius.circular(lumenCorner(12)),
              border: Border.all(color: dangerLine),
            ),
            child: Text(
              _error!,
              style: TextStyle(color: dangerInk, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
        if (_status != null && _error == null) ...[
          const SizedBox(height: 12),
          Center(
            child: Text(
              _status!,
              textAlign: TextAlign.center,
              style: TextStyle(color: muted, fontSize: 12.5),
            ),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: RemoteTap(
            key: const ValueKey('login-submit'),
            focusNode: _submitFocus,
            autofocus: !DeviceProfile.isTelevision,
            semanticLabel: 'تسجيل الدخول',
            focusRadius: 14,
            focusRingColor: Colors.white,
            onTap: _submitActivation,
            child: AnimatedContainer(
              key: const ValueKey('login-submit-surface'),
              duration: lumenMotionFast,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(lumenCorner(14)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_busy ? Icons.sync_rounded : Icons.login_rounded, size: 19, color: onAccent),
                  const SizedBox(width: 8),
                  Text(
                    _busy ? 'جارٍ التحقق...' : 'تسجيل الدخول',
                    style: TextStyle(color: onAccent, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        Divider(color: line),
        const SizedBox(height: 16),
        Text(
          'لتفعيل التطبيق أو الحصول على اشتراك IPTV،',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted, fontSize: 13, height: 1.5),
        ),
        Text(
          'تواصل مع الدعم عبر مسح رمز QR.',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 16),
        Center(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Image.asset(
              'assets/eagle_x_qr.png',
              width: 220,
              height: 220,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.qr_code_2_rounded,
                size: 220,
                color: Colors.black,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'امسح الرمز للتواصل مع الدعم',
          textAlign: TextAlign.center,
          style: TextStyle(color: muted, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _field(
    TextEditingController c,
    String label, {
    required FocusNode focusNode,
    required FocusNode nextFocus,
    String? hint,
    bool obscure = false,
    bool autofocus = false,
    Widget? suffixIcon,
  }) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: RemoteTextInput(
        child: TextField(
          controller: c,
          focusNode: focusNode,
          autofocus: autofocus,
          obscureText: obscure,
          readOnly: DeviceProfile.isTelevision,
          enableInteractiveSelection: !DeviceProfile.isTelevision,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          textDirection: TextDirection.rtl,
          textAlign: TextAlign.right,
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) => nextFocus.requestFocus(),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            suffixIcon: suffixIcon,
          ),
        ),
      ),
    );
  }

  Widget _blob(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
    ),
  );
}

class _ProfileTile extends StatelessWidget {
  final XtreamCredentials profile;
  final bool busy;
  final FocusNode? focusNode;
  final VoidCallback onTap;
  const _ProfileTile({
    required this.profile,
    required this.busy,
    required this.focusNode,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return RemoteTap(
      onTap: busy ? null : onTap,
      focusNode: focusNode,
      focusRadius: 15,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: surfaceHi.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(lumenCorner(15)),
          border: Border.all(color: line),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accentInk.withValues(alpha: isDark ? 0.13 : 0.09),
                borderRadius: BorderRadius.circular(lumenCorner(12)),
              ),
              child: Icon(Icons.tv_rounded, color: accentInk, size: 19),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.isDemo ? 'الوضع التجريبي' : profile.username,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    profile.isDemo
                        ? 'Offline sample library'
                        : profile.baseUrl.replaceFirst(
                            RegExp(r'^https?://'),
                            '',
                          ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: subtle, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_rounded, size: 17, color: accentInk),
          ],
        ),
      ),
    );
  }
}

class _TrustPill extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TrustPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: surfaceHi.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(lumenCorner(13)),
      border: Border.all(color: line),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: accentInk, size: 16),
        const SizedBox(width: 7),
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
        ),
      ],
    ),
  );
}
