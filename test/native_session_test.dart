import 'dart:convert';

import 'package:atlas_auth/atlas_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// A FIFO queue of canned responses plus a record of every request — the same
/// `MockClient`-based harness `atlas_client_test.dart` uses, scoped here to the
/// cookie-free native-session surface.
class MockTransport {
  final List<http.Request> recorded = [];
  final List<_Stub> _stubs = [];

  void enqueue(int status, String json,
      {Map<String, String> headers = const {}}) {
    final merged = <String, String>{'content-type': 'application/json', ...headers};
    _stubs.add(_Stub(status, json, merged));
  }

  http.Client client() => MockClient((request) async {
        recorded.add(request);
        if (_stubs.isEmpty) {
          // No stub enqueued: simulate a transport failure.
          throw http.ClientException('no stubbed response', request.url);
        }
        final stub = _stubs.removeAt(0);
        return http.Response(stub.body, stub.status,
            headers: stub.headers, request: request);
      });
}

class _Stub {
  _Stub(this.status, this.body, this.headers);
  final int status;
  final String body;
  final Map<String, String> headers;
}

const pk = 'pk_test_123';
const clientId = 'client_first_party';
const baseUrl = 'https://clerk.example.com';

void main() {
  late MockTransport transport;

  setUp(() => transport = MockTransport());

  // MARK: exchangeForSession — happy path

  test('exchangeForSession parses the session and posts the form', () async {
    transport.enqueue(
      200,
      '{"access_token":"sess_jwt_1","issued_token_type":"urn:atlas:token-type:session",'
      '"token_type":"Bearer","expires_in":60,"refresh_token":"rt_1","session_id":"sess_abc"}',
    );

    final session = await exchangeForSession(
      baseUrl: baseUrl,
      clientId: clientId,
      accessToken: 'oauth_at_xyz',
      httpClient: transport.client(),
    );

    expect(session, isNotNull);
    expect(session!.sessionToken, 'sess_jwt_1');
    expect(session.refreshToken, 'rt_1');
    expect(session.sessionId, 'sess_abc');
    expect(session.expiresInSeconds, 60);

    final request = transport.recorded.single;
    expect(request.url.path, '/oauth2/token');
    expect(request.method, 'POST');
    expect(
      request.headers['content-type'],
      contains('application/x-www-form-urlencoded'),
    );
    // A Map body is form-encoded, so the fields come back on bodyFields.
    expect(request.bodyFields['grant_type'],
        'urn:ietf:params:oauth:grant-type:token-exchange');
    expect(request.bodyFields['subject_token'], 'oauth_at_xyz');
    expect(request.bodyFields['client_id'], clientId);
    expect(request.bodyFields['requested_token_type'],
        'urn:atlas:token-type:session');
  });

  // MARK: exchangeForSession — failure paths fail soft (null, never throw)

  test('exchangeForSession returns null on a non-2xx', () async {
    transport.enqueue(400, '{"error":"invalid_grant"}');
    final session = await exchangeForSession(
      baseUrl: baseUrl,
      clientId: clientId,
      accessToken: 'bad',
      httpClient: transport.client(),
    );
    expect(session, isNull);
  });

  test('exchangeForSession returns null when session_id is missing', () async {
    transport.enqueue(200, '{"access_token":"sess_jwt_1","expires_in":60}');
    final session = await exchangeForSession(
      baseUrl: baseUrl,
      clientId: clientId,
      accessToken: 'at',
      httpClient: transport.client(),
    );
    expect(session, isNull);
  });

  test('exchangeForSession returns null on a transport failure', () async {
    // No stub enqueued -> the MockClient throws a ClientException.
    final session = await exchangeForSession(
      baseUrl: baseUrl,
      clientId: clientId,
      accessToken: 'at',
      httpClient: transport.client(),
    );
    expect(session, isNull);
  });

  // MARK: refreshNativeSession — rotates the refresh token

  test('refreshNativeSession rotates the refresh token', () async {
    transport.enqueue(
      200,
      '{"object":"session_tokens","jwt":"sess_jwt_2","session_id":"sess_abc",'
      '"expires_in":60,"refresh_token":"rt_2"}',
    );

    final rotated = await refreshNativeSession(
      baseUrl: baseUrl,
      publishableKey: pk,
      sessionId: 'sess_abc',
      refreshToken: 'rt_1',
      httpClient: transport.client(),
    );

    expect(rotated, isNotNull);
    expect(rotated!.sessionToken, 'sess_jwt_2');
    expect(rotated.refreshToken, 'rt_2', reason: 'the refresh token must rotate');
    expect(rotated.sessionId, 'sess_abc');

    final request = transport.recorded.single;
    expect(request.url.path, '/v1/client/sessions/sess_abc/tokens');
    expect(request.headers['x-publishable-key'], pk);
    expect(jsonDecode(request.body)['refresh_token'], 'rt_1');
  });

  test('refreshNativeSession keeps the presented token when the server omits it',
      () async {
    transport.enqueue(
      200,
      '{"object":"session_tokens","jwt":"sess_jwt_2","session_id":"sess_abc","expires_in":60}',
    );
    final rotated = await refreshNativeSession(
      baseUrl: baseUrl,
      publishableKey: pk,
      sessionId: 'sess_abc',
      refreshToken: 'rt_keep',
      httpClient: transport.client(),
    );
    expect(rotated!.refreshToken, 'rt_keep');
  });

  test('refreshNativeSession returns null on a non-2xx', () async {
    transport.enqueue(401, '{"errors":[{"code":"session_expired"}]}');
    final rotated = await refreshNativeSession(
      baseUrl: baseUrl,
      publishableKey: pk,
      sessionId: 'sess_abc',
      refreshToken: 'rt_dead',
      httpClient: transport.client(),
    );
    expect(rotated, isNull);
  });

  // MARK: NativeSessionManager — exchange persists to the TokenStore

  test('manager.exchange persists the session to the store', () async {
    transport.enqueue(
      200,
      '{"access_token":"sess_jwt_1","expires_in":60,"refresh_token":"rt_1","session_id":"sess_abc"}',
    );
    final TokenStore store = InMemoryTokenStore();
    final manager = NativeSessionManager(
      publishableKey: pk,
      frontendApi: 'clerk.example.com',
      clientId: clientId,
      tokenStore: store,
      httpClient: transport.client(),
    );

    final session = await manager.exchange('oauth_at_xyz');
    expect(session!.sessionToken, 'sess_jwt_1');

    final stored = await store.load();
    expect(stored!.token, 'sess_jwt_1');
    expect(stored.refreshToken, 'rt_1');
    expect(stored.sessionId, 'sess_abc');

    final headers = await manager.authHeaders();
    expect(headers['Authorization'], 'Bearer sess_jwt_1');
    expect(headers['x-publishable-key'], pk);
  });

  // MARK: NativeSessionManager — token() lazily refreshes near expiry + persists

  test('manager.token refreshes an expired token and persists the rotation',
      () async {
    final TokenStore store = InMemoryTokenStore();
    final manager = NativeSessionManager(
      publishableKey: pk,
      frontendApi: 'clerk.example.com',
      clientId: clientId,
      tokenStore: store,
      httpClient: transport.client(),
    );
    // Seed a session that is already due for refresh (expires_in 0).
    await manager.setSession(const NativeSession(
      sessionToken: 'old',
      refreshToken: 'rt_1',
      sessionId: 'sess_abc',
    ));

    transport.enqueue(
      200,
      '{"object":"session_tokens","jwt":"fresh","session_id":"sess_abc",'
      '"expires_in":60,"refresh_token":"rt_2"}',
    );

    final token = await manager.token();
    expect(token, 'fresh', reason: 'an expired token is rotated before use');

    final stored = await store.load();
    expect(stored!.token, 'fresh');
    expect(stored.refreshToken, 'rt_2');
  });

  test('manager.token keeps the current token when the refresh fails', () async {
    final manager = NativeSessionManager(
      publishableKey: pk,
      frontendApi: 'clerk.example.com',
      tokenStore: InMemoryTokenStore(),
      httpClient: transport.client(),
    );
    await manager.setSession(const NativeSession(
      sessionToken: 'still_valid',
      refreshToken: 'rt_1',
      sessionId: 'sess_abc',
    ));
    // No stub -> the refresh fails at transport; the existing token stands.
    expect(await manager.token(), 'still_valid');
  });

  test('manager.token is null when signed out', () async {
    final manager = NativeSessionManager(
      publishableKey: pk,
      frontendApi: 'clerk.example.com',
      tokenStore: InMemoryTokenStore(),
      httpClient: transport.client(),
    );
    expect(await manager.token(), isNull);
    expect(await manager.authHeaders(), {'x-publishable-key': pk});
  });

  // MARK: model round-trip

  test('NativeSession maps to and from AtlasSession', () {
    const native = NativeSession(
      sessionToken: 'jwt',
      refreshToken: 'rt',
      sessionId: 'sess_1',
      expiresInSeconds: 60,
    );
    final session = native.toSession();
    expect(session.token, 'jwt');
    expect(session.refreshToken, 'rt');
    expect(session.sessionId, 'sess_1');

    final back = NativeSession.fromSession(session);
    expect(back.sessionToken, 'jwt');
    expect(back.refreshToken, 'rt');
    expect(back.sessionId, 'sess_1');
    expect(back.expiresInSeconds, 0, reason: 'expiry is not persisted');
  });
}
