import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_transport.dart';

const _sessionJson =
    '{"object":"session","id":"sess_1","jwt":"jwt_final","expires_in":60}';
const _rtCookie = {'set-cookie': '__atlas_rt=rt_final; Path=/v1; HttpOnly'};
const _userJson = '{"object":"user","id":"user_1"}';

void main() {
  late MockTransport transport;
  late InMemoryTokenStore store;

  setUp(() {
    transport = MockTransport();
    store = InMemoryTokenStore();
  });

  AtlasClient makeClient() => AtlasClient(
        publishableKey: pk,
        frontendApi: frontendApi,
        tokenStore: store,
        httpClient: transport.client(),
      );

  group('SignInFlow', () {
    test('status + nextStep before start is collect-identifier', () {
      final flow = makeClient().createSignIn();
      expect(flow.status, FlowStatus.needsIdentifier);
      expect(flow.nextStep, isA<CollectIdentifier>());
      expect(flow.isComplete, isFalse);
    });

    test('password → second factor → complete persists via ticket exchange',
        () async {
      transport
        ..enqueue(201,
            '{"id":"sia_1","status":"needs_first_factor","supported_first_factors":["password"]}')
        ..enqueue(200, '{"id":"sia_1","status":"needs_second_factor","supported_second_factors":["totp"]}')
        ..enqueue(200, '{"id":"sia_1","status":"complete","ticket":"tk_1"}')
        ..enqueue(200, _sessionJson, headers: _rtCookie);

      final flow = makeClient().createSignIn();

      final s1 = await flow.start('ada@example.com');
      expect(flow.status, FlowStatus.needsFirstFactor);
      expect(s1, isA<CollectFirstFactor>());
      expect((s1 as CollectFirstFactor).strategies, ['password']);
      expect(transport.pathAt(0), '/v1/client/sign_ins');
      expect(transport.bodyAt(0)['identifier'], 'ada@example.com');

      final s2 = await flow.attemptPassword('hunter2');
      expect(flow.status, FlowStatus.needsSecondFactor);
      expect(s2, isA<CollectSecondFactor>());
      expect((s2 as CollectSecondFactor).strategies, ['totp']);
      expect(transport.pathAt(1), '/v1/client/sign_ins/sia_1/attempt_first_factor');
      expect(transport.bodyAt(1)['strategy'], 'password');
      expect(transport.bodyAt(1)['password'], 'hunter2');

      final s3 = await flow.attemptTotp('123456');
      expect(flow.isComplete, isTrue);
      expect(s3, isA<FlowDone>());
      expect(transport.pathAt(2), '/v1/client/sign_ins/sia_1/attempt_second_factor');
      expect(transport.bodyAt(2)['code'], '123456');

      // Ticket exchanged and session persisted.
      expect(transport.pathAt(3), '/v1/client/tickets/exchange');
      expect(transport.bodyAt(3)['ticket'], 'tk_1');
      final stored = await store.load();
      expect(stored?.token, 'jwt_final');
      expect(stored?.refreshToken, 'rt_final');
    });

    test('passwordless email-code first factor', () async {
      transport
        ..enqueue(201,
            '{"id":"sia_2","status":"needs_first_factor","supported_first_factors":["email_code"]}')
        ..enqueue(200,
            '{"object":"sign_in_attempt","id":"sia_2","status":"needs_email_verification","poll_secret":"ps"}')
        ..enqueue(200, '{"id":"sia_2","status":"complete","ticket":"tk_2"}')
        ..enqueue(200, _sessionJson, headers: _rtCookie);

      final flow = makeClient().createSignIn();
      await flow.start('ada@example.com');
      final prepared = await flow.prepareFirstFactor(strategy: 'email_code');
      expect(prepared, isA<CollectEmailCode>());
      expect(transport.pathAt(1), '/v1/client/sign_ins/sia_2/prepare_first_factor');
      expect(transport.bodyAt(1)['strategy'], 'email_code');

      final done = await flow.attemptEmailCode('000111');
      expect(done, isA<FlowDone>());
      expect(transport.bodyAt(2)['code'], '000111');
      expect((await store.load())?.token, 'jwt_final');
    });

    test('MFA enrollment yields backup codes and completes', () async {
      transport
        ..enqueue(201, '{"id":"sia_3","status":"needs_first_factor","supported_first_factors":["password"]}')
        ..enqueue(200, '{"id":"sia_3","status":"needs_mfa_enrollment"}')
        ..enqueue(201, '{"object":"mfa_enrollment","factor_id":"mf_1","secret":"ABCDEF","uri":"otpauth://x"}')
        ..enqueue(200, '{"id":"sia_3","status":"complete","ticket":"tk_3","backup_codes":["aaa","bbb"]}')
        ..enqueue(200, _sessionJson, headers: _rtCookie);

      final flow = makeClient().createSignIn();
      await flow.start('ada@example.com');
      final step = await flow.attemptPassword('hunter2');
      expect(step, isA<EnrollSecondFactor>());

      final enrollment = await flow.prepareMfaEnrollment();
      expect(enrollment.factorId, 'mf_1');
      expect(enrollment.secret, 'ABCDEF');
      expect(transport.pathAt(2), '/v1/client/sign_ins/sia_3/prepare_mfa_enrollment');

      final done = await flow.attemptMfaEnrollment(factorId: 'mf_1', codes: ['111222']);
      expect(done, isA<FlowDone>());
      expect(transport.bodyAt(3)['factor_id'], 'mf_1');
      expect(transport.bodyAt(3)['codes'], ['111222']);
      expect(flow.backupCodes, ['aaa', 'bbb']);
      expect((await store.load())?.token, 'jwt_final');
    });

    test('prepareSecondFactor returns a typed SMS challenge without advancing',
        () async {
      transport
        ..enqueue(201, '{"id":"sia_4","status":"needs_first_factor","supported_first_factors":["password"]}')
        ..enqueue(200, '{"id":"sia_4","status":"needs_second_factor"}')
        ..enqueue(201, '{"object":"second_factor_challenge","strategy":"sms","sent_to":"+1••••1234"}');

      final flow = makeClient().createSignIn();
      await flow.start('ada@example.com');
      await flow.attemptPassword('hunter2');
      final prep = await flow.prepareSecondFactor(strategy: 'sms');
      expect(prep.strategy, 'sms');
      expect(prep.sentTo, '+1••••1234');
      // Status unchanged — the challenge does not advance the attempt.
      expect(flow.status, FlowStatus.needsSecondFactor);
      expect(transport.bodyAt(2)['strategy'], 'sms');
    });

    test('unknown status maps to FlowUnknown, not a blank step', () async {
      transport.enqueue(201, '{"id":"sia_5","status":"needs_teleport"}');
      final flow = makeClient().createSignIn();
      final step = await flow.start('ada@example.com');
      expect(step, isA<FlowUnknown>());
      expect((step as FlowUnknown).status, 'needs_teleport');
    });

    test('advancing before start throws', () async {
      final flow = makeClient().createSignIn();
      expect(() => flow.attemptPassword('x'), throwsA(isA<AtlasException>()));
    });
  });

  group('SignUpFlow', () {
    test('create → verify email → complete persists the session', () async {
      transport
        ..enqueue(201, '{"object":"sign_up_attempt","id":"su_1","status":"needs_email_verification"}')
        ..enqueue(200, '{"object":"sign_up_attempt","id":"su_1","status":"complete","ticket":"tk_s"}')
        ..enqueue(200, _sessionJson, headers: _rtCookie);

      final flow = makeClient().createSignUp();
      final step = await flow.create(email: 'new@example.com', password: 'hunter2longer');
      expect(step, isA<CollectEmailCode>());
      expect(transport.pathAt(0), '/v1/client/sign_ups');
      expect(transport.bodyAt(0)['email'], 'new@example.com');
      expect(transport.bodyAt(0)['password'], 'hunter2longer');

      final done = await flow.attemptVerification('424242');
      expect(done, isA<FlowDone>());
      expect(transport.pathAt(1), '/v1/client/sign_ups/su_1/attempt_verification');
      expect((await store.load())?.token, 'jwt_final');
    });
  });

  group('PasswordResetFlow', () {
    test('request → verify → new password completes with a ticket', () async {
      transport
        ..enqueue(201, '{"object":"password_reset_attempt","id":"pr_1","status":"needs_email_verification"}')
        ..enqueue(200, '{"object":"password_reset_attempt","id":"pr_1","status":"needs_new_password"}')
        ..enqueue(200, '{"object":"password_reset_attempt","id":"pr_1","status":"complete","ticket":"tk_r","sessions_revoked":2}')
        ..enqueue(200, _sessionJson, headers: _rtCookie);

      final flow = makeClient().createPasswordReset();
      final s1 = await flow.request('ada@example.com');
      expect(s1, isA<CollectEmailCode>());
      expect(transport.pathAt(0), '/v1/client/password_resets');
      expect(transport.bodyAt(0)['email_address'], 'ada@example.com');

      final s2 = await flow.attemptVerification('000111');
      expect(s2, isA<CollectNewPassword>());

      final s3 = await flow.setNewPassword('brandnewpass9');
      expect(s3, isA<FlowDone>());
      expect(transport.pathAt(2), '/v1/client/password_resets/pr_1/set_new_password');
      expect(transport.bodyAt(2)['password'], 'brandnewpass9');
      expect((await store.load())?.token, 'jwt_final');
    });

    test('no ticket (sign-in-after-reset off) completes without a session',
        () async {
      transport
        ..enqueue(201, '{"object":"password_reset_attempt","id":"pr_2","status":"needs_new_password"}')
        ..enqueue(200, '{"object":"password_reset_attempt","id":"pr_2","status":"complete","sessions_revoked":1}');

      final flow = makeClient().createPasswordReset();
      await flow.request('ada@example.com');
      final done = await flow.setNewPassword('brandnewpass9');
      expect(done, isA<FlowDone>());
      // No ticket → no session persisted; user signs in afresh.
      expect(await store.load(), isNull);
    });
  });

  group('signInWithIdToken', () {
    test('posts the id_token body and exchanges the completion ticket',
        () async {
      transport
        ..enqueue(200, '{"object":"sign_in_attempt","id":"sia_i","status":"complete","ticket":"tk_i"}')
        ..enqueue(200, _sessionJson, headers: _rtCookie)
        ..enqueue(200, _userJson);

      final client = makeClient();
      final user = await client.signInWithIdToken(
        provider: 'google',
        idToken: 'eyJ.abc.def',
        nonce: 'n0nce',
      );

      expect(transport.pathAt(0), '/v1/client/sign_ins/id_token');
      expect(transport.bodyAt(0)['provider'], 'google');
      expect(transport.bodyAt(0)['id_token'], 'eyJ.abc.def');
      expect(transport.bodyAt(0)['nonce'], 'n0nce');
      expect(transport.pathAt(1), '/v1/client/tickets/exchange');
      expect(user.id, 'user_1');
      expect((await store.load())?.token, 'jwt_final');
    });

    test('a non-complete id_token response throws with the status', () async {
      transport.enqueue(
          200, '{"object":"sign_in_attempt","id":"sia_i","status":"needs_second_factor"}');
      final client = makeClient();
      expect(
        () => client.signInWithIdToken(provider: 'apple', idToken: 'tok'),
        throwsA(isA<AtlasException>()),
      );
    });

    test('mintIdTokenNonce returns the nonce', () async {
      transport.enqueue(200, '{"nonce":"abc123"}');
      final nonce = await makeClient().mintIdTokenNonce('google');
      expect(nonce, 'abc123');
      expect(transport.pathAt(0), '/v1/client/sign_ins/id_token/nonce');
      expect(transport.bodyAt(0)['provider'], 'google');
    });
  });
}
