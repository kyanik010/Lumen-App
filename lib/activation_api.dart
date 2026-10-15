import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class ActivationApiException implements Exception {
  final String message;
  const ActivationApiException(this.message);

  @override
  String toString() => message;
}

/// Connects the Eagle X login form to the host registry used by the
/// existing AerioTV Control host dashboard.
class ActivationApi {
  ActivationApi._();

  static const _endpoint =
      'https://quaftlmuobshbnlhctmf.supabase.co/functions/v1/device-activation';
  // This is the dashboard's public/publishable Supabase key, not a service key.
  static const _publishableKey =
      'sb_publishable_6mdnO-ezptIZzRKNfEbzaA_e9B-ulL5';

  static Future<XtreamCredentials> activate(
    String username,
    String password, {
    http.Client? client,
  }) async {
    final cleanUsername = username.trim();
    if (cleanUsername.isEmpty || password.isEmpty) {
      throw const ActivationApiException('أدخل اسم المستخدم وكلمة المرور.');
    }

    final ownedClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Content-Type': 'application/json',
              'apikey': _publishableKey,
            },
            body: jsonEncode({
              'username': cleanUsername,
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 45));

      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(response.body);
        body = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } catch (_) {
        body = <String, dynamic>{};
      }

      final status = body['status']?.toString() ?? '';
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          body['activated'] != true) {
        throw ActivationApiException(_messageFor(status));
      }

      final config = body['config'];
      final video = config is Map ? config['video'] : null;
      final serverUrl = video is Map
          ? video['server_url']?.toString().trim() ?? ''
          : '';
      final configuredUsername = video is Map
          ? video['username']?.toString() ?? cleanUsername
          : cleanUsername;
      final configuredPassword =
          video is Map ? video['password']?.toString() ?? password : password;
      final uri = Uri.tryParse(serverUrl);

      if (serverUrl.isEmpty ||
          uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        throw const ActivationApiException(
          'تم التحقق من الاشتراك لكن إعدادات الهوست غير مكتملة. تواصل مع الدعم.',
        );
      }

      return XtreamCredentials(
        baseUrl: serverUrl,
        username: configuredUsername,
        password: configuredPassword,
      );
    } on TimeoutException {
      throw const ActivationApiException(
        'استغرق التحقق وقتًا طويلًا. تحقق من الإنترنت وحاول مرة أخرى.',
      );
    } on ActivationApiException {
      rethrow;
    } catch (_) {
      throw const ActivationApiException(
        'تعذر الاتصال بلوحة الهوستات. تحقق من الإنترنت وحاول مرة أخرى.',
      );
    } finally {
      if (ownedClient) httpClient.close();
    }
  }

  static String _messageFor(String status) {
    switch (status) {
      case 'credentials_required':
        return 'أدخل اسم المستخدم وكلمة المرور.';
      case 'invalid_credentials':
        return 'بيانات الاشتراك غير صحيحة أو غير مفعّلة على الهوستات.';
      case 'expired':
        return 'انتهت صلاحية الاشتراك. تواصل مع الدعم للتجديد.';
      case 'no_enabled_hosts':
        return 'لا توجد هوستات مفعّلة حاليًا. تواصل مع الدعم.';
      case 'host_unreachable':
        return 'تعذر الوصول إلى الهوستات حاليًا. حاول مرة أخرى لاحقًا.';
      default:
        return 'تعذر التحقق من الاشتراك. تحقق من البيانات أو تواصل مع الدعم.';
    }
  }
}
