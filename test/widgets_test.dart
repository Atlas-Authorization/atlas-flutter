import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_transport.dart';

const _sessionJson =
    '{"object":"session","id":"sess_1","jwt":"jwt_final","expires_in":60}';
const _rtCookie = {'set-cookie': '__atlas_rt=rt_final; Path=/v1; HttpOnly'};
const _userJson =
    '{"object":"user","id":"user_1","first_name":"Ada","last_name":"Lovelace",'
    '"email_addresses":[{"object":"email_address","id":"e1","email_address":"ada@example.com","verified":true,"primary":true}]}';

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

  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)),
      );

  testWidgets('AtlasSignIn drives identifier → password → done', (tester) async {
    transport
      ..enqueue(201,
          '{"id":"sia_1","status":"needs_first_factor","supported_first_factors":["password"]}')
      ..enqueue(200, '{"id":"sia_1","status":"complete","ticket":"tk_1"}')
      ..enqueue(200, _sessionJson, headers: _rtCookie)
      ..enqueue(200, _userJson);

    final client = makeClient();
    final session = AtlasAuthState(client);
    AtlasUser? completed;

    await tester.pumpWidget(wrap(AtlasSignIn(
      client: client,
      session: session,
      onComplete: (u) => completed = u,
    )));

    // Identifier step.
    expect(find.byKey(const Key('atlas.identifier')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('atlas.identifier')), 'ada@example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    // Password step appears.
    expect(find.byKey(const Key('atlas.password')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('atlas.password')), 'hunter2');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    // Completed: callback fired and session adopted the user.
    expect(completed, isNotNull);
    expect(completed!.id, 'user_1');
    expect(session.user?.id, 'user_1');
    expect(session.isSignedIn, isTrue);
  });

  testWidgets('AtlasSignIn shows an error banner on a bad password',
      (tester) async {
    transport
      ..enqueue(201,
          '{"id":"sia_1","status":"needs_first_factor","supported_first_factors":["password"]}')
      ..enqueue(422,
          '{"errors":[{"code":"form_password_incorrect","message":"Incorrect password.","param":"password"}]}');

    final client = makeClient();
    await tester.pumpWidget(wrap(AtlasSignIn(client: client)));

    await tester.enterText(find.byKey(const Key('atlas.identifier')), 'ada@example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('atlas.password')), 'wrong');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('atlas.error')), findsOneWidget);
    expect(find.text('Incorrect password.'), findsOneWidget);
  });

  testWidgets('AtlasUserButton shows initials when signed in and a chip when out',
      (tester) async {
    final client = makeClient();
    final session = AtlasAuthState(client);

    await tester.pumpWidget(wrap(AtlasUserButton(session: session)));
    // Signed out initially.
    expect(find.byKey(const Key('atlas.signed_out')), findsOneWidget);

    session.setUser(AtlasUser.fromJson({
      'id': 'user_1',
      'first_name': 'Ada',
      'last_name': 'Lovelace',
    }));
    await tester.pump();

    expect(find.byKey(const Key('atlas.user_button')), findsOneWidget);
    expect(find.text('AL'), findsOneWidget); // initials
  });

  testWidgets('AtlasUserButton signs out through the session', (tester) async {
    // Seed a session so signOut has something to revoke.
    store = InMemoryTokenStore(
      const AtlasSession(sessionId: 'sess_1', token: 'jwt', refreshToken: 'rt'),
    );
    transport.enqueue(200, '{"object":"session","id":"sess_1","status":"revoked"}');

    final client = makeClient();
    final session = AtlasAuthState(client);
    session.setUser(AtlasUser.fromJson({'id': 'user_1', 'first_name': 'Ada'}));

    var signedOutCalled = false;
    await tester.pumpWidget(wrap(AtlasUserButton(
      session: session,
      onSignedOut: () => signedOutCalled = true,
    )));

    await tester.tap(find.byKey(const Key('atlas.user_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(signedOutCalled, isTrue);
    expect(session.isSignedIn, isFalse);
    expect(find.byKey(const Key('atlas.signed_out')), findsOneWidget);
  });
}
