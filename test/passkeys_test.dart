import 'dart:convert';

import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// FIFO queue of canned responses + a record of every request — the same seam
/// the password-flow tests use, so the passkey flow is asserted end to end
/// against `package:http/testing.dart`'s [MockClient].
class MockTransport {
  final List<http.Request> recorded = [];
  final List<_Stub> _stubs = [];

  void enqueue(int status, String json,
      {Map<String, String> headers = const {}}) {
    final merged = <String, String>{
      'content-type': 'application/json',
      ...headers,
    };
    _stubs.add(_Stub(status, json, merged));
  }

  http.Client client() => MockClient((request) async {
        recorded.add(request);
        if (_stubs.isEmpty) {
          throw http.ClientException('no stubbed response', request.url);
        }
        final stub = _stubs.removeAt(0);
        return http.Response(stub.body, stub.status,
            headers: stub.headers, request: request);
      });

  Map<String, dynamic> bodyAt(int index) =>
      jsonDecode(recorded[index].body) as Map<String, dynamic>;
}

class _Stub {
  _Stub(this.status, this.body, this.headers);
  final int status;
  final String body;
  final Map<String, String> headers;
}

/// A scripted [AtlasPasskeyAuthenticator] — no device, no plugin. It echoes the
/// `begin` options it was handed (so a test can assert `rpId`/`challenge` were
/// read from the server), and returns canned ceremony results.
class FakePasskeyAuthenticator implements AtlasPasskeyAuthenticator {
  RegisterRequestType? lastRegister;
  AuthenticateRequestType? lastAuthenticate;

  final RegisterResponseType registerResult;
  final AuthenticateResponseType authenticateResult;

  FakePasskeyAuthenticator({
    RegisterResponseType? registerResult,
    AuthenticateResponseType? authenticateResult,
  })  : registerResult = registerResult ??
            const RegisterResponseType(
              id: 'cred_X',
              rawId: 'cred_X',
              clientDataJSON: 'CDJ',
              attestationObject: 'ATT',
              transports: [],
            ),
        authenticateResult = authenticateResult ??
            const AuthenticateResponseType(
              id: 'cred_Y',
              rawId: 'raw_Y',
              clientDataJSON: 'CDJ',
              authenticatorData: 'AD',
              signature: 'SIG',
              userHandle: '',
            );

  @override
  Future<RegisterResponseType> register(RegisterRequestType request) async {
    lastRegister = request;
    return registerResult;
  }

  @override
  Future<AuthenticateResponseType> authenticate(
      AuthenticateRequestType request) async {
    lastAuthenticate = request;
    return authenticateResult;
  }
}

const pk = 'pk_test_123';
const frontendApi = 'fapi.acme.atlasauth.net';

/// A flat WebAuthn creation-options object as `begin` returns it: `challenge`,
/// `rp` (the instance Frontend API host), and `user` at the top level.
const registerBeginJson = '''
{
  "challenge": "chal_R",
  "rp": { "id": "fapi.acme.atlasauth.net", "name": "Acme" },
  "user": { "id": "dXNlcl8x", "name": "ada@example.com", "displayName": "Ada" },
  "pubKeyCredParams": [ { "type": "public-key", "alg": -7 } ]
}
''';

/// A flat WebAuthn request-options object as `begin` returns it: `rpId`,
/// `challenge`, plus the Atlas assertion `handle`.
const signInBeginJson = '''
{
  "challenge": "chal_A",
  "rpId": "fapi.acme.atlasauth.net",
  "handle": "h_A",
  "allowCredentials": []
}
''';

const userJson = '{"object":"user","id":"user_1","first_name":"Ada"}';

void main() {
  late MockTransport transport;
  late FakePasskeyAuthenticator passkey;

  setUp(() {
    transport = MockTransport();
    passkey = FakePasskeyAuthenticator();
  });

  AtlasClient makeClient({TokenStore? store}) => AtlasClient(
        publishableKey: pk,
        frontendApi: frontendApi,
        tokenStore: store ?? InMemoryTokenStore(),
        httpClient: transport.client(),
        passkeyAuthenticator: passkey,
      );

  // MARK: pure body mapping

  test('maps a create result to the registration finish body', () {
    final body = passkeyRegistrationFinishBody(
      {'challenge': 'chal_1'},
      const RegisterResponseType(
        id: 'cred_1',
        rawId: 'cred_1',
        clientDataJSON: 'cdj',
        attestationObject: 'att',
        transports: [],
      ),
      name: 'My iPhone',
    );
    expect(body, {
      'challenge': 'chal_1',
      'attestation_object': 'att',
      'client_data_json': 'cdj',
      'name': 'My iPhone',
    });
  });

  test('registration body omits an absent/empty name', () {
    final body = passkeyRegistrationFinishBody(
      {'challenge': 'chal_1'},
      const RegisterResponseType(
        id: 'c',
        rawId: 'c',
        clientDataJSON: 'cdj',
        attestationObject: 'att',
        transports: [],
      ),
    );
    expect(body.containsKey('name'), isFalse);
  });

  test('maps a get result to the assertion finish body (rawId preferred)', () {
    final body = passkeyAssertionFinishBody(
      {'challenge': 'chal_2', 'handle': 'h_2'},
      const AuthenticateResponseType(
        id: 'id_2',
        rawId: 'raw_2',
        clientDataJSON: 'cdj',
        authenticatorData: 'ad',
        signature: 'sig',
        userHandle: '',
      ),
    );
    expect(body, {
      'handle': 'h_2',
      'challenge': 'chal_2',
      'credential_id': 'raw_2',
      'authenticator_data': 'ad',
      'client_data_json': 'cdj',
      'signature': 'sig',
    });
  });

  test('assertion body falls back to id when rawId is empty', () {
    final body = passkeyAssertionFinishBody(
      {'challenge': 'c', 'handle': 'h'},
      const AuthenticateResponseType(
        id: 'id_only',
        rawId: '',
        clientDataJSON: 'cdj',
        authenticatorData: 'ad',
        signature: 'sig',
        userHandle: '',
      ),
    );
    expect(body['credential_id'], 'id_only');
  });

  // MARK: registerPasskey — begin → ceremony → finish

  test('registerPasskey runs begin → ceremony → finish with the mapped body',
      () async {
    final store = InMemoryTokenStore(
      const AtlasSession(sessionId: 'sess_1', token: 'jwt', refreshToken: 'rt'),
    );
    transport
      ..enqueue(200, registerBeginJson)
      ..enqueue(200, '{"object":"passkey","id":"pk_1","name":"My iPhone"}');

    final client = makeClient(store: store);
    final created = await client.registerPasskey(name: 'My iPhone');

    // Endpoints.
    expect(transport.recorded[0].url.path, '/v1/client/me/passkeys/begin');
    expect(transport.recorded[1].url.path, '/v1/client/me/passkeys/finish');

    // rpId/challenge were read FROM the begin response, not hardcoded.
    expect(passkey.lastRegister?.challenge, 'chal_R');
    expect(passkey.lastRegister?.relyingParty.id, 'fapi.acme.atlasauth.net');

    // Finish body is the server contract.
    expect(transport.bodyAt(1), {
      'challenge': 'chal_R',
      'attestation_object': 'ATT',
      'client_data_json': 'CDJ',
      'name': 'My iPhone',
    });

    // Authenticated: presents the session cookie.
    final cookie = transport.recorded[0].headers['cookie'] ??
        transport.recorded[0].headers['Cookie'];
    expect(cookie, contains('__session=jwt'));

    expect(created.id, 'pk_1');
    expect(created.name, 'My iPhone');
  });

  test('registerPasskey without a session throws notSignedIn', () async {
    final client = makeClient(); // empty store
    try {
      await client.registerPasskey();
      fail('expected notSignedIn');
    } on AtlasException catch (error) {
      expect(error.kind, AtlasErrorKind.notSignedIn);
    }
    expect(transport.recorded, isEmpty,
        reason: 'no request is made without a session');
  });

  test('registerPasskey surfaces a server error from finish', () async {
    final store = InMemoryTokenStore(
      const AtlasSession(sessionId: 'sess_1', token: 'jwt', refreshToken: 'rt'),
    );
    transport
      ..enqueue(200, registerBeginJson)
      ..enqueue(422,
          '{"errors":[{"code":"passkey_registration_failed","message":"Attestation rejected."}]}');

    final client = makeClient(store: store);
    try {
      await client.registerPasskey();
      fail('expected an AtlasException');
    } on AtlasException catch (error) {
      expect(error.code, 'passkey_registration_failed');
      expect(error.status, 422);
    }
  });

  // MARK: signInWithPasskey — begin → ceremony → finish → exchange → me

  test('signInWithPasskey completes and returns the user', () async {
    final store = InMemoryTokenStore();
    transport
      ..enqueue(200, signInBeginJson)
      // Passkey finish mints the session DIRECTLY (no ticket exchange): the
      // completed attempt carries jwt + created_session_id + a refresh cookie.
      ..enqueue(
        200,
        '{"object":"sign_in_attempt","status":"complete","created_session_id":"sess_1","jwt":"jwt_abc","expires_in":60}',
        headers: {'set-cookie': '__atlas_rt=rt_xyz; Path=/v1; HttpOnly'},
      )
      ..enqueue(200, userJson);

    final client = makeClient(store: store);
    final user = await client.signInWithPasskey();

    // Endpoints in order — finish goes straight to /me, no tickets/exchange.
    expect(transport.recorded[0].url.path, '/v1/client/sign_ins/passkey/begin');
    expect(transport.recorded[1].url.path, '/v1/client/sign_ins/passkey/finish');
    expect(transport.recorded[2].url.path, '/v1/client/me');

    // rpId/challenge/handle read from begin.
    expect(passkey.lastAuthenticate?.challenge, 'chal_A');
    expect(passkey.lastAuthenticate?.relyingPartyId, 'fapi.acme.atlasauth.net');

    // Finish body is the assertion contract.
    expect(transport.bodyAt(1), {
      'handle': 'h_A',
      'challenge': 'chal_A',
      'credential_id': 'raw_Y',
      'authenticator_data': 'AD',
      'client_data_json': 'CDJ',
      'signature': 'SIG',
    });

    // The begin call rides the publishable key, no session cookie.
    expect(transport.recorded[0].headers['x-publishable-key'], pk);
    expect(transport.recorded[0].headers.containsKey('cookie'), isFalse);

    // Session persisted from the exchange.
    final stored = await store.load();
    expect(stored?.token, 'jwt_abc');
    expect(stored?.refreshToken, 'rt_xyz');

    expect(user.id, 'user_1');
  });

  test('signInWithPasskey surfaces a non-complete status', () async {
    transport
      ..enqueue(200, signInBeginJson)
      ..enqueue(200, '{"id":"sia_1","status":"needs_second_factor"}');

    final client = makeClient();
    try {
      await client.signInWithPasskey();
      fail('expected an AtlasException');
    } on AtlasException catch (error) {
      expect(error.code, 'sign_in_not_complete');
      expect(error.message, contains('needs_second_factor'));
    }
  });
}
