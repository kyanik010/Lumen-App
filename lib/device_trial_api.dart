import 'dart:convert';
import 'dart:io' show Platform;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class DeviceTrialException implements Exception {
  const DeviceTrialException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DeviceTrialStatus {
  const DeviceTrialStatus({
    required this.allowed,
    required this.status,
    required this.deviceId,
    this.firstSeenAt,
    this.trialExpiresAt,
    this.subscriptionExpiresAt,
  });
  final bool allowed;
  final String status;
  final String deviceId;
  final DateTime? firstSeenAt;
  final DateTime? trialExpiresAt;
  final DateTime? subscriptionExpiresAt;

  factory DeviceTrialStatus.fromJson(Map<String, dynamic> json, {required String fallbackDeviceId}) {
    DateTime? parseDate(dynamic value) => value is String ? DateTime.tryParse(value)?.toLocal() : null;
    return DeviceTrialStatus(
      allowed: json['allowed'] == true,
      status: json['status']?.toString() ?? 'verification_failed',
      deviceId: json['device_id']?.toString() ?? fallbackDeviceId,
      firstSeenAt: parseDate(json['first_seen_at']),
      trialExpiresAt: parseDate(json['trial_expires_at']),
      subscriptionExpiresAt: parseDate(json['subscription_expires_at']),
    );
  }
}

class DeviceTrialApi {
  DeviceTrialApi._();
  static const _channel = MethodChannel('lumen/device');
  static const _endpoint = 'https://rsiwnaelmahoofsxosjq.supabase.co/functions/v1/device-trial';
  static const _publishableKey = 'sb_publishable_ZgWToIcN18gJlOdwJme8QQ_H_moIvga';
  static const _fallbackPreferenceKey = 'eagle_x_device_trial_fallback_v1';

  /// Android ID is stable across normal reinstalls for the same app signing key/user.
  /// The random fallback is installation-scoped and cannot guarantee reinstall stability.
  static Future<String> deviceId() async {
    String? rawId;
    if (!kIsWeb && Platform.isAndroid) {
      try {
        rawId = await _channel.invokeMethod<String>('readAndroidId');
      } on PlatformException {
        rawId = null;
      } on MissingPluginException {
        rawId = null;
      }
    }
    if (rawId == null || rawId.trim().isEmpty) {
      final preferences = await SharedPreferences.getInstance();
      rawId = preferences.getString(_fallbackPreferenceKey);
      if (rawId == null || rawId.isEmpty) {
        rawId = 'fallback:${Uuid().v4()}';
        await preferences.setString(_fallbackPreferenceKey, rawId);
      }
    }
    final digest = sha256.convert(utf8.encode('eagle-x-device-v1:${rawId.trim()}')).toString().toUpperCase();
    return 'EX-$digest';
  }

  static Future<DeviceTrialStatus> check({String? deviceId, http.Client? client}) async {
    final id = deviceId ?? await DeviceTrialApi.deviceId();
    if (!RegExp(r'^EX-[A-F0-9]{64}$').hasMatch(id)) {
      throw const DeviceTrialException('معرّف الجهاز غير صالح.');
    }
    final ownedClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient.post(
        Uri.parse(_endpoint),
        headers: {'Content-Type': 'application/json', 'apikey': _publishableKey},
        body: jsonEncode({'device_id': id}),
      ).timeout(const Duration(seconds: 20));
      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(response.body);
        body = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
      } catch (_) {
        body = <String, dynamic>{};
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = body['error']?.toString() ?? '';
        if (code == 'invalid_device_id') {
          throw const DeviceTrialException('تعذر التحقق من معرّف الجهاز.');
        }
        throw const DeviceTrialException('تعذر الاتصال بخادم التفعيل. تحقق من الإنترنت ثم أعد المحاولة.');
      }
      if (body['allowed'] is! bool) {
        throw const DeviceTrialException('وصل رد غير صالح من خادم التفعيل. أعد المحاولة.');
      }
      return DeviceTrialStatus.fromJson(body, fallbackDeviceId: id);
    } on DeviceTrialException {
      rethrow;
    } catch (_) {
      throw const DeviceTrialException('تعذر التحقق من الجهاز. تحقق من اتصال الإنترنت ثم أعد المحاولة.');
    } finally {
      if (ownedClient) httpClient.close();
    }
  }
}
