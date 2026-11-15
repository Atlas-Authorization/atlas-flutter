import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_transport.dart';

void main() {
  late MockTransport t;
  late InMemoryTokenStore store;

  setUp(() {
    t = MockTransport();
    store = InMemoryTokenStore(const AtlasSession(sessionId: 'sess_1', token: 'jwt', refreshToken: 'rt'));
  });

  AtlasClient client() =>
      AtlasClient(publishableKey: pk, frontendApi: frontendApi, tokenStore: store, httpClient: t.client());


  group('billing', () {
    test('plans decode and sort', () async {
      t.enqueue(200, '{"data":[{"id":"b","name":"B","sort_order":2,"amount":0},{"id":"a","sort_order":1,"amount":"500"}]}');
      final plans = await client().billingPlans();
      expect(plans.map((p) => p.id), ['a', 'b']);
      expect(plans.first.amount, 500);
      expect(t.pathAt(0), '/v1/client/billing/plans');
    });

    test('priceView applies promotion and annual', () {
      final p = BillingPlan.fromJson({
        'id': 'plan_pro', 'interval': 'month', 'amount': 1000, 'currency': 'usd',
        'annual_available': true, 'annual_amount': '9600', 'trial_days': 14,
        'promotion': {'label': 'Launch', 'percent_off': 50, 'code': 'LAUNCH'},
      });
      final monthly = p.priceView(wantedInterval: 'month');
      expect(monthly.amount, 500);
      expect(monthly.originalPrice, '10.00 USD');
      expect(monthly.trialDays, 14);
      expect(monthly.promotionCode, 'LAUNCH');
      final yearly = p.priceView(wantedInterval: 'year');
      expect(yearly.interval, 'year');
      expect(yearly.amount, 4800);
      final expired = BillingPlan.fromJson({
        'id': 'x', 'amount': 1000,
        'promotion': {'label': 'Old', 'percent_off': 50, 'ends_at': 1000},
      });
      expect(expired.priceView(now: DateTime.fromMillisecondsSinceEpoch(5000)).amount, 1000);
    });

    test('subscription reads the org query and add-ons', () async {
      t.enqueue(200,
          '{"subject_type":"org","status":"active","id":"sub_1","cancel_at_period_end":true,"subscriptions":[{"id":"sub_1","status":"active"},{"id":"sub_2","status":"trialing","plan":{"id":"x","kind":"addon"}}]}');
      final sub = await client().billingSubscription(orgId: 'org_1');
      expect(t.recorded.first.url.toString(), 'https://clerk.example.com/v1/client/billing/subscription?org_id=org_1');
      expect(sub.isLive, isTrue);
      expect(sub.cancelAtPeriodEnd, isTrue);
      expect(sub.liveAddons.map((s) => s.id), ['sub_2']);
    });

    test('never subscribed has a null status', () async {
      t.enqueue(200, '{"subject_type":"user","status":null,"plan":null}');
      final sub = await client().billingSubscription();
      expect(sub.status, isNull);
      expect(sub.all, isEmpty);
    });

    test('checkout, portal and manage bodies', () async {
      final c = client();
      t.enqueue(200, '{"url":"https://checkout.example/s/1"}');
      final url = await c.billingCheckout(
          planId: 'plan_pro', successUrl: 'app://ok', cancelUrl: 'app://no', orgId: 'org_1', interval: 'year', couponCode: 'LAUNCH');
      expect(url.toString(), 'https://checkout.example/s/1');
      expect(t.methodAt(0), 'POST');
      expect(t.pathAt(0), '/v1/client/billing/checkout');
      expect(t.bodyAt(0), containsPair('plan_id', 'plan_pro'));
      expect(t.bodyAt(0), containsPair('org_id', 'org_1'));
      expect(t.bodyAt(0), containsPair('coupon_code', 'LAUNCH'));
      t.enqueue(200, '{"url":"https://portal.example/p"}');
      await c.billingPortal(returnUrl: 'app://back', subscriptionId: 'sub 2');
      expect(t.bodyAt(1), containsPair('subscription_id', 'sub 2'));
      const sub = '{"subject_type":"user","status":"active"}';
      t.enqueue(200, sub);
      await c.billingCancel(immediately: true);
      expect(t.pathAt(2), '/v1/client/billing/subscription/cancel');
      expect(t.bodyAt(2), containsPair('immediately', true));
      t.enqueue(200, sub);
      await c.billingRestore(subscriptionId: 'sub_2');
      expect(t.pathAt(3), '/v1/client/billing/subscriptions/sub_2/restore');
      t.enqueue(200, sub);
      await c.billingChangePlan(planId: 'plan_b', atPeriodEnd: true);
      expect(t.pathAt(4), '/v1/client/billing/subscription/change');
      expect(t.bodyAt(4), containsPair('schedule_at_period_end', true));
    });

    test('invoices, card, feature check and coupon', () async {
      final c = client();
      t.enqueue(200, '{"data":[{"id":"in_1","number":"A-1","status":"paid","amount_due":1000,"currency":"usd","created_at":1700000000000}]}');
      expect((await c.billingInvoices()).first.number, 'A-1');
      t.enqueue(200, '{"payment_method":{"brand":"visa","last4":"4242","exp_month":4,"exp_year":2030}}');
      expect((await c.billingPaymentMethod())?.last4, '4242');
      t.enqueue(200, '{"payment_method":null}');
      expect(await c.billingPaymentMethod(), isNull);
      t.enqueue(200, '{"feature":"seats","allowed":true,"remaining":3}');
      expect((await c.billingCheck('seats', required: 2)).allowed, isTrue);
      expect(t.recorded[3].url.query, 'feature=seats&required=2');
      t.enqueue(200, '{"valid":true,"discount":{"percent_off":20,"duration":"repeating","duration_months":3}}');
      final check = await c.billingValidateCoupon(planId: 'plan_pro', code: ' LAUNCH ');
      expect(check.durationMonths, 3);
      expect(t.bodyAt(4), containsPair('code', 'LAUNCH'));
    });

    test('controller switches in place when a base subscription is live', () async {
      final c = AtlasBillingController(client(), returnUrl: 'app://back');
      t
        ..enqueue(200, '{"data":[{"id":"a","name":"A","amount":0},{"id":"b","name":"B","amount":500}]}')
        ..enqueue(200, '{"subject_type":"user","status":"active","plan":{"id":"a","name":"A","amount":0}}')
        ..enqueue(200, '{"data":[]}')
        ..enqueue(200, '{"payment_method":null}');
      await c.load();
      t.enqueue(200, '{"subject_type":"user","status":"active","plan":{"id":"b","name":"B","amount":500}}');
      expect(await c.subscribe(c.plans[1]), isNull);
      expect(c.subscription?.plan?.id, 'b');
      expect(t.pathAt(4), '/v1/client/billing/subscription/change');
    });
  });

  group('api keys', () {
    const key =
        '{"id":"ak_1","subject_type":"user","subject_id":"user_1","name":"CI","prefix":"ak_live_abcd","scopes":["calls:read"],"created_at":1700000000000}';

    test('list, create, rename, revoke', () async {
      final c = client();
      t.enqueue(200, '{"data":[$key],"allowed_scopes":["calls:read","calls:write"],"max_active_keys":5,"active_count":1}');
      final list = await c.listApiKeys(organizationId: 'org_1', bound: true);
      expect(t.recorded.first.url.query, 'organization_id=org_1&subject_type=user');
      expect(list.maxActiveKeys, 5);
      expect(list.keys.first.isActive(), isTrue);
      t.enqueue(201, '${key.substring(0, key.length - 1)},"secret":"ak_live_secret"}');
      final created = await c.createApiKey(name: 'CI', expiresInSeconds: 86400, scopes: ['calls:read'], organizationId: 'org_1');
      expect(created.secret, 'ak_live_secret');
      expect(t.bodyAt(1), containsPair('expires_in_seconds', 86400));
      expect(t.bodyAt(1), containsPair('organization_id', 'org_1'));
      expect(t.bodyAt(1).containsKey('expires_at'), isFalse);
      t.enqueue(200, key);
      await c.renameApiKey('ak_1', null);
      expect(t.methodAt(2), 'PATCH');
      expect(t.bodyAt(2), containsPair('name', null));
      t.enqueue(200, '{"id":"ak_1","revoked":true}');
      await c.revokeApiKey('ak_1');
      expect(t.pathAt(3), '/v1/client/me/api_keys/ak_1/revoke');
    });

    test('a stale session surfaces step-up', () async {
      t.enqueue(403, '{"errors":[{"code":"STEP_UP_REQUIRED","message":"Re-authenticate"}]}');
      try {
        await client().createApiKey();
        fail('expected an error');
      } on AtlasException catch (e) {
        expect(e.isStepUpRequired, isTrue);
      }
    });

    test('stepUp persists the fresh jwt', () async {
      t.enqueue(200, '{"id":"sess_1","jwt":"jwt_fresh"}');
      await client().stepUp(strategy: 'password', password: 'pw');
      expect(t.pathAt(0), '/v1/client/me/step_up');
      expect(store.load()?.token, 'jwt_fresh');
      expect(store.load()?.refreshToken, 'rt');
    });

    test('controller parks the create on step-up and finishes it', () async {
      final c = AtlasApiKeysController(client());
      t.enqueue(403, '{"errors":[{"code":"STEP_UP_REQUIRED","message":"x"}]}');
      await c.create(name: 'CI', expiresInDays: 30);
      expect(c.needsStepUp, isTrue);
      t
        ..enqueue(200, '{"id":"sess_1","jwt":"fresh"}')
        ..enqueue(201, '${key.substring(0, key.length - 1)},"secret":"ak_secret"}')
        ..enqueue(200, '{"data":[]}');
      await c.completeStepUp('pw');
      expect(c.createdSecret, 'ak_secret');
      expect(c.needsStepUp, isFalse);
      expect(t.bodyAt(2), containsPair('expires_in_seconds', 30 * 86400));
    });

    test('a 403 on the list reads as disabled', () async {
      final c = AtlasApiKeysController(client());
      t.enqueue(403, '{"errors":[{"code":"FORBIDDEN","message":"off"}]}');
      await c.load();
      expect(c.status, AtlasApiKeysStatus.disabled);
    });
  });

  group('organizations', () {
    test('setActiveOrganization persists the rotated jwt', () async {
      final c = client();
      t.enqueue(200, '{"id":"sess_1","jwt":"jwt_rot","last_active_organization_id":"org_1"}');
      expect(await c.setActiveOrganization('org_1'), 'org_1');
      expect(t.pathAt(0), '/v1/client/sessions/sess_1/touch');
      expect(t.bodyAt(0), containsPair('active_organization_id', 'org_1'));
      expect(store.load()?.token, 'jwt_rot');
      t.enqueue(200, '{"id":"sess_1","jwt":"j2","last_active_organization_id":null}');
      expect(await c.setActiveOrganization(null), isNull);
      expect(t.bodyAt(1), containsPair('active_organization_id', null));
    });

    test('slug', () {
      expect(atlasOrganizationSlug('Acme Corp!'), 'acme-corp');
      expect(atlasOrganizationSlug('  a  b '), 'a-b');
    });

    test('controller loads, switches and creates', () async {
      final c = AtlasOrganizationSwitcherController(client());
      t.enqueue(200, '{"data":[{"role":"admin","organization":{"id":"org_1","name":"Acme","slug":"acme"}}]}');
      await c.load();
      expect(c.memberships.length, 1);
      t.enqueue(200, '{"id":"sess_1","jwt":"j","last_active_organization_id":"org_1"}');
      await c.select('org_1');
      expect(c.activeOrganizationId, 'org_1');
      t
        ..enqueue(201, '{"id":"org_2","name":"Beta","slug":"beta"}')
        ..enqueue(200, '{"id":"sess_1","jwt":"j2","last_active_organization_id":"org_2"}')
        ..enqueue(200, '{"data":[{"role":"admin","organization":{"id":"org_2","name":"Beta","slug":"beta"}}]}');
      expect(await c.create('Beta'), isTrue);
      expect(c.activeOrganizationId, 'org_2');
    });
  });

  group('device approval', () {
    test('lookup then approve', () async {
      final c = AtlasDeviceApprovalController(client());
      t.enqueue(200, '{"id":"da_1","user_code":"ABCD-EFGH","status":"pending","client":{"name":"TV"},"scopes":[]}');
      await c.lookup('abcdefgh');
      expect(c.phase, AtlasDeviceApprovalPhase.pending);
      t.enqueue(200, '{"id":"da_1","user_code":"ABCD-EFGH","status":"approved","client":{"name":"TV"},"scopes":[]}');
      await c.decide(approve: true);
      expect(c.phase, AtlasDeviceApprovalPhase.approved);
    });

    test('a stale session asks for step-up', () async {
      final c = AtlasDeviceApprovalController(client());
      t.enqueue(200, '{"id":"da_1","user_code":"ABCD-EFGH","client":{"name":"TV"}}');
      await c.lookup('ABCD-EFGH');
      t.enqueue(403, '{"errors":[{"code":"STEP_UP_REQUIRED","message":"x"}]}');
      await c.decide(approve: true);
      expect(c.needsStepUp, isTrue);
    });
  });

  group('step-up', () {
    test('passkey body drops the handle and sets the strategy', () {
      final body = stepUpPasskeyBody(
        {'challenge': 'ch', 'handle': 'h'},
        const AuthenticateResponseType(
          id: 'id', rawId: 'raw', clientDataJSON: 'cdj', authenticatorData: 'ad', signature: 'sig', userHandle: ''),
      );
      expect(body, {
        'strategy': 'passkey',
        'challenge': 'ch',
        'credential_id': 'raw',
        'authenticator_data': 'ad',
        'client_data_json': 'cdj',
        'signature': 'sig',
      });
    });

    test('push pending then approved', () async {
      final c = client();
      t.enqueue(200, '{"number_match":"42"}');
      expect(await c.beginPushStepUp(), '42');
      expect(t.pathAt(0), '/v1/client/me/step_up/push');
      t.enqueue(202, '{"status":"pending"}');
      expect(await c.stepUpPush(), isFalse);
      expect(store.load()?.token, 'jwt');
      t.enqueue(200, '{"id":"sess_1","jwt":"jwt_push"}');
      expect(await c.stepUpPush(), isTrue);
      expect(store.load()?.token, 'jwt_push');
    });
  });
}
