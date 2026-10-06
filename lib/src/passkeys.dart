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
