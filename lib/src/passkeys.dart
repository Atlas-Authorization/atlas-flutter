/// Native passkey (WebAuthn) support — the platform ceremony seam and the pure
/// mapping between the server's `begin`/`finish` contract and the device.
///
/// Passkeys on native are a two-call dance that mirrors the web (the Dart peer
/// of `@atlasauth/js`'s `createPasskey` / `getPasskeyAssertion` and of
/// `@atlasauth/expo-passkeys`): the server's `begin` response describes the
/// ceremony, the platform authenticator performs it, and the result is POSTed to
/// `finish`. The browser runs the ceremony with `navigator.credentials`; on
/// native there is no `navigator`, so the SDK delegates the ceremony to the
/// [`passkeys`](https://pub.dev/packages/passkeys) plugin (iOS
/// ASAuthorization / Android Credential Manager under one Dart API) and owns
/// only the two HTTP calls and the body mapping between them.
///
///   register: `POST /v1/client/me/passkeys/begin`      → create → `…/finish`
///   sign in : `POST /v1/client/sign_ins/passkey/begin`  → get    → `…/finish`
///
/// The `rpId` and `challenge` the ceremony needs are read FROM the `begin`
/// response — never hardcoded — exactly as the plugin's
/// `RegisterRequestType.fromJson` / `AuthenticateRequestType.fromJson` parse
/// them out of the WebAuthn options.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:passkeys/authenticator.dart';
import 'package:passkeys/types.dart';

export 'package:passkeys/authenticator.dart' show PasskeyAuthenticator;
export 'package:passkeys/types.dart'
    show
        RegisterRequestType,
        RegisterResponseType,
        AuthenticateRequestType,
        AuthenticateResponseType,
        AuthenticatorException,
        PasskeyAuthCancelledException,
        NoCredentialsAvailableException,
        DomainNotAssociatedException;

/// The slice of the platform authenticator the SDK drives: the two WebAuthn
/// ceremonies. The `passkeys` plugin's `PasskeyAuthenticator` satisfies this
/// (via [CorbadoPasskeyAuthenticator]); a test injects a fake. Depending on
/// this seam instead of the plugin directly keeps the mapping unit-testable
/// without a device.
abstract interface class AtlasPasskeyAuthenticator {
  /// Create a passkey on the device for [request] (the parsed `begin` options)
  /// and return the attestation the `finish` route verifies.
  Future<RegisterResponseType> register(RegisterRequestType request);

  /// Assert an existing passkey for [request] (the parsed `begin` options) and
  /// return the assertion the `finish` route verifies.
  Future<AuthenticateResponseType> authenticate(AuthenticateRequestType request);
}

/// The default [AtlasPasskeyAuthenticator], backed by the `passkeys` plugin's
/// `PasskeyAuthenticator`. Constructed lazily on first passkey call so a
/// password-only app never touches the native authenticator.
class CorbadoPasskeyAuthenticator implements AtlasPasskeyAuthenticator {
  CorbadoPasskeyAuthenticator([PasskeyAuthenticator? authenticator])
      : _authenticator = authenticator ?? PasskeyAuthenticator();

  final PasskeyAuthenticator _authenticator;

  @override
  Future<RegisterResponseType> register(RegisterRequestType request) =>
      _authenticator.register(request);

  @override
  Future<AuthenticateResponseType> authenticate(
          AuthenticateRequestType request) =>
      _authenticator.authenticate(request);
}

/// Map a registration `begin` response + a create result to the `finish` body.
///
/// Field names are the server's: `challenge`, `attestation_object`,
/// `client_data_json`, and an optional human [name] for the credential. The
/// challenge is echoed verbatim from [begin] — the server matched and stored it
/// — never re-derived from the device result. All values are base64url strings
/// as the plugin returns them.
Map<String, String> passkeyRegistrationFinishBody(
  Map<String, dynamic> begin,
  RegisterResponseType credential, {
  String? name,
}) {
  final challenge = begin['challenge'];
  return <String, String>{
    'challenge': challenge is String ? challenge : '',
    'attestation_object': credential.attestationObject,
    'client_data_json': credential.clientDataJSON,
    if (name != null && name.isNotEmpty) 'name': name,
  };
}

/// The passkey sign-in `begin` body: the captcha token when there is one.
Map<String, String> passkeySignInBeginBody(String? captchaToken) =>
    captchaToken == null || captchaToken.isEmpty ? const <String, String>{} : {'captcha_token': captchaToken};

/// Map an assertion `begin` response + a get result to the `finish` body.
///
/// Field names are the server's: `handle`, `challenge`, `credential_id`,
/// `authenticator_data`, `client_data_json`, `signature`. [begin]'s `handle`
/// and `challenge` are echoed verbatim; the rest come off the device result.
/// The credential id prefers `rawId`, falling back to `id`. All values are
/// base64url strings as the plugin returns them.
Map<String, String> passkeyAssertionFinishBody(
  Map<String, dynamic> begin,
  AuthenticateResponseType assertion,
) {
  final handle = begin['handle'];
  final challenge = begin['challenge'];
  final credentialId =
      assertion.rawId.isNotEmpty ? assertion.rawId : assertion.id;
  return <String, String>{
    'handle': handle is String ? handle : '',
    'challenge': challenge is String ? challenge : '',
    'credential_id': credentialId,
    'authenticator_data': assertion.authenticatorData,
    'client_data_json': assertion.clientDataJSON,
    'signature': assertion.signature,
  };
}


/// Ask the authenticator for a PRF output (the WebAuthn `prf` extension) during
/// a passkey ceremony — e.g. to derive a client-side encryption key only this
/// passkey can unlock. The salt and the output stay on the device: the output
/// reaches only your `onPrfResult` callback and nothing PRF-related is sent to
/// Atlas. The `passkeys` plugin evaluates one salt ([first]); authenticators
/// without PRF support return no output.
class AtlasPasskeyPrf {
  const AtlasPasskeyPrf(this.first);

  /// A salt given as a string is encoded as UTF-8 (the same rule as the web SDK).
  factory AtlasPasskeyPrf.fromSalt(String salt) => AtlasPasskeyPrf(Uint8List.fromList(utf8.encode(salt)));

  /// The salt (bytes).
  final Uint8List first;
}

/// The PRF output of a ceremony: [enabled] is reported on registration (whether
/// the new passkey supports PRF); [first] is the 32-byte output for the salt,
/// when the authenticator evaluated it.
class AtlasPasskeyPrfResult {
  const AtlasPasskeyPrfResult({required this.credentialId, this.enabled, this.first, this.second});

  final String credentialId;
  final bool? enabled;
  final Uint8List? first;
  final Uint8List? second;
}

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List? _b64urlDecode(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    return base64Url.decode(base64Url.normalize(value));
  } on FormatException {
    return null;
  }
}

/// [begin] with the `prf` extension (`eval.first`) added, so the plugin's
/// request types pick the salt up. Returns [begin] unchanged when [prf] is null.
Map<String, dynamic> withPasskeyPrf(Map<String, dynamic> begin, AtlasPasskeyPrf? prf) {
  if (prf == null) return begin;
  final existing = begin['extensions'];
  return <String, dynamic>{
    ...begin,
    'extensions': <String, dynamic>{
      if (existing is Map) ...existing.cast<String, dynamic>(),
      'prf': <String, dynamic>{
        'eval': <String, dynamic>{'first': _b64url(prf.first)},
      },
    },
  };
}

/// Read the `prf` client-extension results the platform returned; null when
/// there are none.
AtlasPasskeyPrfResult? readPasskeyPrfResult(String credentialId, Map<String?, Object?>? clientExtensionResults) {
  final prf = clientExtensionResults?['prf'];
  if (prf is! Map) return null;
  final results = prf['results'];
  final enabled = prf['enabled'];
  return AtlasPasskeyPrfResult(
    credentialId: credentialId,
    enabled: enabled is bool ? enabled : (results is Map ? true : null),
    first: results is Map ? _b64urlDecode(results['first']) : null,
    second: results is Map ? _b64urlDecode(results['second']) : null,
  );
}
