import 'dart:convert';

import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_transport.dart';

const fullResolved = '''
{"version":1,"preset":"midnight","colorScheme":"dark",
 "palette":{"primary":"#0F766E","primaryInk":"#ffffff","accent":"#f59e0b","background":"#f8fafc","surface":"#ffffff","text":"#0f172a","muted":"#64748b","border":"#e2e8f0","danger":"#b91c1c","success":"#15803d","inputBackground":"#ffffff","inputText":"#0f172a"},
 "paletteDark":{"primary":"#2dd4bf","primaryInk":"#042f2e","accent":"#fbbf24","background":"#020617","surface":"#0f172a","text":"#f8fafc","muted":"#94a3b8","border":"#1e293b","danger":"#f87171","success":"#4ade80","inputBackground":"#020617","inputText":"#f8fafc"},
 "typography":{"font":"source-serif","headingFont":"playfair-display","baseSize":17,"headingWeight":700,"bodyWeight":300,"letterCase":"uppercase","scale":"golden"},
 "shape":{"radius":20,"controlRadius":999,"borderWidth":2},
 "elevation":{"cardShadow":"xl"},"spacing":{"density":"spacious"},
 "card":{"style":"glass","blur":24,"width":"wide"},
 "layout":{"position":"split","logoSize":"lg"},
 "buttons":{"style":"gradient","socialLayout":"icons"},"inputs":{"style":"underline"},
 "background":{},"backgroundDark":{},"logo":{}}
''';

Map<String, dynamic> obj(String s) => jsonDecode(s) as Map<String, dynamic>;

void main() {
  group('decoding', () {
    test('a full resolved design', () {
      final d = AtlasDesign.fromResolved(obj(fullResolved));
      expect(d.colorScheme, AtlasColorScheme.dark);
      expect(d.palette[AtlasPaletteSlot.primary], '#0f766e');
      expect(d.paletteDark[AtlasPaletteSlot.primaryInk], '#042f2e');
      expect(d.typography.font, 'source-serif');
      expect(d.typography.headingFont, 'playfair-display');
      expect(d.typography.baseSize, 17);
      expect(d.typography.headingWeight, 700);
      expect(d.typography.bodyWeight, 300);
      expect(d.typography.letterCase, AtlasLetterCase.uppercase);
      expect(d.typography.headingSize, closeTo(17 * 1.618, 0.001));
      expect(d.radius, 20);
      expect(d.isPill, isTrue);
      expect(d.borderWidth, 2);
      expect(d.cardShadow, AtlasCardShadow.xl);
      expect(d.spacing.control, 46);
      expect(d.cardStyle, AtlasCardStyle.glass);
      expect(d.cardMaxWidth, 460);
      expect(d.logoHeight, 64);
      expect(d.buttonStyle, AtlasButtonStyle.gradient);
      expect(d.socialLayout, AtlasSocialLayout.icons);
      expect(d.inputStyle, AtlasInputStyle.underline);
    });

    test('a partial design fills defaults and ignores unknown keys', () {
      final d = AtlasDesign.fromResolved(obj('''
        {"palette":{"primary":"#123456","bogus":"#ffffff"},
         "typography":{"font":"roboto","baseSize":99,"letterCase":"shouty"},
         "shape":{"radius":"12px"},"buttons":{"style":"neon"},"futureSection":{"x":1}}'''));
      final defaults = AtlasDesign.defaults;
      expect(d.palette[AtlasPaletteSlot.primary], '#123456');
      expect(d.palette[AtlasPaletteSlot.surface], defaults.palette[AtlasPaletteSlot.surface]);
      expect(d.paletteDark, defaults.paletteDark);
      expect(d.typography.font, 'roboto');
      expect(d.typography.headingFont, 'roboto');
      expect(d.typography.baseSize, 15);
      expect(d.typography.letterCase, AtlasLetterCase.none);
      expect(d.radius, 12);
      expect(d.buttonStyle, AtlasButtonStyle.solid);
    });

    test('an empty resolved object is the defaults', () {
      expect(AtlasDesign.fromResolved(const {}), AtlasDesign.defaults);
    });

    test('a null design decodes to null', () {
      final info = AtlasAppearanceInfo.fromJson(
          obj('{"object":"appearance","design":null,"providers":["google","github"]}'));
      expect(info.design, isNull);
      expect(info.providers, ['google', 'github']);
      expect(AtlasAppearanceInfo.fromJson(obj('{"object":"appearance"}')).design, isNull);
    });

    test('the bundle carries the logo urls', () {
      final d = AtlasDesign.fromBundle(obj(
          '{"resolved":{},"logo_url":"https://cdn.example.com/l.png","logo_dark_url":"https://cdn.example.com/d.png"}'))!;
      expect(d.logo(platformIsDark: false), 'https://cdn.example.com/l.png');
      expect(d.logo(platformIsDark: true), 'https://cdn.example.com/d.png');
    });
  });

  group('colours + dark mode', () {
    test('auto follows the platform, forced schemes do not', () {
      final d = AtlasDesign.fromResolved(
          obj('{"palette":{"primary":"#111111"},"paletteDark":{"primary":"#eeeeee"}}'));
      expect(d.activePalette(platformIsDark: false)[AtlasPaletteSlot.primary], '#111111');
      expect(d.activePalette(platformIsDark: true)[AtlasPaletteSlot.primary], '#eeeeee');
      expect(d.copyWith(colorScheme: AtlasColorScheme.dark).activePalette(platformIsDark: false), d.paletteDark);
      expect(d.copyWith(colorScheme: AtlasColorScheme.light).activePalette(platformIsDark: true), d.palette);
    });

    test('hex maps to Flutter colours', () {
      expect(atlasColor('#ff8000'), const Color(0xFFFF8000));
      expect(atlasColor('orange'), const Color(0x00000000));
      final dark = AtlasDesignStyle(AtlasDesign.defaults, platformIsDark: true);
      expect(dark.color(AtlasPaletteSlot.surface), const Color(0xFF18181B));
      final light = AtlasDesignStyle(AtlasDesign.defaults, platformIsDark: false);
      expect(light.color(AtlasPaletteSlot.surface), const Color(0xFFFFFFFF));
      expect(AtlasHex.readableOn('#ffffff'), '#111827');
      expect(AtlasHex.readableOn('#18181b'), '#ffffff');
    });

    test('pill radius is half the control height; shadow follows the card style', () {
      final d = AtlasDesign.defaults.copyWith(controlRadius: 999);
      final style = AtlasDesignStyle(d, platformIsDark: false);
      expect(style.controlRadius, BorderRadius.circular(20));
      expect(d.shadow?.y, 12);
      expect(d.copyWith(cardStyle: AtlasCardStyle.outline).shadow, isNull);
      expect(d.copyWith(cardStyle: AtlasCardStyle.outline).cardBorderWidth, 1);
      expect(d.copyWith(cardStyle: AtlasCardStyle.none).cardBorderWidth, 0);
    });

    test('fonts use the catalog family with a same-category fallback', () {
      final d = AtlasDesign.fromResolved(obj(fullResolved));
      final style = AtlasDesignStyle(d, platformIsDark: false, fonts: const {'playfair-display': 'MyPlayfair'});
      expect(style.body.fontFamily, 'Source Serif 4');
      expect(style.body.fontFamilyFallback, contains('serif'));
      expect(style.body.fontWeight, FontWeight.w300);
      expect(style.heading.fontFamily, 'MyPlayfair');
      expect(style.heading.fontWeight, FontWeight.w700);
      expect(style.label('Continue'), 'CONTINUE');
    });
  });

  group('precedence', () {
    test('no design and no override means the unchanged look', () {
      expect(AtlasDesign.resolve(null, null), isNull);
      expect(AtlasDesign.resolve(null, const AtlasAppearance()), isNull);
    });

    test('the dashboard design applies without an override', () {
      final dash = AtlasDesign.fromResolved(obj(fullResolved));
      expect(AtlasDesign.resolve(dash, null), dash);
      expect(AtlasDesign.resolve(dash, const AtlasAppearance()), dash);
    });

    test('a code override wins over the dashboard', () {
      final dash = AtlasDesign.fromResolved(obj(fullResolved));
      final d = AtlasDesign.resolve(
        dash,
        const AtlasAppearance(
          palette: {AtlasPaletteSlot.primary: '#FF0000'},
          controlRadius: 4,
          buttonStyle: AtlasButtonStyle.outline,
          colorScheme: AtlasColorScheme.light,
        ),
      )!;
      expect(d.palette[AtlasPaletteSlot.primary], '#ff0000');
      expect(d.palette[AtlasPaletteSlot.primaryInk], '#111827');
      expect(d.paletteDark[AtlasPaletteSlot.primary], '#ff0000');
      expect(d.controlRadius, 4);
      expect(d.buttonStyle, AtlasButtonStyle.outline);
      expect(d.colorScheme, AtlasColorScheme.light);
      expect(d.typography.font, 'source-serif');
      expect(d.inputStyle, AtlasInputStyle.underline);
    });

    test('an override alone layers over the defaults; opting out works', () {
      final d = AtlasDesign.resolve(null, const AtlasAppearance(density: AtlasDensity.compact))!;
      expect(d.density, AtlasDensity.compact);
      expect(d.palette, AtlasDesign.defaults.palette);
      final dash = AtlasDesign.fromResolved(obj(fullResolved));
      expect(AtlasDesign.resolve(dash, const AtlasAppearance(applyDashboardDesign: false)), isNull);
      expect(
        AtlasDesign.resolve(
                dash, const AtlasAppearance(applyDashboardDesign: false, inputStyle: AtlasInputStyle.filled))!
            .palette,
        AtlasDesign.defaults.palette,
      );
    });

    test('invalid override values are ignored', () {
      final d = AtlasDesign.resolve(
        null,
        const AtlasAppearance(palette: {AtlasPaletteSlot.primary: 'blue'}, baseSize: 400, font: 'comic-sans'),
      )!;
      expect(d.palette[AtlasPaletteSlot.primary], AtlasDesign.defaults.palette[AtlasPaletteSlot.primary]);
      expect(d.typography.baseSize, 15);
      expect(d.typography.font, 'inter');
    });
  });

  group('fetching', () {
    late MockTransport transport;
    AtlasClient makeClient() => AtlasClient(
          publishableKey: pk,
          frontendApi: frontendApi,
          tokenStore: InMemoryTokenStore(),
          httpClient: transport.client(),
        );

    setUp(() => transport = MockTransport());

    test('GET /v1/appearance with the publishable key, cached per client', () async {
      transport.appearanceJson =
          '{"object":"appearance","design":{"resolved":{"buttons":{"style":"soft"}},"logo_url":null},"providers":["google"]}';
      final client = makeClient();
      final info = await client.appearance();
      final request = transport.appearanceRequests.single;
      expect(request.url.toString(), 'https://clerk.example.com/v1/appearance');
      expect(request.headers['x-publishable-key'], pk);
      expect(info.design?.buttonStyle, AtlasButtonStyle.soft);
      expect(info.design?.logoUrl, isNull);
      expect(info.providers, ['google']);

      await client.appearance();
      expect(transport.appearanceRequests, hasLength(1), reason: 'cached');
      await client.appearance(refresh: true);
      await client.appearance(organization: 'acme');
      expect(transport.appearanceRequests, hasLength(3));
      expect(transport.appearanceRequests.last.url.queryParameters['org'], 'acme');
    });

    test('a null design', () async {
      final info = await makeClient().appearance();
      expect(info.design, isNull);
    });

    test('a failed fetch is not cached', () async {
      transport.appearanceStatus = 500;
      final client = makeClient();
      await expectLater(client.appearance(), throwsA(isA<AtlasException>()));
      transport.appearanceStatus = 200;
      expect((await client.appearance()).design, isNull);
      expect(transport.appearanceRequests, hasLength(2));
    });
  });

  group('EMAIL_DELIVERY_NOT_CONFIGURED', () {
    test('is typed and keeps the server message', () {
      final e = AtlasException.fromResponse(422, emailUndeliverable);
      expect(e.status, 422);
      expect(e.knownCode, AtlasErrorCode.emailDeliveryNotConfigured);
      expect(e.isEmailDeliveryNotConfigured, isTrue);
      expect(e.message, emailUndeliverableMessage);
      final other = AtlasException.fromResponse(400, '{"errors":[{"code":"SOMETHING_NEW","message":"x"}]}');
      expect(other.knownCode, isNull);
      expect(other.isEmailDeliveryNotConfigured, isFalse);
      expect(AtlasException.transport('offline').knownCode, isNull);
    });
  });
}

const emailUndeliverableMessage =
    "This app can't send email right now. Try another sign-in method or contact the app owner.";
const emailUndeliverable =
    '{"errors":[{"code":"EMAIL_DELIVERY_NOT_CONFIGURED","message":"$emailUndeliverableMessage","meta":{"fix":"Configure an email provider first."}}]}';
