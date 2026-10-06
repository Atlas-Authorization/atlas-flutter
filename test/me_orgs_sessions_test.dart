import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_transport.dart';

void main() {
  late MockTransport transport;
  late InMemoryTokenStore store;

  setUp(() {
    transport = MockTransport();
    store = InMemoryTokenStore(
      const AtlasSession(sessionId: 'sess_1', token: 'jwt', refreshToken: 'rt'),
    );
  });

  AtlasClient makeClient() => AtlasClient(
        publishableKey: pk,
        frontendApi: frontendApi,
        tokenStore: store,
        httpClient: transport.client(),
      );

  test('authenticated calls present the session cookie', () async {
    transport.enqueue(200, '{"object":"list","data":[]}');
    await makeClient().listOrganizationMemberships();
    final cookie = transport.recorded.first.headers['cookie'] ??
        transport.recorded.first.headers['Cookie'];
    expect(cookie, contains('__session=jwt'));
    expect(cookie, contains('__atlas_rt=rt'));
  });

  test('a call with no session throws notSignedIn', () async {
    final client = AtlasClient(
      publishableKey: pk,
      frontendApi: frontendApi,
      tokenStore: InMemoryTokenStore(),
      httpClient: transport.client(),
    );
    try {
      await client.listSessions();
      fail('expected notSignedIn');
    } on AtlasException catch (e) {
      expect(e.kind, AtlasErrorKind.notSignedIn);
    }
  });

  group('organizations', () {
    test('listOrganizationMemberships maps role + organization', () async {
      transport.enqueue(200, '''
        {"object":"list","data":[
          {"object":"organization_membership","role":"admin",
           "organization":{"object":"organization","id":"org_1","name":"Acme","slug":"acme","image_url":"https://i/x.png","public_metadata":{"tier":"pro"}}}
        ]}''');

      final memberships = await makeClient().listOrganizationMemberships();
      expect(transport.pathAt(0), '/v1/client/me/organizations');
      expect(memberships, hasLength(1));
      expect(memberships.first.role, 'admin');
      expect(memberships.first.organization.name, 'Acme');
      expect(memberships.first.organization.slug, 'acme');
      expect(memberships.first.organization.publicMetadata?['tier'], 'pro');
    });

    test('createOrganization posts name + slug', () async {
      transport.enqueue(201,
          '{"object":"organization","id":"org_2","name":"Beta","slug":"beta"}');
      final org =
          await makeClient().createOrganization(name: 'Beta', slug: 'beta');
      expect(transport.methodAt(0), 'POST');
      expect(transport.pathAt(0), '/v1/client/organizations');
      expect(transport.bodyAt(0)['name'], 'Beta');
      expect(transport.bodyAt(0)['slug'], 'beta');
      expect(org.id, 'org_2');
    });

    test('updateOrganization PATCHes only the supplied fields', () async {
      transport.enqueue(200,
          '{"object":"organization","id":"org_1","name":"Renamed","slug":"acme"}');
      final org = await makeClient().updateOrganization('org_1',
          name: 'Renamed', publicMetadata: {'k': 1});
      expect(transport.methodAt(0), 'PATCH');
      expect(transport.pathAt(0), '/v1/client/organizations/org_1');
      expect(transport.bodyAt(0)['name'], 'Renamed');
      expect(transport.bodyAt(0)['public_metadata'], {'k': 1});
      expect(transport.bodyAt(0).containsKey('image_url'), isFalse);
      expect(org.name, 'Renamed');
    });

    test('getOrganization reads one org', () async {
      transport.enqueue(200,
          '{"object":"organization","id":"org_1","name":"Acme","slug":"acme","max_allowed_memberships":5}');
      final org = await makeClient().getOrganization('org_1');
      expect(transport.pathAt(0), '/v1/client/organizations/org_1');
      expect(org.maxAllowedMemberships, 5);
    });
  });

  group('sessions', () {
    test('listSessions maps the device shape', () async {
      transport.enqueue(200, '''
        {"object":"list","data":[
          {"object":"session","id":"sess_1","status":"active","current":true,"browser":"Chrome","os":"macOS","location":"Berlin, DE"},
          {"object":"session","id":"sess_2","status":"active","current":false}
        ]}''');
      final devices = await makeClient().listSessions();
      expect(transport.pathAt(0), '/v1/client/sessions');
      expect(devices, hasLength(2));
      expect(devices.first.current, isTrue);
      expect(devices.first.browser, 'Chrome');
      expect(devices.first.location, 'Berlin, DE');
    });

    test('revokeSession of the current session clears local storage',
        () async {
      transport.enqueue(200, '{"object":"session","id":"sess_1","status":"revoked"}');
      await makeClient().revokeSession('sess_1');
      expect(transport.pathAt(0), '/v1/client/sessions/sess_1/revoke');
      expect(await store.load(), isNull);
    });

    test('revokeSession of another device keeps this one signed in', () async {
      transport.enqueue(200, '{"object":"session","id":"sess_2","status":"revoked"}');
      await makeClient().revokeSession('sess_2');
      expect(await store.load(), isNotNull);
    });

    test('revokeOtherSessions returns the count', () async {
      transport.enqueue(200, '{"object":"client","sessions_revoked":3}');
      final n = await makeClient().revokeOtherSessions();
      expect(transport.pathAt(0), '/v1/client/sessions/revoke_all');
      expect(n, 3);
    });
  });

  group('/me mutations', () {
    test('updateProfile PATCHes only supplied fields and decodes the user',
        () async {
      transport.enqueue(200, '{"object":"user","id":"user_1","first_name":"Ada"}');
      final user = await makeClient().updateProfile(
        firstName: 'Ada',
        unsafeMetadata: {'theme': 'dark'},
      );
      expect(transport.methodAt(0), 'PATCH');
      expect(transport.pathAt(0), '/v1/client/me');
      expect(transport.bodyAt(0)['first_name'], 'Ada');
      expect(transport.bodyAt(0)['unsafe_metadata'], {'theme': 'dark'});
      expect(transport.bodyAt(0).containsKey('last_name'), isFalse);
      expect(user.firstName, 'Ada');
    });

    test('addEmailAddress posts the address and decodes EmailAddress', () async {
      transport.enqueue(201,
          '{"object":"email_address","id":"email_2","email_address":"a@b.com","verified":false,"primary":false}');
      final email = await makeClient().addEmailAddress('a@b.com');
      expect(transport.pathAt(0), '/v1/client/me/email_addresses');
      expect(transport.bodyAt(0)['email_address'], 'a@b.com');
      expect(email.id, 'email_2');
      expect(email.verified, isFalse);
    });

    test('verifyEmailAddress hits the attempt_verification endpoint', () async {
      transport.enqueue(200,
          '{"object":"email_address","id":"email_2","email_address":"a@b.com","verified":true,"primary":false}');
      final email =
          await makeClient().verifyEmailAddress(id: 'email_2', code: '112233');
      expect(transport.pathAt(0),
          '/v1/client/me/email_addresses/email_2/attempt_verification');
      expect(transport.bodyAt(0)['code'], '112233');
      expect(email.verified, isTrue);
    });

    test('setPrimaryEmailAddress + deleteEmailAddress hit the right routes',
        () async {
      transport
        ..enqueue(200, '{"object":"email_address","id":"email_2","primary":true}')
        ..enqueue(200, '{"object":"email_address","id":"email_2","deleted":true}');
      final client = makeClient();
      await client.setPrimaryEmailAddress('email_2');
      await client.deleteEmailAddress('email_2');
      expect(transport.pathAt(0), '/v1/client/me/email_addresses/email_2/primary');
      expect(transport.methodAt(1), 'DELETE');
      expect(transport.pathAt(1), '/v1/client/me/email_addresses/email_2');
    });

    test('connectExternalAccount returns the authorize URL', () async {
      transport.enqueue(201, '''
        {"object":"external_account_connection","provider":"github",
         "attempt_id":"att_1","authorization_url":"https://github.com/login/oauth/authorize?x=1",
         "scopes":["read:user","repo"]}''');
      final conn = await makeClient().connectExternalAccount(
        provider: 'github',
        redirectUrl: 'myapp://cb',
        additionalScopes: ['repo'],
      );
      expect(transport.pathAt(0), '/v1/client/me/external_accounts/connect');
      expect(transport.bodyAt(0)['provider'], 'github');
      expect(transport.bodyAt(0)['redirect_url'], 'myapp://cb');
      expect(transport.bodyAt(0)['additional_scopes'], ['repo']);
      expect(conn.authorizationUrl, startsWith('https://github.com/'));
      expect(conn.scopes, contains('repo'));
    });

    test('disconnectExternalAccount DELETEs the link', () async {
      transport.enqueue(200, '{"object":"external_account","id":"ext_1","deleted":true}');
      await makeClient().disconnectExternalAccount('ext_1');
      expect(transport.methodAt(0), 'DELETE');
      expect(transport.pathAt(0), '/v1/client/me/external_accounts/ext_1');
    });

    test('changePassword posts both passwords', () async {
      transport.enqueue(200, '{"object":"user","id":"user_1","sessions_revoked":4}');
      await makeClient()
          .changePassword(currentPassword: 'old-one', newPassword: 'new-one-9');
      expect(transport.pathAt(0), '/v1/client/me/change_password');
      expect(transport.bodyAt(0)['current_password'], 'old-one');
      expect(transport.bodyAt(0)['new_password'], 'new-one-9');
    });

    test('setPassword posts the new password', () async {
      transport.enqueue(200, '{"object":"user","id":"user_1","has_password":true}');
      await makeClient().setPassword('first-pass-9');
      expect(transport.pathAt(0), '/v1/client/me/set_password');
      expect(transport.bodyAt(0)['password'], 'first-pass-9');
    });

    test('an API error surfaces as AtlasException with the code', () async {
      transport.enqueue(409,
          '{"errors":[{"code":"identifier_exists","message":"That address is already in use."}]}');
      try {
        await makeClient().addEmailAddress('taken@b.com');
        fail('expected an AtlasException');
      } on AtlasException catch (e) {
        expect(e.status, 409);
        expect(e.code, 'identifier_exists');
      }
    });
  });
}
