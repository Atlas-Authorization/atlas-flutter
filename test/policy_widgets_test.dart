import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_transport.dart';

AtlasPolicy _policy(String key, {String display = 'checkbox', String html = '<p>Terms</p>', bool? reaccept, String? summary}) =>
    AtlasPolicy(
      key: key,
      title: key.toUpperCase(),
      display: display,
      versionId: 'polv_$key',
      version: '1',
      contentHtml: html,
      contentSha256: 'sha_$key',
      reaccept: reaccept,
      summaryOfChanges: summary,
    );

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: child))));

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

  testWidgets('combined checkbox ticks every checkbox policy and the title opens the viewer', (tester) async {
    final c = PolicyAcceptanceController([
      _policy('tos', html: '<h2>Heading</h2><p>Body text</p>'),
      _policy('privacy'),
    ]);
    await tester.pumpWidget(_wrap(AtlasPolicyConsent(controller: c)));
    expect(find.byKey(const Key('atlas.policy_consent')), findsOneWidget);
    expect(c.canSubmit(), isFalse);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(c.canSubmit(), isTrue);
    expect(c.combinedChecked, isTrue);

    // Tapping a title opens the document in the in-app viewer.
    await tester.tapOnText(find.textRange.ofSubstring('TOS'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('atlas.policy_viewer')), findsOneWidget);
    expect(find.text('Body text'), findsOneWidget);
    await tester.tap(find.byKey(const Key('atlas.policy_viewer_back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('atlas.policy_viewer')), findsNothing);
    expect(c.viewing, isNull);
  });

  testWidgets('separate mode shows one box per policy', (tester) async {
    final c = PolicyAcceptanceController([_policy('tos'), _policy('privacy')], combined: false);
    await tester.pumpWidget(_wrap(AtlasPolicyConsent(controller: c)));
    expect(find.byType(Checkbox), findsNWidgets(2));
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(c.isChecked('tos'), isTrue);
    expect(c.isChecked('privacy'), isFalse);
  });

  testWidgets('clickwrap draws only link policies', (tester) async {
    final c = PolicyAcceptanceController([_policy('tos'), _policy('cookies', display: 'link')]);
    await tester.pumpWidget(_wrap(AtlasPolicyClickwrap(controller: c)));
    expect(find.byKey(const Key('atlas.policy_clickwrap')), findsOneWidget);
    expect(find.textContaining('By continuing you agree to the COOKIES.', findRichText: true), findsOneWidget);
    await tester.pumpWidget(_wrap(AtlasPolicyClickwrap(controller: PolicyAcceptanceController([_policy('tos')]))));
    expect(find.byKey(const Key('atlas.policy_clickwrap')), findsNothing);
  });

  testWidgets('the scroll dialog cannot be dismissed and Accept waits for the end', (tester) async {
    final long = List.generate(60, (i) => '<p>Paragraph number $i of the agreement.</p>').join();
    final c = PolicyAcceptanceController([_policy('tos', display: 'scroll', html: long)]);
    AtlasPolicy? declined = _policy('x');
    await tester.pumpWidget(_wrap(Builder(
      builder: (context) => FilledButton(
        onPressed: () async => declined = await runScrollPolicies(context, c),
        child: const Text('go'),
      ),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('atlas.policy_dialog')), findsOneWidget);
    FilledButton accept() => tester.widget<FilledButton>(find.byKey(const Key('atlas.policy_accept')));
    expect(accept().onPressed, isNull);
    expect(find.text('Scroll to the end to accept'), findsOneWidget);

    // Back / outside taps do not dismiss it.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('atlas.policy_dialog')), findsOneWidget);

    await tester.drag(find.byKey(const Key('atlas.policy_scroll')), const Offset(0, -20000));
    await tester.pumpAndSettle();
    expect(accept().onPressed, isNotNull);
    expect(c.hasScrolledToEnd('tos'), isTrue);

    await tester.tap(find.byKey(const Key('atlas.policy_accept')));
    await tester.pumpAndSettle();
    expect(declined, isNull);
    expect(c.isChecked('tos'), isTrue);
    expect(c.build().single.scrolledToEnd, isTrue);
  });

  testWidgets('text that fits enables Accept at once, and Decline cancels', (tester) async {
    final c = PolicyAcceptanceController([_policy('tos', display: 'scroll', html: '<p>Short.</p>')]);
    AtlasPolicy? declined;
    await tester.pumpWidget(_wrap(Builder(
      builder: (context) => FilledButton(
        onPressed: () async => declined = await runScrollPolicies(context, c),
        child: const Text('go'),
      ),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('atlas.policy_accept'))).onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('atlas.policy_decline')));
    await tester.pumpAndSettle();
    expect(declined?.key, 'tos');
    expect(c.isChecked('tos'), isFalse);
  });

  testWidgets('a re-acceptance dialog shows what changed', (tester) async {
    final c = PolicyAcceptanceController([_policy('tos', display: 'scroll', reaccept: true, summary: 'New arbitration clause')]);
    await tester.pumpWidget(_wrap(Builder(
      builder: (context) => FilledButton(onPressed: () => runScrollPolicies(context, c), child: const Text('go')),
    )));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('What changed'), findsOneWidget);
    expect(find.text('New arbitration clause'), findsOneWidget);
    expect(find.text('TOS has been updated'), findsOneWidget);
  });

  testWidgets('AtlasSignIn shows the accept step for a held attempt and finishes', (tester) async {
    transport
      ..enqueue(201, '{"id":"sia_1","status":"needs_first_factor","supported_first_factors":["password"]}')
      ..enqueue(
          200,
          '{"id":"sia_1","status":"needs_policy_acceptance","policy_acceptance_token":"pat_1",'
          '"pending_policies":[{"policy":"tos","title":"Terms","display":"checkbox","version_id":"polv_1","version":"2","content_sha256":"h"}]}')
      ..enqueue(
          200,
          '{"object":"list","data":[{"object":"policy","key":"tos","title":"Terms","display":"checkbox","required":true,'
          '"version_id":"polv_1","version":"2","content_html":"<p>Hi</p>","content_sha256":"h"}]}')
      ..enqueue(200, '{"id":"sia_1","status":"complete","ticket":"tk_1"}')
      ..enqueue(200, '{"object":"session","id":"sess_1","jwt":"jwt_final","expires_in":60}',
          headers: {'set-cookie': '__atlas_rt=rt_final; Path=/v1; HttpOnly'})
      ..enqueue(200, '{"object":"user","id":"user_1"}');
    final client = makeClient();
    AtlasUser? done;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: AtlasSignIn(client: client, onComplete: (u) => done = u))),
    ));
    await tester.enterText(find.byKey(const Key('atlas.identifier')), 'a@b.co');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('atlas.password')), 'pw');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('atlas.policy_step')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('atlas.policy_submit'))).onPressed, isNull);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.byKey(const Key('atlas.policy_submit')));
    await tester.pumpAndSettle();

    expect(done?.id, 'user_1');
    expect(transport.pathAt(3), '/v1/client/sign_ins/sia_1/accept_policies');
    expect(transport.bodyAt(3)['policy_acceptance_token'], 'pat_1');
  });

  testWidgets('declining the held step returns to the first step with the reason', (tester) async {
    transport
      ..enqueue(201, '{"id":"sia_1","status":"needs_first_factor","supported_first_factors":["password"]}')
      ..enqueue(
          200,
          '{"id":"sia_1","status":"needs_policy_acceptance","policy_acceptance_token":"pat_1",'
          '"pending_policies":[{"policy":"tos","title":"Terms","display":"checkbox","version_id":"polv_1","version":"2","content_sha256":"h","content_html":"<p>x</p>"}]}');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: AtlasSignIn(client: makeClient()))),
    ));
    await tester.enterText(find.byKey(const Key('atlas.identifier')), 'a@b.co');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('atlas.password')), 'pw');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('atlas.policy_step_decline')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('atlas.identifier')), findsOneWidget);
    expect(find.text('You need to accept the Terms to use this app.'), findsOneWidget);
  });

  testWidgets('the gate banner shows stale policies, re-accepts and disappears', (tester) async {
    final s = InMemoryTokenStore();
    s.save(const AtlasSession(sessionId: 's', token: 'j', refreshToken: 'rt'));
    final client = makeClient(s);
    transport
      ..enqueue(200, '{"data":[{"policy":"tos","title":"Terms","needs_reaccept":true,"grace_ends_at":1792800000000}]}')
      ..enqueue(
          200,
          '{"data":[{"object":"policy","key":"tos","title":"Terms","display":"checkbox","required":true,'
          '"version_id":"polv_2","version":"2","content_html":"<p>Hi</p>","content_sha256":"h"}]}')
      ..enqueue(200, '{}')
      ..enqueue(200, '{"data":[{"policy":"tos","title":"Terms","needs_reaccept":false}]}');
    var accepted = false;
    await tester.pumpWidget(_wrap(AtlasPolicyGate(client: client, onAccepted: () => accepted = true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('atlas.policy_gate')), findsOneWidget);
    expect(find.text('We have updated: Terms. Please review and accept.'), findsOneWidget);
    expect(find.text('Accept by 2026-10-24 to keep your access.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('atlas.policy_gate_review')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.byKey(const Key('atlas.policy_submit')));
    await tester.pumpAndSettle();

    expect(accepted, isTrue);
    expect(transport.pathAt(2), '/v1/client/me/policies/accept');
    expect(find.byKey(const Key('atlas.policy_gate')), findsNothing);
  });

  testWidgets('the gate draws nothing when nothing needs accepting', (tester) async {
    final s = InMemoryTokenStore();
    s.save(const AtlasSession(sessionId: 's', token: 'j', refreshToken: 'rt'));
    transport.enqueue(200, '{"data":[{"policy":"tos","title":"Terms","needs_reaccept":false}]}');
    await tester.pumpWidget(_wrap(AtlasPolicyGate(client: makeClient(s))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('atlas.policy_gate')), findsNothing);
  });
}
