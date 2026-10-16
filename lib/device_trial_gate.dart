import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'device_trial_api.dart';

class DeviceTrialGate extends StatefulWidget {
  const DeviceTrialGate({super.key, required this.child});
  final Widget child;
  @override
  State<DeviceTrialGate> createState() => _DeviceTrialGateState();
}

class _DeviceTrialGateState extends State<DeviceTrialGate> {
  DeviceTrialStatus? _status;
  String? _deviceId;
  String? _error;
  bool _checking = true;
  late final bool _enforce = !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    if (_enforce) {
      unawaited(_check());
    } else {
      _checking = false;
    }
  }

  Future<void> _check() async {
    if (mounted) {
      setState(() {
        _checking = true;
        _error = null;
      });
    }
    try {
      final id = await DeviceTrialApi.deviceId();
      if (mounted) setState(() => _deviceId = id);
      final status = await DeviceTrialApi.check(deviceId: id);
      if (!mounted) return;
      setState(() {
        _status = status;
        _checking = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = error is DeviceTrialException
            ? error.message
            : 'تعذر التحقق من حالة الجهاز. أعد المحاولة.';
      });
    }
  }

  String _formatDate(DateTime? value) {
    if (value == null) return 'غير متاح';
    final date = value.toLocal();
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$day/$month/${date.year}  $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    if (!_enforce || (!_checking && _error == null && _status?.allowed == true)) {
      return widget.child;
    }

    final colors = Theme.of(context).colorScheme;
    final blocked = _status?.status == 'blocked';
    final expired = _status?.status == 'subscription_required';
    final title = _checking
        ? 'جارٍ التحقق من الجهاز'
        : blocked
            ? 'هذا الجهاز موقوف'
            : expired
                ? 'انتهت الفترة التجريبية'
                : 'تعذر التحقق من التفعيل';
    final message = _checking
        ? 'نتحقق من هوية الجهاز وحالة التجربة والاشتراك لدى الخادم.'
        : blocked
            ? 'هذا الجهاز غير مسموح له باستخدام Eagle X. تواصل مع المسؤول.'
            : expired
                ? 'انتهت مدة التجربة المجانية. يلزم تفعيل اشتراك لهذا الجهاز للمتابعة.'
                : _error ?? 'تعذر التحقق من حالة الجهاز. أعد المحاولة.';

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        _checking
                            ? Icons.verified_user_outlined
                            : blocked
                                ? Icons.block
                                : expired
                                    ? Icons.lock_clock_outlined
                                    : Icons.cloud_off_outlined,
                        size: 56,
                        color: blocked ? colors.error : colors.primary,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'EAGLE X',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Text(message, textAlign: TextAlign.center),
                      if (_status?.trialExpiresAt != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          'انتهاء التجربة: ${_formatDate(_status!.trialExpiresAt)}',
                          textAlign: TextAlign.center,
                        ),
                      ],
                      if (_deviceId != null) ...[
                        const SizedBox(height: 20),
                        Text('معرّف الجهاز', style: Theme.of(context).textTheme.labelLarge),
                        const SizedBox(height: 6),
                        SelectableText(
                          _deviceId!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 12, letterSpacing: .5),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: _deviceId!));
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('تم نسخ معرّف الجهاز')),
                            );
                          },
                          icon: const Icon(Icons.copy),
                          label: const Text('نسخ معرّف الجهاز'),
                        ),
                      ],
                      if (blocked || expired) ...[
                        const SizedBox(height: 18),
                        Text(
                          'امسح الرمز للتواصل مع الدعم',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 10),
                        Center(
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xFFC8A45A),
                                width: 1.5,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.asset(
                                'assets/eagle_x_qr.png',
                                width: 112,
                                height: 112,
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.high,
                                errorBuilder: (_, __, ___) => const Icon(
                                  Icons.qr_code_2_rounded,
                                  size: 112,
                                  color: Colors.black,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (_checking) ...[
                        const SizedBox(height: 20),
                        const Center(child: CircularProgressIndicator()),
                      ] else ...[
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: _check,
                          icon: const Icon(Icons.refresh),
                          label: Text(expired || blocked ? 'إعادة التحقق من الاشتراك' : 'إعادة المحاولة'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
