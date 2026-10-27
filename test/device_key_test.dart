import 'dart:convert';

import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeSigner implements AtlasDeviceKeySigner {
  final signed = <String>[];
  @override
  Future<AtlasDeviceKeyJwk> createKey({required bool biometric}) async => const AtlasDeviceKeyJwk(x: 'xx', y: 'yy');
  @override
  Future<String> sign(String message) async {
    signed.add(message);
    return 'sig';
  }
}

void main() {
  test('message mirrors the server format', () {
    expect(
      atlasDeviceKeyMessage(purpose: 'sign_in', instanceId: 'ins_1', keyId: 'dvk_1', nonce: 'n'),
      'atlas-device-key:v1:sign_in:ins_1:dvk_1:n',
    );
  });

  test('jwk JSON and resource parsing', () {
    expect(const AtlasDeviceKeyJwk(x: 'a', y: 'b').toJson(), {'kty': 'EC', 'crv': 'P-256', 'x': 'a', 'y': 'b'});
    final k = AtlasDeviceKey.fromJson({'id': 'dvk_1', 'label': 'Pixel', 'biometric_bound': true, 'created_at': 5});
    expect(k.id, 'dvk_1');
    expect(k.biometricBound, isTrue);
  });

  test('signs the register message with the key x coordinate', () async {
    final signer = _FakeSigner();
    final posts = <String>[];
    final mock = MockClient((http.Request r) async {
      posts.add('${r.method} ${r.url.path}');
      if (r.url.path.endsWith('/challenge')) return http.Response(jsonEncode({'nonce': 'n1'}), 201);
      return http.Response(jsonEncode({'object': 'device_key', 'id': 'dvk_1', 'biometric_bound': true, 'created_at': 1}), 201);
    });
    final client = AtlasClient(
      publishableKey: 'pk_test_x',
      frontendApi: 'fapi.test',
      tokenStore: InMemoryTokenStore(const AtlasSession(sessionId: 's', token: 't', refreshToken: 'r')),
      httpClient: mock,
    );
    final key = await client.registerDeviceKey(instanceId: 'ins_1', signer: signer, label: 'Pixel');
    expect(key.id, 'dvk_1');
    expect(signer.signed.single, 'atlas-device-key:v1:register:ins_1:xx:n1');
    expect(posts, ['POST /v1/client/me/device_keys/challenge', 'POST /v1/client/me/device_keys']);
  });
}
