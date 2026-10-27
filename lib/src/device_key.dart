import 'package:flutter/services.dart';

/// Device-bound biometric sign-in (the Dart peer of the JS `registerDeviceKey` /
/// `signInWithDeviceKey`). An ES256 (P-256) key lives in the Secure Enclave
/// (iOS) or Android Keystore and is unlocked by Face ID / fingerprint; Atlas
/// stores only the public half. See `AtlasClient.registerDeviceKey` and
/// `AtlasClient.signInWithDeviceKey`.

/// A P-256 public key as a JWK (`x`, `y` base64url).
class AtlasDeviceKeyJwk {
  const AtlasDeviceKeyJwk({required this.x, required this.y});
  final String x;
  final String y;
  Map<String, String> toJson() => {'kty': 'EC', 'crv': 'P-256', 'x': x, 'y': y};
}

/// The keystore contract. [MethodChannelDeviceKeySigner] is the built-in
/// implementation; pass your own (or a fake in tests) to the client.
abstract class AtlasDeviceKeySigner {
  /// Creates the keypair; [biometric] asks for a key that needs Face ID /
  /// fingerprint to use.
  Future<AtlasDeviceKeyJwk> createKey({required bool biometric});

  /// Signs the UTF-8 [message] with ES256 and returns base64url IEEE-P1363
  /// (`r || s`), after the biometric prompt for a biometric key.
  Future<String> sign(String message);
}

/// The signer backed by this package's native plugin (Secure Enclave on iOS,
/// Android Keystore + BiometricPrompt on Android).
class MethodChannelDeviceKeySigner implements AtlasDeviceKeySigner {
  MethodChannelDeviceKeySigner({MethodChannel? channel, this.promptTitle = 'Sign in'})
      : _channel = channel ?? const MethodChannel('net.atlasauth.atlas/device_key');

  final MethodChannel _channel;

  /// The reason shown in the biometric sheet.
  final String promptTitle;

  @override
  Future<AtlasDeviceKeyJwk> createKey({required bool biometric}) async {
    final r = await _channel.invokeMapMethod<String, String>('createKey', {'biometric': biometric});
    if (r == null || r['x'] == null || r['y'] == null) {
      throw PlatformException(code: 'no_key', message: 'The device did not return a public key.');
    }
    return AtlasDeviceKeyJwk(x: r['x']!, y: r['y']!);
  }

  @override
  Future<String> sign(String message) async {
    final s = await _channel.invokeMethod<String>('sign', {'message': message, 'title': promptTitle});
    if (s == null) throw PlatformException(code: 'no_signature', message: 'The device did not sign.');
    return s;
  }
}

/// The `device_key` resource the server returns (public metadata only).
class AtlasDeviceKey {
  const AtlasDeviceKey({
    required this.id,
    this.label,
    this.platform,
    this.biometricBound = false,
    this.lastUsedAt,
    this.createdAt = 0,
  });

  factory AtlasDeviceKey.fromJson(Map<String, dynamic> j) => AtlasDeviceKey(
        id: j['id'] as String,
        label: j['label'] as String?,
        platform: j['platform'] as String?,
        biometricBound: j['biometric_bound'] as bool? ?? false,
        lastUsedAt: (j['last_used_at'] as num?)?.toInt(),
        createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String? label;
  final String? platform;
  final bool biometricBound;
  final int? lastUsedAt;
  final int createdAt;
}

/// The exact string the device signs; mirrors the server.
String atlasDeviceKeyMessage({
  required String purpose,
  required String instanceId,
  required String keyId,
  required String nonce,
}) =>
    'atlas-device-key:v1:$purpose:$instanceId:$keyId:$nonce';
