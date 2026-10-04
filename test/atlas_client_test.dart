import 'dart:convert';

import 'package:atlas_auth/atlas_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A FIFO queue of canned responses plus a record of every request the client
/// made — the Dart analogue of the Swift `MockURLProtocol`. Built on
/// `package:http/testing.dart`'s [MockClient], the exact seam the SDK's injected
/// `http.Client` is designed for.
class MockTransport {
  final List<http.Request> recorded = [];
  final List<_Stub> _stubs = [];

  void enqueue(int status, String json, {Map<String, String> headers = const {}}) {
    final merged = <String, String>{'content-type': 'application/json', ...headers};
    _stubs.add(_Stub(status, json, merged));
  }

  http.Client client() => MockClient((request) async {
        recorded.add(request);
        if (_stubs.isEmpty) {
          // No stub enqueued: simulate a transport failure, like the Swift mock.
          throw http.ClientException('no stubbed response', request.url);
        }
        final stub = _stubs.removeAt(0);
        return http.Response(
          stub.body,
          stub.status,
          headers: stub.headers,
          request: request,
        );
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

const pk = 'pk_test_123';
const frontendApi = 'clerk.example.com';

const userJson = '''
{
  "object": "user",
  "id": "user_1",
  "first_name": "Ada",
  "last_name": "Lovelace",
  "username": null,
  "image_url": "https://img.example.com/a.png",
  "locale": "en-US",
  "public_metadata": { "plan": "pro" },
  "unsafe_metadata": {},
  "mfa_enabled": false,
  "has_password": true,
  "created_at": 1700000000000,
  "primary_email_id": "email_1",
  "email_addresses": [
    { "object": "email_address", "id": "email_1", "email_address": "ada@example.com", "verified": true, "primary": true }
  ],
  "external_accounts": [
    { "object": "external_account", "id": "ext_1", "provider": "google", "provider_email": "ada@gmail.com", "connected_at": 1700000000000 }
  ],
  "passkeys": []
}
''';

void main() {
  late MockTransport transport;

  setUp(() => transport = MockTransport());

  AtlasClient makeClient({TokenStore? store}) => AtlasClient(
        publishableKey: pk,
        frontendApi: frontendApi,
        tokenStore: store ?? InMemoryTokenStore(),
        httpClient: transport.client(),
      );

  // MARK: base URL + auth header

  test('resolves a bare host to https', () {
    final client = makeClient();
    expect(client.baseUrl, 'https://clerk.example.com');
  });

  test('resolves a full origin untouched (trailing slash trimmed)', () {
    final client = AtlasClient(
      publishableKey: pk,
      frontendApi: 'http://localhost:4000/',
      tokenStore: InMemoryTokenStore(),
      httpClient: transport.client(),
    );
    expect(client.baseUrl, 'http://localhost:4000');
  });

  test('rejects a secret key', () {
    expect(
      () => AtlasClient(publishableKey: 'sk_test_secret', frontendApi: frontendApi),
      throwsArgumentError,
    );
  });

  test('every request carries the publishable key and hits the base URL', () async {
    transport
      ..enqueue(201, '{"id":"sia_1","status":"needs_first_factor"}')
      ..enqueue(200, '{"id":"sia_1","status":"complete","ticket":"tk_1"}')
      ..enqueue(
        200,
        '{"object":"session","id":"sess_1","jwt":"jwt_abc","expires_in":60}',
        headers: {'set-cookie': '__atlas_rt=rt_xyz; Path=/v1; HttpOnly'},
      )
      ..enqueue(200, userJson);

    final client = makeClient();
    await client.signIn(email: 'a@b.com', password: 'hunter2');

    final first = transport.recorded[0];
    expect(first.url.toString(), 'https://clerk.example.com/v1/client/sign_ins');
    for (final request in transport.recorded) {
      expect(request.headers['x-publishable-key'], pk);
    }
  });

  // MARK: password sign-in — endpoint + body mutation-checks + token storage

  test('password sign-in hits the exact endpoints with the exact bodies', () async {
    transport
      ..enqueue(201, '{"id":"sia_42","status":"needs_first_factor"}')
      ..enqueue(200, '{"id":"sia_42","status":"complete","ticket":"tk_9"}')
      ..enqueue(
        200,
        '{"object":"session","id":"sess_9","jwt":"jwt_final","expires_in":60}',
        headers: {'set-cookie': '__atlas_rt=rt_final; Path=/v1; HttpOnly'},
      )
      ..enqueue(200, userJson);

    final store = InMemoryTokenStore();
    final client = makeClient(store: store);
    final user = await client.signIn(email: 'a@b.com', password: 'hunter2');

    // Step 1: create attempt with the identifier (never the password).
    expect(transport.recorded[0].url.path, '/v1/client/sign_ins');
    expect(transport.bodyAt(0)['identifier'], 'a@b.com');
    expect(transport.bodyAt(0).containsKey('password'), isFalse,
        reason: 'the password must not leak into the create call');

    // Step 2: first factor with strategy=password on the attempt id.
    expect(transport.recorded[1].url.path,
        '/v1/client/sign_ins/sia_42/attempt_first_factor');
    expect(transport.bodyAt(1)['strategy'], 'password');
    expect(transport.bodyAt(1)['password'], 'hunter2');

    // Step 3: exchange the completion ticket.
    expect(transport.recorded[2].url.path, '/v1/client/tickets/exchange');
    expect(transport.bodyAt(2)['attempt_id'], 'sia_42');
    expect(transport.bodyAt(2)['ticket'], 'tk_9');

    // Token stored: the JWT from the exchange and the refresh cookie captured.
    final stored = await store.load();
    expect(stored, isNotNull);
    expect(stored!.token, 'jwt_final');
    expect(stored.refreshToken, 'rt_final');
    expect(stored.sessionId, 'sess_9');

    expect(user.id, 'user_1');
  });

  // MARK: 4xx -> AtlasException with code (mutation-check on the envelope)

  test('wrong password surfaces an api error with a code', () async {
    transport
      ..enqueue(201, '{"id":"sia_1","status":"needs_first_factor"}')
      ..enqueue(
        422,
        '{"errors":[{"code":"form_password_incorrect","message":"Incorrect password.","param":"password"}]}',
      );

    final client = makeClient();
    try {
      await client.signIn(email: 'a@b.com', password: 'wrong');
      fail('expected an AtlasException');
    } on AtlasException catch (error) {
      expect(error.code, 'form_password_incorrect');
      expect(error.status, 422);
      expect(error.message, 'Incorrect password.');
      expect(error.errors.first.param, 'password');
    }
  });

  test('a malformed error body still yields a code', () async {
    transport.enqueue(500, 'not json at all');
    final client = makeClient();
    try {
      await client.oauthAuthorizeUrl(provider: 'google', redirectUri: 'app://cb');
      fail('expected an AtlasException');
    } on AtlasException catch (error) {
      expect(error.status, 500);
      expect(error.code, 'unexpected');
    }
  });

  // MARK: currentUser decodes

  test('currentUser decodes the full shape and presents the cookie', () async {
    final store = InMemoryTokenStore(
      const AtlasSession(sessionId: 'sess_1', token: 'jwt', refreshToken: 'rt'),
    );
    transport.enqueue(200, userJson);

    final client = makeClient(store: store);
    final user = await client.currentUser();

    expect(user.id, 'user_1');
    expect(user.firstName, 'Ada');
    expect(user.primaryEmailId, 'email_1');
    expect(user.emailAddresses?.first.emailAddress, 'ada@example.com');
    expect(user.emailAddresses?.first.verified, true);
    expect(user.externalAccounts?.first.provider, 'google');
    expect(user.publicMetadata?['plan'], 'pro');

    final cookie = transport.recorded.last.headers['cookie'] ??
        transport.recorded.last.headers['Cookie'];
    expect(cookie, contains('__atlas_rt=rt'));
    expect(cookie, contains('__session=jwt'));
  });

  test('currentUser without a session throws notSignedIn', () async {
    final client = makeClient(); // empty store
    try {
      await client.currentUser();
      fail('expected notSignedIn');
    } on AtlasException catch (error) {
      expect(error.kind, AtlasErrorKind.notSignedIn);
    }
  });

  // MARK: OAuth authorize URL

  test('oauthAuthorizeUrl returns the provider URL and posts the right body', () async {
    transport.enqueue(
      201,
      '{"object":"sign_in_attempt","id":"sia_o","status":"needs_oauth_callback","authorization_url":"https://accounts.google.com/o/oauth2/auth?x=1"}',
    );
    final client = makeClient();
    final url = await client.oauthAuthorizeUrl(
        provider: 'google', redirectUri: 'myapp://callback');

    expect(url.host, 'accounts.google.com');
    expect(transport.recorded[0].url.path, '/v1/client/sign_ins/oauth');
    expect(transport.bodyAt(0)['provider'], 'google');
    expect(transport.bodyAt(0)['redirect_url'], 'myapp://callback');
  });

  // MARK: refresh rotates the stored token

  test('refresh rotates the stored token', () async {
    final store = InMemoryTokenStore(
      const AtlasSession(sessionId: 'sess_1', token: 'old', refreshToken: 'rt_old'),
    );
    transport.enqueue(
      200,
      '{"object":"session_tokens","jwt":"jwt_new","session_id":"sess_1","expires_in":60}',
      headers: {'set-cookie': '__atlas_rt=rt_new; Path=/v1; HttpOnly'},
    );
    final client = makeClient(store: store);
    final rotated = await client.refresh();

    expect(rotated.token, 'jwt_new');
    expect(rotated.refreshToken, 'rt_new');
    expect(transport.recorded[0].url.path, '/v1/client/sessions/sess_1/tokens');
    expect((await store.load())?.token, 'jwt_new');
  });

  // MARK: sign-out clears storage even on network failure

  test('signOut clears the store even when revoke fails', () async {
    final store = InMemoryTokenStore(
      const AtlasSession(sessionId: 'sess_1', token: 'jwt', refreshToken: 'rt'),
    );
    // No stub enqueued: the revoke request fails at transport. Store must still
    // be cleared.
    final client = makeClient(store: store);
    await client.signOut();
    expect(await store.load(), isNull);
  });

  test('hasSession reflects the store', () async {
    final TokenStore store = InMemoryTokenStore();
    final client = makeClient(store: store);
    expect(await client.hasSession(), isFalse);
    await store.save(
      const AtlasSession(sessionId: 's', token: 't', refreshToken: 'r'),
    );
    expect(await client.hasSession(), isTrue);
  });

  // MARK: token store + model round-trips

  test('InMemoryTokenStore round-trips', () async {
    final TokenStore store = InMemoryTokenStore();
    expect(await store.load(), isNull);

    const session = AtlasSession(sessionId: 'sess_1', token: 'jwt', refreshToken: 'rt');
    await store.save(session);
    expect(await store.load(), session);

    await store.clear();
    expect(await store.load(), isNull);
  });

  test('AtlasSession JSON round-trips (guards the secure-store shape)', () {
    const session =
        AtlasSession(sessionId: 'sess_1', token: 'jwt_abc', refreshToken: 'rt_xyz');
    final decoded = AtlasSession.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>);
    expect(decoded, session);
  });
}
