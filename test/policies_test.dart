import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_transport.dart';

const _policiesJson = '''
{"object":"list","data":[
  {"object":"policy","key":"tos","title":"Terms of Service","display":"checkbox","required":true,"applies_to":"sign_in_and_sign_up",
   "version_id":"polv_1","version":"2026-10-24","content_html":"<p>Hello</p>","content_sha256":"abc","effective_at":1790000000000,"summary_of_changes":null},
  {"object":"policy","key":"privacy","title":"Privacy","display":"scroll","required":true,"applies_to":"sign_up",
   "version_id":"polv_2","version":"3","content_markdown":"# Privacy","content_html":null,"content_sha256":"def"}
],"legacy_consent":{"required":false,"terms_url":"https://x/t","privacy_url":null}}
''';

AtlasPolicy policy(String key, {String display = 'checkbox', bool required = true, String? html = '<p>Terms</p>'}) =>
    AtlasPolicy(
      key: key,
      title: key.toUpperCase(),
      display: display,
      required: required,
      versionId: 'polv_$key',
      version: '2026-10-24',
      contentHtml: html,
      contentSha256: 'sha_$key',
    );

void main() {
  late MockTransport transport;
  late InMemoryTokenStore store;

  setUp(() {
    transport = MockTransport();
    store = InMemoryTokenStore();
  });

  AtlasClient makeClient([InMemoryTokenStore? s]) => AtlasClient(
        publishableKey: pk,
        frontendApi: frontendApi,
        tokenStore: s ?? store,
        httpClient: transport.client(),
      );

  AtlasClient signedIn() {
    final s = InMemoryTokenStore();
    s.save(const AtlasSession(sessionId: 's', token: 'j', refreshToken: 'rt'));
    return makeClient(s);
  }

  group('wire readers', () {
    test('policies are read from the wire', () async {
      transport.enqueue(200, _policiesJson);
      final res = await makeClient().policies(locale: 'fr');
      expect(transport.pathAt(0), '/v1/client/policies');
      expect(transport.recorded[0].url.query, 'locale=fr');
      expect(transport.methodAt(0), 'GET');
      expect(res.policies, hasLength(2));
      final tos = res.policies[0];
      expect(tos.key, 'tos');
      expect(tos.display, 'checkbox');
      expect(tos.versionId, 'polv_1');
      expect(tos.effectiveAt, 1790000000000);
      expect(res.signIn, hasLength(1));
      expect(res.policies[1].display, 'scroll');
      expect(res.policies[1].contentHtml, isNull);
      expect(res.policies[1].contentMarkdown, '# Privacy');
      expect(res.policies[1].html, contains('<h1>Privacy</h1>'));
      expect(res.legacyConsent?.termsUrl, 'https://x/t');
    });

    test('nested version and policy-key shapes are accepted', () {
      final p = AtlasPolicy.fromJson({
        'policy': 'tos',
        'title': 'T',
        'version': {'id': 'polv_9', 'version': 'v9', 'content_html': '<p>x</p>', 'content_sha256': 'zz'},
      })!;
      expect(p.key, 'tos');
      expect(p.versionId, 'polv_9');
      expect(p.version, 'v9');
      expect(p.display, 'checkbox');
      expect(AtlasPolicy.fromJson({'title': 'no key'}), isNull);
    });

    test('a held attempt maps to AcceptPolicies with its pending list', () {
      final a = SignInAttempt.fromJson({
        'id': 'sia_1',
        'status': 'needs_policy_acceptance',
        'policy_acceptance_token': 'pat_1',
        'pending_policies': [
          {
            'policy': 'tos',
            'title': 'Terms',
            'display': 'scroll',
            'version_id': 'polv_1',
            'version': '2',
            'content_sha256': 'h',
            'reaccept': true,
            'summary_of_changes': 'New clause',
          }
        ],
      });
      expect(a.policyAcceptanceToken, 'pat_1');
      expect(flowStatusFromString(a.status), FlowStatus.needsPolicyAcceptance);
      final p = pendingPoliciesOf(a).single;
      expect(p.key, 'tos');
      expect(p.display, 'scroll');
      expect(p.reaccept, isTrue);
      expect(p.summaryOfChanges, 'New clause');
      expect(p.hasContent, isFalse);
    });

    test('redirect params are read', () {
      final r = AtlasRedirectResult.parse(
          'myapp://cb?__atlas_attempt=sia_7&__atlas_status=needs_policy_acceptance&__atlas_policy_token=pat%2B1#x')!;
      expect(r.attemptId, 'sia_7');
      expect(r.needsPolicyAcceptance, isTrue);
      expect(r.policyToken, 'pat+1');
      expect(AtlasRedirectResult.parse('myapp://cb?foo=bar'), isNull);
      expect(
          AtlasRedirectResult.parse('myapp://cb?__atlas_attempt=a&__atlas_status=complete&__atlas_policy_token=x')!
              .policyToken,
          isNull);
    });
  });

  group('PolicyAcceptanceController', () {
    test('builds acceptances and gates the submit', () {
      var clock = 1000;
      final c = PolicyAcceptanceController(
        [
          policy('tos'),
          policy('privacy', display: 'scroll'),
          policy('cookies', display: 'link'),
          policy('news', required: false),
        ],
        now: () => clock,
      );
      // A required checkbox blocks; scroll-mode policies are read on submit and do not block the button.
      expect(c.canSubmit(), isFalse);
      c.setAllChecked(true);
      expect(c.canSubmit(), isTrue);
      expect(c.satisfied(), isFalse);
      expect(c.pendingScroll()?.key, 'privacy');

      c.startClock('privacy');
      clock += 4000;
      c.stopClock('privacy');
      c.acceptScroll('privacy');
      expect(c.satisfied(), isTrue);
      expect(c.pendingScroll(), isNull);

      final byKey = {for (final a in c.build()) a.policy: a};
      expect(byKey.keys.toSet(), {'tos', 'privacy', 'cookies', 'news'});
      expect(byKey['privacy']!.scrolledToEnd, isTrue);
      expect(byKey['privacy']!.viewMs, 4000);
      expect(byKey['privacy']!.versionId, 'polv_privacy');
      expect(byKey['tos']!.contentSha256, 'sha_tos');
      expect(byKey['tos']!.viewMs, isNull);
      expect(byKey['tos']!.scrolledToEnd, isNull);
      expect(byKey['cookies']!.display, 'link');
      expect(byKey['tos']!.toJson()['version_id'], 'polv_tos');
    });

    test('an unread scroll policy is not built', () {
      expect(PolicyAcceptanceController([policy('privacy', display: 'scroll')]).build(), isEmpty);
    });

    test('the reading clock records view_ms while the document is open', () {
      var clock = 0;
      final c = PolicyAcceptanceController([policy('tos')], now: () => clock);
      c.openDocument('tos');
      clock += 2500;
      expect(c.viewing?.key, 'tos');
      c.closeDocument();
      c.setChecked('tos', true);
      expect(c.build().single.viewMs, 2500);
    });

    test('ticks survive a refresh of unchanged versions only', () {
      final c = PolicyAcceptanceController([policy('tos'), policy('privacy')]);
      c.setAllChecked(true);
      c.setPolicies([
        policy('tos'),
        const AtlasPolicy(key: 'privacy', title: 'PRIVACY', versionId: 'polv_new'),
      ]);
      expect(c.isChecked('tos'), isTrue);
      expect(c.isChecked('privacy'), isFalse);
    });

    test('separate mode ticks one at a time; listeners can stop', () {
      final c = PolicyAcceptanceController([policy('tos'), policy('privacy')], combined: false);
      var n = 0;
      void l() => n++;
      c.addListener(l);
      c.setChecked('tos', true);
      c.removeListener(l);
      c.setChecked('tos', false);
      c.setChecked('tos', true);
      expect(n, 1);
      expect(c.combinedChecked, isFalse);
      expect(c.missing().map((p) => p.key), ['privacy']);
    });
  });

  group('flows', () {
    test('sign-up sends policy_acceptances and omits them when none', () async {
      transport
        ..enqueue(201, '{"id":"sua_1","status":"needs_email_verification"}')
        ..enqueue(201, '{"id":"sua_2","status":"needs_email_verification"}');
      final c = PolicyAcceptanceController([policy('tos')])..setAllChecked(true);
      final client = makeClient();
      await client.createSignUp().create(email: 'a@b.co', password: 'pw', policyAcceptances: c.build());
      final sent = (transport.bodyAt(0)['policy_acceptances'] as List).single as Map;
      expect(sent['policy'], 'tos');
      expect(sent['version_id'], 'polv_tos');
      expect(sent['content_sha256'], 'sha_tos');
      expect(sent['display'], 'checkbox');
      await client.createSignUp().create(email: 'a@b.co', password: 'pw');
      expect(transport.bodyAt(1).containsKey('policy_acceptances'), isFalse);
    });

    test('a 422 refusal is recognised and reloads the policies', () async {
      transport.enqueue(422, '{"errors":[{"code":"POLICY_ACCEPTANCE_REQUIRED","message":"Accept the terms."}]}');
      final client = makeClient();
      AtlasException? failure;
      try {
        await client.createSignUp().create(email: 'a@b.co', password: 'pw');
      } on AtlasException catch (e) {
        failure = e;
      }
      expect(failure!.isPolicyAcceptanceRequired, isTrue);

      transport.enqueue(200, _policiesJson);
      final c = PolicyAcceptanceController([]);
      expect(await client.refreshPoliciesOnRequired(c, failure), isTrue);
      expect(c.policies, hasLength(2));
      final other = AtlasException.api(status: 400, errors: [const AtlasErrorItem(code: 'VALIDATION_FAILED', message: 'x')]);
      expect(await client.refreshPoliciesOnRequired(c, other), isFalse);
    });

    test('a held sign-in continues with the policy token and completes', () async {
      transport
        ..enqueue(201, '{"id":"sia_1","status":"needs_first_factor","supported_first_factors":["password"]}')
        ..enqueue(
            200,
            '{"id":"sia_1","status":"needs_policy_acceptance","policy_acceptance_token":"pat_9",'
            '"pending_policies":[{"policy":"tos","title":"Terms","display":"checkbox","version_id":"polv_1","version":"2","content_sha256":"h"}]}')
        ..enqueue(200, '{"id":"sia_1","status":"complete","ticket":"tk_1"}')
        ..enqueue(200, '{"object":"session","id":"sess_1","jwt":"jwt_final","expires_in":60}',
            headers: {'set-cookie': '__atlas_rt=rt_final; Path=/v1; HttpOnly'});
      final flow = makeClient().createSignIn();
      await flow.start('a@b.co');
      final step = await flow.attemptPassword('pw');
      expect(step, isA<AcceptPolicies>());
      expect((step as AcceptPolicies).policies.single.key, 'tos');

      final done = await flow.acceptPolicies([
        const PolicyAcceptance(policy: 'tos', versionId: 'polv_1', contentSha256: 'h', display: 'checkbox'),
      ]);
      expect(done, isA<FlowDone>());
      expect(transport.pathAt(2), '/v1/client/sign_ins/sia_1/accept_policies');
      final b = transport.bodyAt(2);
      expect(b['policy_acceptance_token'], 'pat_9');
      expect(b.containsKey('poll_secret'), isFalse);
      expect(((b['policy_acceptances'] as List).single as Map)['policy'], 'tos');
      expect(store.load()?.token, 'jwt_final');
    });

    test('policyController fills in content the attempt only listed', () async {
      final a = SignInAttempt.fromJson({
        'id': 'sia_1',
        'status': 'needs_policy_acceptance',
        'pending_policies': [
          {'policy': 'tos', 'title': 'Terms', 'display': 'scroll', 'version_id': 'polv_1', 'version': '2', 'content_sha256': 'h', 'reaccept': true}
        ],
      });
      transport.enqueue(200, _policiesJson);
      final c = await makeClient().policyController(a);
      final p = c.policies.single;
      expect(p.contentHtml, '<p>Hello</p>');
      expect(p.display, 'scroll'); // the attempt's display wins
      expect(p.versionId, 'polv_1');
      expect(p.title, 'Terms');
      expect(p.required, isTrue);
    });

    test('a resumed redirect shows every required policy and continues with its token', () async {
      final r = AtlasRedirectResult.parse(
          'myapp://cb?__atlas_attempt=sia_7&__atlas_status=needs_policy_acceptance&__atlas_policy_token=pat%2B1')!;
      transport
        ..enqueue(200, _policiesJson)
        ..enqueue(200, '{"id":"sia_7","status":"complete","ticket":"tk"}')
        ..enqueue(200, '{"object":"session","id":"s","jwt":"j","expires_in":60}',
            headers: {'set-cookie': '__atlas_rt=rt; Path=/v1'});
      final client = makeClient();
      final flow = client.resumeSignIn(r);
      expect(flow.nextStep, isA<AcceptPolicies>());
      final c = await client.policyController(flow.attempt);
      expect(c.policies.map((p) => p.key), ['tos', 'privacy']);
      await flow.acceptPolicies([const PolicyAcceptance(policy: 'tos', versionId: 'v', contentSha256: 'h')]);
      expect(transport.pathAt(1), '/v1/client/sign_ins/sia_7/accept_policies');
      expect(transport.bodyAt(1)['policy_acceptance_token'], 'pat+1');
    });

    test('a native id_token sign-in held at policies continues in the flow', () async {
      transport
        ..enqueue(200, '{"id":"sia_3","status":"needs_policy_acceptance","policy_acceptance_token":"pat_3"}')
        ..enqueue(200, '{"id":"sia_3","status":"needs_second_factor"}');
      final flow = makeClient().createSignIn();
      final step = await flow.startWithIdToken(provider: 'google', idToken: 'tok', nonce: 'n');
      expect(step, isA<AcceptPolicies>());
      expect(transport.bodyAt(0)['id_token'], 'tok');
      final next = await flow.acceptPolicies([const PolicyAcceptance(policy: 'tos', versionId: 'v', contentSha256: 'h')]);
      expect(next, isA<CollectSecondFactor>());
    });

    test('a passkey sign-up accepts with the poll secret when there is no token', () async {
      transport
        ..enqueue(201, '{"id":"sua_1","status":"needs_policy_acceptance","poll_secret":"ps_1"}')
        ..enqueue(200, '{"id":"sua_1","status":"needs_first_factor","supported_first_factors":["passkey"]}');
      final flow = makeClient().createPasskeySignUp();
      await flow.start(
          email: 'a@b.co',
          policyAcceptances: [const PolicyAcceptance(policy: 'tos', versionId: 'v', contentSha256: 'h')]);
      expect(transport.bodyAt(0).containsKey('policy_acceptances'), isTrue);
      await flow.acceptPolicies([const PolicyAcceptance(policy: 'tos', versionId: 'v', contentSha256: 'h')]);
      final b = transport.bodyAt(1);
      expect(b['poll_secret'], 'ps_1');
      expect(b.containsKey('policy_acceptance_token'), isFalse);
    });

    test('password reset held at policies continues', () async {
      transport
        ..enqueue(201, '{"id":"pr_1","status":"needs_policy_acceptance","policy_acceptance_token":"pat_r"}')
        ..enqueue(200, '{"id":"pr_1","status":"complete"}');
      final flow = makeClient().createPasswordReset();
      expect(await flow.request('a@b.co'), isA<AcceptPolicies>());
      await flow.acceptPolicies([const PolicyAcceptance(policy: 'tos', versionId: 'v', contentSha256: 'h')]);
      expect(transport.pathAt(1), '/v1/client/sign_ins/pr_1/accept_policies');
      expect(transport.bodyAt(1)['policy_acceptance_token'], 'pat_r');
    });

    test('my policies and in-app acceptance use the session routes', () async {
      final client = signedIn();
      transport.enqueue(
          200,
          '{"object":"list","needs_acceptance":true,"blocking":false,"data":['
          '{"policy":"tos","title":"Terms","accepted_version":"1","current_version":"2","needs_reaccept":true,"grace_ends_at":1790000000000,"blocking":false},'
          '{"policy":"privacy","title":"Privacy","needs_reaccept":false}]}');
      final mine = await client.myPolicies();
      expect(transport.pathAt(0), '/v1/client/me/policies');
      expect(transport.recorded[0].headers['Cookie'], contains('__atlas_rt=rt'));
      expect(mine[0].needsReaccept, isTrue);
      expect(mine[0].graceEndsAt, 1790000000000);
      expect(mine[1].needsReaccept, isFalse);

      transport.enqueue(200, '{}');
      await client.acceptMyPolicies([
        const PolicyAcceptance(
            policy: 'tos', versionId: 'polv_2', contentSha256: 'h', display: 'scroll', scrolledToEnd: true, viewMs: 5000)
      ]);
      expect(transport.pathAt(1), '/v1/client/me/policies/accept');
      final sent = (transport.bodyAt(1)['policy_acceptances'] as List).single as Map;
      expect(sent['scrolled_to_end'], isTrue);
      expect(sent['view_ms'], 5000);
    });

    test('the gate builds a controller for only the stale policies', () async {
      final client = signedIn();
      final gate = PolicyGate(client);
      transport.enqueue(200,
          '{"data":[{"policy":"tos","title":"Terms","needs_reaccept":true,"grace_ends_at":1790000000000},{"policy":"privacy","needs_reaccept":false}]}');
      await gate.load();
      expect(gate.graceEndsAt, 1790000000000);
      transport.enqueue(200, _policiesJson);
      final c = await gate.begin();
      expect(c.policies.map((p) => p.key), ['tos']);
      expect(c.policies.single.required, isTrue);
    });
  });

  group('helpers', () {
    test('format and split', () {
      expect(joinPolicyTitles(['A', 'B', 'C'], 'and'), 'A, B and C');
      expect(joinPolicyTitles(['A'], 'and'), 'A');
      expect(splitPolicyTemplate('I agree to the {policies}.', 'policies'), ('I agree to the ', '.'));
      expect(formatPolicyDate(1792800000000), '2026-10-24');
      expect(formatPolicyDate(null), '');
      expect(fillPolicyTemplate('Please accept {policy}', {'policy': 'Terms'}), 'Please accept Terms');
      expect(isPolicyScrolledToEnd(0, 0), isTrue);
      expect(isPolicyScrolledToEnd(98, 100), isTrue);
      expect(isPolicyScrolledToEnd(10, 100), isFalse);
    });
  });

  group('policy html', () {
    test('blocks, spans and lists', () {
      final blocks = parsePolicyHtml(
          '<h1>Terms</h1><p>Hello <strong>bold</strong> and <em>soft</em> <a href="https://x.test/a">link</a>.</p>'
          '<ul><li>one</li><li>two</li></ul><ol><li>first</li><li>second</li></ol>');
      expect(blocks[0].kind, PolicyBlockKind.heading);
      expect(blocks[0].level, 1);
      expect(blocks[0].text, 'Terms');
      final p = blocks[1];
      expect(p.text, 'Hello bold and soft link.');
      expect(p.spans.any((s) => s.bold && s.text == 'bold'), isTrue);
      expect(p.spans.any((s) => s.italic && s.text == 'soft'), isTrue);
      expect(p.spans.singleWhere((s) => s.href != null).href, 'https://x.test/a');
      expect(blocks.where((b) => b.kind == PolicyBlockKind.listItem).map((b) => b.marker),
          ['•', '•', '1.', '2.']);
    });

    test('unsafe links and active content are dropped', () {
      final blocks = parsePolicyHtml(
          '<p><a href="javascript:alert(1)">bad</a><script>alert(1)</script><style>p{}</style> ok</p>');
      expect(blocks.single.text, 'bad ok');
      expect(blocks.single.spans.where((s) => s.href != null), isEmpty);
    });

    test('entities decode and whitespace collapses', () {
      expect(policyPlainText('<p>A &amp;\n  B &lt;c&gt; &ldquo;q&rdquo; &#233;</p>'), 'A & B <c> “q” é');
    });

    test('nested lists indent, rules and quotes become blocks', () {
      final blocks = parsePolicyHtml('<ul><li>a<ul><li>b</li></ul></li></ul><hr><blockquote><p>quoted</p></blockquote>');
      expect(blocks.where((b) => b.kind == PolicyBlockKind.listItem).map((b) => b.depth), [0, 1]);
      expect(blocks.any((b) => b.kind == PolicyBlockKind.rule), isTrue);
      expect(blocks.last.kind, PolicyBlockKind.quote);
    });

    test('unknown tags are transparent and stray angles are text', () {
      expect(policyPlainText('<section><blink>keep</blink> this</section>'), 'keep this');
      expect(policyPlainText('<p>1 < 2'), '1 < 2');
      expect(policyPlainText(''), '');
    });

    test('markdown fallback escapes everything', () {
      final html = policyMarkdownToSafeHtml('# Title\n\nHi <script>x</script> **b** [l](https://a.b/c)\n\n- one\n- two');
      expect(html, isNot(contains('<script>')));
      expect(html, contains('<h1>Title</h1>'));
      expect(html, contains('<strong>b</strong>'));
      expect(html, contains('<a href="https://a.b/c">l</a>'));
      expect(policyPlainText(html), 'Title\nHi <script>x</script> b l\n• one\n• two');
    });
  });
}
