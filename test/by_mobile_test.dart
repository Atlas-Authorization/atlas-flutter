import 'dart:convert';
import 'dart:typed_data';

import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_transport.dart';

/// Records the options the plugin was handed and answers with PRF results.
class _PrfAuthenticator implements AtlasPasskeyAuthenticator {
  RegisterRequestType? registered;
  AuthenticateRequestType? authenticated;
  static final output = Uint8List.fromList(List.filled(32, 9));

  @override
  Future<RegisterResponseType> register(RegisterRequestType request) async {
    registered = request;
    return const RegisterResponseType(
      id: 'cred_X',
      rawId: 'cred_X',
      clientDataJSON: 'CDJ',
      attestationObject: 'ATT',
      transports: [],
      clientExtensionResults: {
        'prf': {'enabled': true},
      },
    );
  }

  @override
  Future<AuthenticateResponseType> authenticate(AuthenticateRequestType request) async {
    authenticated = request;
    return AuthenticateResponseType(
      id: 'cred_X',
      rawId: 'cred_X',
      clientDataJSON: 'CDJ',
      authenticatorData: 'AD',
      signature: 'SIG',
      userHandle: '',
      clientExtensionResults: {
        'prf': {
          'results': {'first': base64Url.encode(output).replaceAll('=', '')},
        },
      },
    );
  }
}

void main() {
  late MockTransport transport;
  late _PrfAuthenticator authenticator;

  setUp(() {
    transport = MockTransport();
    authenticator = _PrfAuthenticator();
  });

  AtlasClient makeClient({TokenStore? store}) => AtlasClient(
        publishableKey: pk,
        frontendApi: frontendApi,
        tokenStore: store ?? InMemoryTokenStore(),
        httpClient: transport.client(),
        passkeyAuthenticator: authenticator,
      );

  InMemoryTokenStore signedIn() {
    final store = InMemoryTokenStore();
    store.save(const AtlasSession(sessionId: 'sess_1', token: 'jwt', refreshToken: 'rt'));
    return store;
  }

  test('sign-out follows the upstream logout URL and keeps only https', () async {
    transport.enqueue(200,
        '{"object":"session","upstream_logout_url":"https://idp.example.com/logout?x=1","saml_logout_url":"http://insecure.example.com/slo"}');
    final store = signedIn();
    final client = makeClient(store: store);
    final opened = <Uri>[];
    client.logoutUrlOpener = (url) async => opened.add(url);
    final result = await client.signOut(returnUrl: 'https://app.example.com/bye');
    expect(transport.recorded.single.url.path, '/v1/client/sessions/sess_1/revoke');
    expect(transport.bodyAt(0)['return_url'], 'https://app.example.com/bye');
    expect(result.upstreamLogoutUrl, 'https://idp.example.com/logout?x=1');
    expect(result.samlLogoutUrl, isNull);
    expect(opened.single.toString(), 'https://idp.example.com/logout?x=1');
    expect(store.load(), isNull);
  });

  test('sign-out prefers the SAML URL and can skip opening it', () async {
    transport.enqueue(200, '{"saml_logout_url":"https://clerk.example.com/v1/sso/saml/sso_1/slo/start?request=a"}');
    final client = makeClient(store: signedIn());
    client.logoutUrlOpener = (url) async => fail('must not open');
    final result = await client.signOut(followLogoutUrl: false);
    expect(result.logoutUrl, 'https://clerk.example.com/v1/sso/saml/sso_1/slo/start?request=a');
  });

  test('device approval: lookup, approve, deny, step-up refusal', () async {
    const da =
        '{"object":"device_authorization","id":"da_1","user_code":"WDJB-MJHT","status":"pending","client":{"client_id":"oc_tv","name":"TV","first_party":true},"scopes":[{"scope":"openid","description":"Sign you in"}],"audience":null,"requires_step_up":true,"created_at":1,"expires_at":2}';
    transport
      ..enqueue(200, da)
      ..enqueue(200, da.replaceFirst('pending', 'approved'))
      ..enqueue(200, da.replaceFirst('pending', 'denied'))
      ..enqueue(403, '{"errors":[{"code":"STEP_UP_REQUIRED","message":"Re-authenticate."}]}');
    final client = makeClient(store: signedIn());
    final auth = await client.lookupDeviceAuthorization(' wdjb mjht ');
    expect(transport.recorded[0].url.path, '/v1/client/me/device_authorizations/lookup');
    expect(transport.bodyAt(0)['user_code'], 'WDJB-MJHT');
    expect(transport.recorded[0].headers['Cookie'], contains('jwt'));
    expect(auth.client.name, 'TV');
    expect(auth.requiresStepUp, isTrue);
    expect(auth.scopes.single.description, 'Sign you in');
    expect((await client.approveDeviceAuthorization(auth)).status, 'approved');
    expect(transport.recorded[1].url.path, '/v1/client/me/device_authorizations/da_1/approve');
    expect((await client.denyDeviceAuthorization(auth)).status, 'denied');
    expect(transport.recorded[2].url.path, '/v1/client/me/device_authorizations/da_1/deny');
    await expectLater(
      client.approveDeviceAuthorization(auth),
      throwsA(isA<AtlasException>().having((e) => e.code, 'code', 'STEP_UP_REQUIRED')),
    );
    expect(AtlasClient.formatUserCode('abc'), 'abc');
    expect(AtlasClient.userCodeFromUrl('https://example.com/device?user_code=wdjbmjht'), 'WDJB-MJHT');
    expect(AtlasClient.userCodeFromUrl('nope'), isNull);
  });

  test('passkey PRF: the salt reaches the plugin, the output only the callback', () async {
    transport
      ..enqueue(200, '{"handle":"h_1","challenge":"ch_1","rpId":"clerk.example.com","allowCredentials":[]}')
      ..enqueue(200,
          '{"object":"sign_in_attempt","id":"sia_1","status":"complete","created_session_id":"sess_2","jwt":"jwt_2"}',
          headers: {'set-cookie': '__atlas_rt=rt_2; Path=/'})
      ..enqueue(200, '{"object":"user","id":"user_1"}');
    AtlasPasskeyPrfResult? got;
    try {
      await makeClient().signInWithPasskey(
        prf: AtlasPasskeyPrf.fromSalt('my-app-key'),
        onPrfResult: (r) => got = r,
      );
    } catch (_) {
      // The sign-in result shape is covered elsewhere; this test is about PRF.
    }
    expect(authenticator.authenticated!.prf, base64Url.encode(utf8.encode('my-app-key')).replaceAll('=', ''));
    final finish = jsonEncode(transport.bodyAt(1));
    expect(finish.contains('prf'), isFalse);
    expect(got!.credentialId, 'cred_X');
    expect(got!.first, _PrfAuthenticator.output);

    // Without prf nothing is requested.
    final plain = withPasskeyPrf({'challenge': 'c'}, null);
    expect(plain.containsKey('extensions'), isFalse);
    final merged = withPasskeyPrf({
      'challenge': 'c',
      'extensions': {'credProps': true},
    }, AtlasPasskeyPrf(Uint8List.fromList([1])));
    expect((merged['extensions'] as Map)['credProps'], isTrue);
    expect(((merged['extensions'] as Map)['prf'] as Map)['eval'], {'first': 'AQ'});
    expect(readPasskeyPrfResult('c', {'prf': {'enabled': true}})!.enabled, isTrue);
    expect(readPasskeyPrfResult('c', const {}), isNull);
  });

  test('passkey PRF on registration reports enabled', () async {
    transport
      ..enqueue(200, '{"challenge":"ch_r","rp":{"id":"clerk.example.com","name":"Acme"},"user":{"id":"dXNlcg","name":"a@b.com","displayName":"A"},"pubKeyCredParams":[]}')
      ..enqueue(200, '{"object":"passkey","id":"pk_1","name":null,"created_at":1}');
    AtlasPasskeyPrfResult? got;
    try {
      await makeClient(store: signedIn())
          .registerPasskey(prf: AtlasPasskeyPrf.fromSalt('k'), onPrfResult: (r) => got = r);
    } catch (_) {
      // Passkey model decoding is covered elsewhere.
    }
    expect(authenticator.registered!.prf, isNotNull);
    expect(got!.enabled, isTrue);
  });
}
