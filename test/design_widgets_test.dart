import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_test.dart' show fullResolved, emailUndeliverable, emailUndeliverableMessage;
import 'mock_transport.dart';

const _designBundle = '{"object":"appearance","design":{"scope":".atlas-root","css":"",'
    '"resolved":$fullResolved,"logo_url":null,"logo_dark_url":null},"providers":["google","github"]}';

void main() {
  late MockTransport transport;

  setUp(() => transport = MockTransport());

  AtlasClient makeClient() => AtlasClient(
        publishableKey: pk,
        frontendApi: frontendApi,
        tokenStore: InMemoryTokenStore(),
        httpClient: transport.client(),
      );

  final appTheme = ThemeData(useMaterial3: true, colorSchemeSeed: Colors.deepPurple);

  Widget wrap(Widget child) => MaterialApp(
        theme: appTheme,
        home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)),
      );

  Color? fillOf(WidgetTester tester, Finder button) {
    final ctx = tester.element(button);
    final widget = tester.widget<FilledButton>(button);
    final resolved = widget.style?.backgroundColor ?? Theme.of(ctx).filledButtonTheme.style?.backgroundColor;
    return resolved?.resolve(<WidgetState>{});
  }

  testWidgets('design: null keeps the ambient-Theme look exactly', (tester) async {
    await tester.pumpWidget(wrap(AtlasSignIn(client: makeClient())));
    await tester.pumpAndSettle();

    expect(transport.appearanceRequests, hasLength(1));
    expect(find.byKey(const Key('atlas.card')), findsNothing);
    expect(find.byKey(const Key('atlas.logo')), findsNothing);
    final button = find.widgetWithText(FilledButton, 'Continue');
    expect(button, findsOneWidget);
    expect(tester.widget<FilledButton>(button).style, isNull);
    // No Theme override above the form: the app's theme reaches the button.
    final ctx = tester.element(button);
    expect(Theme.of(ctx).colorScheme.primary, appTheme.colorScheme.primary);
    expect(Theme.of(ctx).filledButtonTheme.style, isNull);
    final title = tester.widget<Text>(find.text('Sign in'));
    expect(title.style, Theme.of(tester.element(find.byType(Scaffold))).textTheme.headlineSmall);
  });

  testWidgets('a dashboard design is applied (light)', (tester) async {
    transport.appearanceJson = _designBundle.replaceFirst('"colorScheme":"dark"', '"colorScheme":"light"');
    await tester.pumpWidget(wrap(AtlasSignIn(client: makeClient())));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('atlas.card')), findsOneWidget);
    // Uppercase button labels.
    final button = find.widgetWithText(FilledButton, 'CONTINUE');
    expect(button, findsOneWidget);
    final ctx = tester.element(button);
    final theme = Theme.of(ctx);
    expect(theme.colorScheme.primary, const Color(0xFF0F766E));
    expect(theme.inputDecorationTheme.enabledBorder, isA<UnderlineInputBorder>());
    final title = tester.widget<Text>(find.text('Sign in'));
    expect(Theme.of(tester.element(find.text('Sign in'))).textTheme.headlineSmall?.fontSize,
        closeTo(17 * 1.618, 0.001));
    expect(title.style?.fontFamily, 'Playfair Display');
    final card = tester.widget<Container>(find.byKey(const Key('atlas.card')));
    expect((card.decoration as BoxDecoration).color, const Color(0xFFFFFFFF).withValues(alpha: 0.72));
  });

  testWidgets('dark palette under platform dark mode (auto)', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    transport.appearanceJson = _designBundle.replaceFirst('"colorScheme":"dark"', '"colorScheme":"auto"');
    await tester.pumpWidget(wrap(AtlasSignIn(client: makeClient())));
    await tester.pumpAndSettle();

    final theme = Theme.of(tester.element(find.widgetWithText(FilledButton, 'CONTINUE')));
    expect(theme.colorScheme.primary, const Color(0xFF2DD4BF));
    expect(theme.colorScheme.brightness, Brightness.dark);
  });

  testWidgets('the code-level appearance wins over the dashboard', (tester) async {
    transport.appearanceJson = _designBundle.replaceFirst('"colorScheme":"dark"', '"colorScheme":"light"');
    await tester.pumpWidget(wrap(AtlasSignIn(
      client: makeClient(),
      appearance: const AtlasAppearance(
        palette: {AtlasPaletteSlot.primary: '#ff0000'},
        buttonStyle: AtlasButtonStyle.solid,
        letterCase: AtlasLetterCase.none,
      ),
    )));
    await tester.pumpAndSettle();

    final button = find.widgetWithText(FilledButton, 'Continue');
    expect(button, findsOneWidget);
    expect(fillOf(tester, button), const Color(0xFFFF0000));
  });

  testWidgets('an appearance alone styles the form even with no dashboard design', (tester) async {
    await tester.pumpWidget(wrap(AtlasSignIn(
      client: makeClient(),
      appearance: const AtlasAppearance(palette: {AtlasPaletteSlot.primary: '#00ff00'}),
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('atlas.card')), findsOneWidget);
    expect(fillOf(tester, find.widgetWithText(FilledButton, 'Continue')), const Color(0xFF00FF00));
  });

  testWidgets('social buttons follow the layout and report the provider', (tester) async {
    final semantics = tester.ensureSemantics();
    transport.appearanceJson = _designBundle;
    String? picked;
    await tester.pumpWidget(wrap(AtlasSignIn(client: makeClient(), onSocialSignIn: (p) => picked = p)));
    await tester.pumpAndSettle();

    // `icons` layout: one-letter buttons with a full semantic label.
    expect(find.byKey(const Key('atlas.social.google')), findsOneWidget);
    expect(find.byKey(const Key('atlas.social.github')), findsOneWidget);
    expect(find.bySemanticsLabel('Continue with GitHub'), findsOneWidget);
    await tester.tap(find.byKey(const Key('atlas.social.github')));
    expect(picked, 'github');
    semantics.dispose();
  });

  testWidgets('no social buttons without onSocialSignIn', (tester) async {
    transport.appearanceJson = _designBundle;
    await tester.pumpWidget(wrap(AtlasSignIn(client: makeClient())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('atlas.social.google')), findsNothing);
  });

  testWidgets('the logo renders from logo_url', (tester) async {
    transport.appearanceJson =
        _designBundle.replaceFirst('"logo_url":null', '"logo_url":"https://cdn.example.com/logo.png"');
    await tester.pumpWidget(wrap(AtlasSignIn(client: makeClient())));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('atlas.logo')), findsOneWidget);
  });

  testWidgets('a pre-fetched appearanceInfo skips the fetch', (tester) async {
    await tester.pumpWidget(wrap(AtlasSignIn(
      client: makeClient(),
      appearanceInfo: const AtlasAppearanceInfo(),
    )));
    await tester.pumpAndSettle();
    expect(transport.appearanceRequests, isEmpty);
    expect(find.byKey(const Key('atlas.card')), findsNothing);
  });

  testWidgets('a failed appearance fetch keeps the default look silently', (tester) async {
    transport.appearanceStatus = 500;
    await tester.pumpWidget(wrap(AtlasSignIn(client: makeClient())));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('atlas.card')), findsNothing);
    expect(find.byKey(const Key('atlas.error')), findsNothing);
  });

  testWidgets('EMAIL_DELIVERY_NOT_CONFIGURED shows the server message and withdraws email',
      (tester) async {
    transport
      ..enqueue(201, '{"id":"sia_1","status":"needs_first_factor","supported_first_factors":["email_code"]}')
      ..enqueue(422, emailUndeliverable);

    await tester.pumpWidget(wrap(AtlasSignIn(client: makeClient())));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('atlas.identifier')), 'ada@example.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Email me a code'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('atlas.error')), findsOneWidget);
    expect(find.text(emailUndeliverableMessage), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Email me a code'), findsNothing);
  });
}
