import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen_tv/device_trial_api.dart';

void main() {
  const deviceId = 'EX-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

  test('device trial check accepts an active trial from the server', () async {
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.host, 'rsiwnaelmahoofsxosjq.supabase.co');
      expect(request.url.path, '/functions/v1/device-trial');
      expect(request.headers['apikey'], isNotEmpty);
      expect(jsonDecode(request.body), {'device_id': deviceId});
      return http.Response(
        jsonEncode({
          'allowed': true,
          'status': 'trial',
          'device_id': deviceId,
          'first_seen_at': '2026-10-16T00:00:00Z',
          'trial_expires_at': '2026-11-15T00:00:00Z',
        }),
        200,
      );
    });

    final result = await DeviceTrialApi.check(deviceId: deviceId, client: client);
    expect(result.allowed, isTrue);
    expect(result.status, 'trial');
    expect(result.deviceId, deviceId);
    expect(result.trialExpiresAt, isNotNull);
    client.close();
  });

  test('device trial check reports expired devices as denied', () async {
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'allowed': false,
          'status': 'subscription_required',
          'device_id': deviceId,
          'trial_expires_at': '2026-10-01T00:00:00Z',
        }),
        200,
      ),
    );

    final result = await DeviceTrialApi.check(deviceId: deviceId, client: client);
    expect(result.allowed, isFalse);
    expect(result.status, 'subscription_required');
    client.close();
  });

  test('device trial check rejects malformed IDs before making a request', () async {
    final client = MockClient((_) async {
      fail('The request must not be sent for an invalid ID.');
    });

    await expectLater(
      DeviceTrialApi.check(deviceId: 'not-a-device-id', client: client),
      throwsA(isA<DeviceTrialException>()),
    );
    client.close();
  });
}
