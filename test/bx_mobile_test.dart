import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_transport.dart';

class _FakeAuthenticator implements AtlasPasskeyAuthenticator {
  @override
  Future<RegisterResponseType> register(RegisterRequestType request) async => const RegisterResponseType(
        id: 'cred_X',
        rawId: 'cred_X',
        clientDataJSON: 'CDJ',
        attestationObject: 'ATT',
        transports: [],
      );

  @override
  Future<AuthenticateResponseType> authenticate(AuthenticateRequestType request) async =>
      throw UnimplementedError();
}

void main() {
  late MockTransport transport;

  setUp(() => transport = MockTransport());

  AtlasClient makeClient({TokenStore? store}) => AtlasClient(
        publishableKey: pk,
        frontendApi: frontendApi,
        tokenStore: store ?? InMemoryTokenStore(),
        httpClient: transport.client(),
        passkeyAuthenticator: _FakeAuthenticator(),
      )..deviceIdProvider = () => 'd_test';

  test('device id rides on account-creating starts only', () async {
    transport
      ..enqueue(201, '{"id":"sua_1","status":"needs_email_verification"}')
      ..enqueue(201, '{"id":"sia_1","status":"needs_first_factor","supported_first_factors":["password"]}');
    final client = makeClient();
    await client.createSignUp().create(email: 'a@b.com', password: 'pw');
    expect(transport.bodyAt(0)['device_id'], 'd_test');
    await client.createSignIn().start('a@b.com');
    expect(transport.bodyAt(1).containsKey('device_id'), isFalse);

    expect(AtlasClient.stampDeviceId('POST', '/v1/client/sign_ups', {'device_id': 'mine'}, () => 'x'), {'device_id': 'mine'});
    expect(AtlasClient.stampDeviceId('GET', '/v1/client/sign_ups', null, () => 'x'), isNull);
    expect(AtlasClient.deviceIdRoutes.contains('/v1/client/sign_ins/oauth'), isTrue);
    expect(AtlasClient.freshDeviceId(), startsWith('d_'));
  });

  test('captcha refusals are typed and the passkey begin carries the token', () {
    final e = AtlasException.api(status: 400, errors: [const AtlasErrorItem(code: 'CAPTCHA_REQUIRED', message: 'Solve it.')]);
    expect(e.knownCode, AtlasErrorCode.captchaRequired);
    expect(e.isCaptchaRequired, isTrue);
    expect(passkeySignInBeginBody('tok'), {'captcha_token': 'tok'});
    expect(passkeySignInBeginBody(null), isEmpty);
  });

  test('SMS MFA enrolment and the TOTP QR image', () async {
    transport
      ..enqueue(201, '{"id":"sia_m","status":"needs_mfa_enrollment"}')
      ..enqueue(201, '{"factor_id":"fac_s","strategy":"phone_code","phone":"+1*******0123"}')
      ..enqueue(200, '{"id":"sia_m","status":"needs_second_factor","backup_codes":["aaaa"]}');
    final flow = makeClient().createSignIn();
    await flow.start('a@b.com');
    final enrollment = await flow.prepareSmsMfaEnrollment('+14155550123');
    expect(transport.bodyAt(1), {'strategy': 'phone_code', 'phone': '+14155550123'});
    expect(enrollment.strategy, 'phone_code');
    expect(enrollment.phone, '+1*******0123');
    await flow.attemptSmsMfaEnrollment(factorId: enrollment.factorId, code: '123456');
    expect(transport.bodyAt(2), {'factor_id': 'fac_s', 'code': '123456'});
    expect(flow.backupCodes, ['aaaa']);

    final totp = MfaEnrollment.fromJson(
        {'factor_id': 'f', 'secret': 'S', 'uri': 'otpauth://x', 'qr_code': 'data:image/gif;base64,R0lGODlh'});
    expect(totp.qrCode, 'data:image/gif;base64,R0lGODlh');
    expect(totp.qrImageBytes, isNotEmpty);
    expect(MfaEnrollment.fromJson({'factor_id': 'f', 'qr_code': 'javascript:x'}).qrCode, isNull);
  });

  test('passkey-only sign-up: start, begin, finish', () async {
    transport
      ..enqueue(201,
          '{"object":"sign_up_attempt","id":"sua_p","status":"needs_first_factor","supported_first_factors":["passkey"],"poll_secret":"ps_1"}')
      ..enqueue(201,
          '{"challenge":"ch_1","rp":{"id":"clerk.example.com","name":"Acme"},"user":{"id":"dXNlcg","name":"a@b.com","displayName":"A"},"pubKeyCredParams":[{"type":"public-key","alg":-7}]}')
      ..enqueue(200, '{"object":"sign_up_attempt","id":"sua_p","status":"needs_email_verification"}');
    final client = makeClient();
    final flow = client.createPasskeySignUp();
    await flow.start(email: 'a@b.com', captchaToken: 'cap');
    expect(transport.pathAt(0), '/v1/client/sign_ups/passkey');
    expect(transport.bodyAt(0)['captcha_token'], 'cap');
    expect(flow.awaitingPasskey, isTrue);
    await client.createSignUpPasskey(flow);
    expect(transport.pathAt(1), '/v1/client/sign_ups/sua_p/passkey/begin');
    expect(transport.bodyAt(1), {'poll_secret': 'ps_1'});
    expect(transport.pathAt(2), '/v1/client/sign_ups/sua_p/passkey/finish');
    expect(transport.bodyAt(2)['poll_secret'], 'ps_1');
    expect(transport.bodyAt(2)['attestation_object'], 'ATT');
  });

  test('organization audit log', () async {
    transport.enqueue(200,
        '{"object":"list","data":[{"object":"audit_log","id":"al_1","action":"member.added","actor":{"type":"user","id":"u_1"},"target":{"type":"user","id":"u_2"},"organization_id":"org_1","created_at":1}],"has_more":true,"next_cursor":"al_1"}');
    final store = InMemoryTokenStore(const AtlasSession(sessionId: 'sess_1', token: 'jwt', refreshToken: 'rt'));
    final page = await makeClient(store: store).organizationAuditLog('org_1', limit: 10, action: 'member.');
    expect(transport.pathAt(0), '/v1/client/organizations/org_1/audit_logs');
    expect(transport.recorded[0].url.query, 'limit=10&action=member.');
    expect(page.data.first.action, 'member.added');
    expect(page.data.first.actor.id, 'u_1');
    expect(page.nextCursor, 'al_1');
    expect(page.hasMore, isTrue);
  });
}
