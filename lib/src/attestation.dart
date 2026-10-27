import 'dart:convert';

/// The OS proof for one single-use nonce (see `AtlasClient.attestationProvider`).
class AtlasAttestationProof {
  /// Apple App Attest: the base64 assertion plus the registration receipt.
  const AtlasAttestationProof.appAttest({required String assertion, required String receipt})
      : _assertion = assertion,
        _receipt = receipt,
        _integrityToken = null,
        _deviceToken = null;

  /// A Google Play Integrity token whose request nonce is the server nonce.
  const AtlasAttestationProof.playIntegrity(String token)
      : _assertion = null,
        _receipt = null,
        _integrityToken = token,
        _deviceToken = null;

  /// An Apple DeviceCheck token (base64), for devices without App Attest.
  const AtlasAttestationProof.deviceCheck(String token)
      : _assertion = null,
        _receipt = null,
        _integrityToken = null,
        _deviceToken = token;

  final String? _deviceToken;
  final String? _assertion;
  final String? _receipt;
  final String? _integrityToken;

  /// The `Atlas-Attestation` header value: base64url JSON the server reads.
  String toHeader(String nonce) {
    final body = <String, String>{'n': nonce};
    if (_deviceToken != null) {
      body['p'] = 'ios_dc';
      body['t'] = _deviceToken;
    } else if (_integrityToken != null) {
      body['p'] = 'android';
      body['t'] = _integrityToken;
    } else {
      body['p'] = 'ios';
      body['a'] = _assertion ?? '';
      body['r'] = _receipt ?? '';
    }
    return base64Url.encode(utf8.encode(jsonEncode(body))).replaceAll('=', '');
  }
}

/// True for the calls an instance may require attestation on: sign-up, sign-in
/// and SMS-send posts.
bool isAttestationGuarded(String method, String path) {
  if (method != 'POST') return false;
  final bare = path.split('?').first;
  return bare == '/v1/client/sign_ups' ||
      bare == '/v1/client/sign_ins' ||
      bare == '/v1/client/me/phone_numbers' ||
      (bare.startsWith('/v1/client/me/phone_numbers/') && bare.endsWith('/prepare_verification'));
}
