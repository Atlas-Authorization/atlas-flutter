import 'dart:convert';

import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_transport.dart' as mt;

/// Integration `getToken`, the OIDC org / SSO claims, the 2026-10 error codes
/// and the new key-format guard.
void main() {
  const key = 'atlas_test_pk_abc';
  late mt.MockTransport transport;

  AtlasClient client({bool signedIn = true}) => AtlasClient(
        publishableKey: key,
        frontendApi: mt.frontendApi,
        tokenStore: signedIn
            ? InMemoryTokenStore(const AtlasSession(sessionId: 'sess_1', token: 'jwt_1', refreshToken: 'rt_1'))
            : InMemoryTokenStore(),
        httpClient: transport.client(),
      );

  setUp(() => transport = mt.MockTransport());

  group('key format', () {
    test('rejects every secret-key form, accepts every publishable form', () {
      for (final bad in ['sk_test_x', 'psk_live_x', 'atlas_test_sk_x', 'atlas_live_psk_x', 'atlas_live_dsk_x']) {
        expect(() => AtlasClient(publishableKey: bad, frontendApi: mt.frontendApi), throwsArgumentError, reason: bad);
      }
      for (final good in ['pk_test_x', 'atlas_test_pk_x', 'atlas_live_pk_x']) {
        final c = AtlasClient(
          publishableKey: good,
          frontendApi: mt.frontendApi,
          tokenStore: InMemoryTokenStore(),
          httpClient: transport.client(),
        );
        expect(c.publishableKey, good);
      }
    });
  });

  group('getToken', () {
    test('posts to the session integration route with the stored cookie', () async {
      transport.enqueue(200, '{"jwt":"t.t.t","expires_in":300,"integration":"chatly","audience":"chatly"}');
      final token = await client().getToken('chatly');
      expect(token, isNotNull);
      expect(token!.jwt, 't.t.t');
      expect(token.expiresIn, 300);
      expect(token.audience, 'chatly');
      final req = transport.reqAt(0);
      expect(req.method, 'POST');
      expect(req.url.path, '/v1/client/sessions/sess_1/integration_tokens/chatly');
      expect(req.headers['x-publishable-key'], key);
      expect(req.headers['Cookie'], contains('__atlas_rt=rt_1'));
    });

    test('carries the Forumulate space and reads the redeem fields', () async {
      transport.enqueue(200,
          '{"jwt":"j","expires_in":60,"integration":"forumulate","audience":"a","org_id":"o1","space_id":"s 1","redeem_url":"https://f.example/redeem"}');
      final token = await client().getToken('forumulate', spaceId: 's 1');
      expect(token!.orgId, 'o1');
      expect(token.redeemUrl, 'https://f.example/redeem');
      expect(transport.reqAt(0).url.query, 'space_id=s%201');
    });

    test('sends the per-call audience', () async {
      transport.enqueue(200, '{"jwt":"j","expires_in":60,"integration":"acme","audience":"acme:dv-1"}');
      final token = await client().getToken('acme',
          cbid: 'dv 1', audience: 'acme:dv-1', audienceParams: {'tenant': 't2'});
      expect(token!.audience, 'acme:dv-1');
      expect(transport.reqAt(0).url.query, 'tenant=t2&cbid=dv%201&audience=acme%3Adv-1');
    });

    test('is null when the integration is not enabled', () async {
      transport.enqueue(404, '{"errors":[{"code":"NOT_FOUND","message":"nope"}]}');
      expect(await client().getToken('chatly'), isNull);
    });

    test('throws on other refusals and without a session', () async {
      transport.enqueue(401, '{"errors":[{"code":"UNAUTHENTICATED","message":"no"}]}');
      await expectLater(
        client().getToken('chatly'),
        throwsA(isA<AtlasException>().having((e) => e.status, 'status', 401)),
      );
      await expectLater(
        client(signedIn: false).getToken('chatly'),
        throwsA(isA<AtlasException>().having((e) => e.kind, 'kind', AtlasErrorKind.notSignedIn)),
      );
      expect(transport.recorded.length, 1);
    });
  });

  group('getAtlasIdToken', () {
    test('sends the bearer, the origin and the key in the query, no cookie', () async {
      transport.enqueue(200,
          '{"jwt":"j","expires_in":300,"integration":"referalli","audience":"r","issuer":"https://atlasauth.net","jwks_uri":"https://atlasauth.net/jwks"}');
      final token = await client().getAtlasIdToken('referalli', 'at_123', origin: 'https://app.example');
      expect(token!.issuer, 'https://atlasauth.net');
      expect(token.jwksUri, 'https://atlasauth.net/jwks');
      final req = transport.reqAt(0);
      expect(req.url.path, '/v1/client/integrations/referalli/atlas_id_tokens');
      expect(req.url.queryParameters['publishable_key'], key);
      expect(req.headers['Authorization'], 'Bearer at_123');
      expect(req.headers['Origin'], 'https://app.example');
      expect(req.headers.containsKey('Cookie'), isFalse);
    });

    test('uses DPoP when a proof is given and types ORIGIN_NOT_ALLOWED', () async {
      transport.enqueue(403, '{"errors":[{"code":"ORIGIN_NOT_ALLOWED","message":"origin"}]}');
      await expectLater(
        client().getAtlasIdToken('referalli', 'at_1', dpopProof: 'proof'),
        throwsA(isA<AtlasException>().having((e) => e.isOriginNotAllowed, 'isOriginNotAllowed', isTrue)),
      );
      final req = transport.reqAt(0);
      expect(req.headers['Authorization'], 'DPoP at_1');
      expect(req.headers['DPoP'], 'proof');
    });

    test('is null on 404', () async {
      transport.enqueue(404, '{"errors":[{"code":"NOT_FOUND","message":"n"}]}');
      expect(await client().getAtlasIdToken('x', 't'), isNull);
    });
  });

  group('error codes', () {
    test('INSUFFICIENT_SCOPE reads the required scope; SCOPE_MISSING is tolerated', () {
      final e = AtlasException.fromResponse(403,
          '{"errors":[{"code":"INSUFFICIENT_SCOPE","message":"m","meta":{"required_scope":"webhooks:write"},"docs_url":"https://atlasauth.net/errors/INSUFFICIENT_SCOPE"}]}');
      expect(e.isInsufficientScope, isTrue);
      expect(e.requiredScope, 'webhooks:write');
      expect(e.errors.first.docsUrl, 'https://atlasauth.net/errors/INSUFFICIENT_SCOPE');
      final legacy = AtlasException.api(status: 403, errors: const [AtlasErrorItem(code: 'SCOPE_MISSING', message: 'm')]);
      expect(legacy.isInsufficientScope, isTrue);
      expect(legacy.requiredScope, isNull);
    });

    test('STEP_UP_REQUIRED and ORIGIN_NOT_ALLOWED are typed', () {
      final step = AtlasException.api(status: 403, errors: const [AtlasErrorItem(code: 'STEP_UP_REQUIRED', message: 'm')]);
      expect(step.isStepUpRequired, isTrue);
      expect(step.isOriginNotAllowed, isFalse);
      expect(step.knownCode, AtlasErrorCode.stepUpRequired);
    });

    test('ROUTE_NOT_FOUND carries did_you_mean and allowed_methods', () {
      final e = AtlasException.fromResponse(404,
          '{"errors":[{"code":"ROUTE_NOT_FOUND","message":"m","did_you_mean":["/v1/webhook_endpoints"],"allowed_methods":["GET","POST"]}]}');
      expect(e.isRouteNotFound, isTrue);
      expect(e.didYouMean, ['/v1/webhook_endpoints']);
      expect(e.allowedMethods, ['GET', 'POST']);
      final plain = AtlasException.api(status: 404, errors: const [AtlasErrorItem(code: 'NOT_FOUND', message: 'm')]);
      expect(plain.didYouMean, isEmpty);
    });
  });

  group('OidcClaims', () {
    test('reads the org and SSO claims', () {
      final claims = OidcClaims.fromClaims(jsonDecode(
        '{"org_id":"org_1","org_slug":"acme","org_role":"admin","org_permissions":["a:b","c:d"],'
        '"orgs":[{"id":"org_1","slug":"acme","role":"admin"},{"id":"org_2","slug":"b","role":"member"},{"slug":"skipped"}],'
        '"sso_connection_id":"sso_9","sso_tenant_id":"tid","sso_issuer":"https://login.example","sso_domain":"acme.com","sso_organization_id":"org_7","sso_connection_type":"saml"}',
      ) as Map<String, dynamic>);
      expect(claims.orgId, 'org_1');
      expect(claims.orgRole, 'admin');
      expect(claims.orgPermissions, ['a:b', 'c:d']);
      expect(claims.orgs.length, 2);
      expect(claims.orgs[1].role, 'member');
      expect(claims.sso?.connectionId, 'sso_9');
      expect(claims.sso?.domain, 'acme.com');
      expect(claims.ssoOrganizationId, 'org_7');
      expect(claims.ssoConnectionType, 'saml');
      final none = OidcClaims.fromClaims({'sub': 'u'});
      expect(none.orgId, isNull);
      expect(none.sso, isNull);
      expect(none.ssoOrganizationId, isNull);
      expect(none.ssoConnectionType, isNull);
      expect(none.orgs, isEmpty);
    });

    test('reads a JWT payload and builds scope lists', () {
      final payload = base64Url.encode(utf8.encode('{"org_id":"o","sso_connection_id":"s"}')).replaceAll('=', '');
      final c = OidcClaims.fromJwt('e30.$payload.sig');
      expect(c?.orgId, 'o');
      expect(c?.sso?.connectionId, 's');
      expect(OidcClaims.fromJwt('not-a-jwt'), isNull);
      expect(AtlasScopes.withOrganizations(['openid']), ['openid', 'organizations']);
      expect(AtlasScopes.withOrganizations(['openid', 'organizations']), ['openid', 'organizations']);
    });
  });
}
