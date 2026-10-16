import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen_tv/activation_api.dart';

void main() {
  test('activation returns credentials from the configured host', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/functions/v1/device-activation');
      expect(request.headers['apikey'], isNotEmpty);
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload['username'], 'viewer');
      expect(payload['password'], 'secret');
      return http.Response(
        jsonEncode({
          'activated': true,
          'status': 'active',
          'config': {
            'video': {
              'server_url': 'https://host.example:8080',
              'username': 'viewer',
              'password': 'secret',
            },
          },
        }),
        200,
      );
    });

    final credentials = await ActivationApi.activate(
      ' viewer ',
      'secret',
      client: client,
    );

    expect(credentials.baseUrl, 'https://host.example:8080');
    expect(credentials.username, 'viewer');
    expect(credentials.password, 'secret');
    client.close();
  });

  test('activation reports invalid subscription credentials', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'activated': false,
          'status': 'invalid_credentials',
          'config': null,
        }),
        401,
      ),
    );

    expect(
      () => ActivationApi.activate('viewer', 'wrong', client: client),
      throwsA(
        isA<ActivationApiException>().having(
          (error) => error.message,
          'message',
          'بيانات الاشتراك غير صحيحة أو غير مفعّلة على الهوستات.',
        ),
      ),
    );
    client.close();
  });
}
