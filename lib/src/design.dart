import 'dart:math' as math;

// The dashboard design, as a native app sees it.
//
// `GET /v1/appearance` returns `design` — `null` until the app owner saves a
// design in the dashboard — whose `resolved` member is the fully-resolved
// design the hosted pages and web components render. This file is the
// platform-neutral half: the model, a TOLERANT decoder (unknown keys ignored;
// missing, mistyped or out-of-range values fall back to the Atlas defaults),
// the code-level override ([AtlasAppearance]) and the precedence rules.
// `widgets/design_style.dart` maps the result onto Flutter widgets.

/// `auto` follows the platform brightness; `light` / `dark` force one.
enum AtlasColorScheme { auto, light, dark }

enum AtlasLetterCase { none, uppercase }

enum AtlasCardShadow { none, sm, md, lg, xl }

enum AtlasDensity { compact, comfortable, spacious }

enum AtlasCardStyle { solid, glass, outline, none }

enum AtlasCardWidth { narrow, normal, wide }

enum AtlasLogoSize { sm, md, lg }

enum AtlasButtonStyle { solid, outline, soft, gradient }

enum AtlasSocialLayout { list, grid, icons }

enum AtlasInputStyle { outline, filled, underline }

/// The twelve palette slots, in the dashboard editor's order.
enum AtlasPaletteSlot {
  primary,
  primaryInk,
  accent,
  background,
  surface,
  text,
  muted,
  border,
  danger,
  success,
  inputBackground,
  inputText;

  /// Brand slots set in the light palette carry into dark mode (as on the web).
  static const brand = [primary, accent, danger, success];
}

T? _parseEnum<T extends Enum>(List<T> values, Object? raw) {
  if (raw is! String) return null;
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return null;
}

final _hex = RegExp(r'^#[0-9a-fA-F]{6}$');

/// `#rrggbb` helpers shared by the model and the widgets.
class AtlasHex {
  const AtlasHex._();

  static bool isValid(Object? s) => s is String && _hex.hasMatch(s);

  /// `0xRRGGBB`, or null when not a `#rrggbb` string.
  static int? rgb(Object? s) => isValid(s) ? int.parse((s as String).substring(1), radix: 16) : null;

  /// Near-black or white, whichever reads on [hex] (the WCAG 0.179 split) —
  /// the dashboard's rule for an unset `primaryInk`.
  static String readableOn(String hex) {
    final n = rgb(hex);
    if (n == null) return '#ffffff';
    double lin(int v) {
      final s = v / 255;
      return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
    }

    final l = 0.2126 * lin((n >> 16) & 0xff) + 0.7152 * lin((n >> 8) & 0xff) + 0.0722 * lin(n & 0xff);
    return l > 0.179 ? '#111827' : '#ffffff';
  }
}

/// One colour mode's palette: every slot is a lower-case `#rrggbb` string.
class AtlasPalette {
  const AtlasPalette(this.colors);

  factory AtlasPalette.fromSpec(String spec) {
    final parts = spec.split(' ');
    return AtlasPalette({
      for (var i = 0; i < AtlasPaletteSlot.values.length; i++) AtlasPaletteSlot.values[i]: parts[i],
    });
  }

  /// Tolerant: each valid `#rrggbb` slot in [json] replaces [fallback]'s.
  factory AtlasPalette.fromJson(Object? json, AtlasPalette fallback) {
    if (json is! Map) return fallback;
    return fallback.withColors({
      for (final slot in AtlasPaletteSlot.values)
        if (json[slot.name] is String) slot: json[slot.name] as String,
    });
  }

  final Map<AtlasPaletteSlot, String> colors;

  String operator [](AtlasPaletteSlot slot) => colors[slot] ?? '#000000';

  /// A copy with the valid `#rrggbb` entries of [over] applied.
  AtlasPalette withColors(Map<AtlasPaletteSlot, String> over) => AtlasPalette({
        ...colors,
        for (final e in over.entries)
          if (AtlasHex.isValid(e.value)) e.key: e.value.toLowerCase(),
      });

  @override
  bool operator ==(Object other) =>
      other is AtlasPalette &&
      AtlasPaletteSlot.values.every((s) => other[s] == this[s]);

  @override
  int get hashCode => Object.hashAll(AtlasPaletteSlot.values.map((s) => this[s]));
}

enum AtlasFontCategory { sansSerif, serif, monospace }

/// The curated font catalog (ids → family names), mirroring the dashboard's
/// list. A family renders when the app bundles it (pubspec `fonts:` with that
/// family name) or maps the id via `AtlasSignIn(fonts: …)`; otherwise Flutter
/// falls back to the platform font of the same category.
class AtlasFontCatalog {
  const AtlasFontCatalog._();

  static const Map<String, (String?, AtlasFontCategory)> families = {
    'system': (null, AtlasFontCategory.sansSerif),
    'system-serif': (null, AtlasFontCategory.serif),
    'system-mono': (null, AtlasFontCategory.monospace),
    'inter': ('Inter', AtlasFontCategory.sansSerif),
    'roboto': ('Roboto', AtlasFontCategory.sansSerif),
    'open-sans': ('Open Sans', AtlasFontCategory.sansSerif),
    'lato': ('Lato', AtlasFontCategory.sansSerif),
    'montserrat': ('Montserrat', AtlasFontCategory.sansSerif),
    'poppins': ('Poppins', AtlasFontCategory.sansSerif),
    'nunito': ('Nunito', AtlasFontCategory.sansSerif),
    'work-sans': ('Work Sans', AtlasFontCategory.sansSerif),
    'dm-sans': ('DM Sans', AtlasFontCategory.sansSerif),
    'manrope': ('Manrope', AtlasFontCategory.sansSerif),
    'source-serif': ('Source Serif 4', AtlasFontCategory.serif),
    'merriweather': ('Merriweather', AtlasFontCategory.serif),
    'playfair-display': ('Playfair Display', AtlasFontCategory.serif),
    'jetbrains-mono': ('JetBrains Mono', AtlasFontCategory.monospace),
    'ibm-plex-mono': ('IBM Plex Mono', AtlasFontCategory.monospace),
  };

  static bool isKnown(Object? id) => id is String && families.containsKey(id);
  static String? family(String id) => families[id]?.$1;
  static AtlasFontCategory category(String id) => families[id]?.$2 ?? AtlasFontCategory.sansSerif;
}

const Map<String, double> _typeScales = {
  'minor-second': 1.067,
  'major-second': 1.125,
  'minor-third': 1.2,
  'major-third': 1.25,
  'perfect-fourth': 1.333,
  'augmented-fourth': 1.414,
  'perfect-fifth': 1.5,
  'golden': 1.618,
  'minor-seventh': 1.778,
  'octave': 2,
};

class AtlasTypography {
  const AtlasTypography({
    required this.font,
    required this.headingFont,
    required this.baseSize,
    required this.headingWeight,
    required this.bodyWeight,
    required this.letterCase,
    required this.scale,
  });

  /// Font catalog ids.
  final String font;
  final String headingFont;

  /// Body text size in logical pixels (12…20).
  final int baseSize;
  final int headingWeight;
  final int bodyWeight;

  /// Letter case of BUTTON labels.
  final AtlasLetterCase letterCase;
  final String scale;

  /// Heading size = base × the type-scale ratio.
  double get headingSize => baseSize * (_typeScales[scale] ?? 1.333);
  double get smallSize => (baseSize * 0.867 * 10).round() / 10;

  AtlasTypography copyWith({
    String? font,
    String? headingFont,
    int? baseSize,
    int? headingWeight,
    int? bodyWeight,
    AtlasLetterCase? letterCase,
    String? scale,
  }) =>
      AtlasTypography(
        font: font ?? this.font,
        headingFont: headingFont ?? this.headingFont,
        baseSize: baseSize ?? this.baseSize,
        headingWeight: headingWeight ?? this.headingWeight,
        bodyWeight: bodyWeight ?? this.bodyWeight,
        letterCase: letterCase ?? this.letterCase,
        scale: scale ?? this.scale,
      );

  @override
  bool operator ==(Object other) =>
      other is AtlasTypography &&
      other.font == font &&
      other.headingFont == headingFont &&
      other.baseSize == baseSize &&
      other.headingWeight == headingWeight &&
      other.bodyWeight == bodyWeight &&
      other.letterCase == letterCase &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(font, headingFont, baseSize, headingWeight, bodyWeight, letterCase, scale);
}

/// A card shadow: [opacity], [blur] radius and [y] offset (logical px).
typedef AtlasShadow = ({double opacity, double blur, double y});

/// Density spacing: base unit, card padding, row gap, control height.
typedef AtlasSpacing = ({double unit, double card, double gap, double control});

/// A fully-resolved design: every token has a value.
class AtlasDesign {
  const AtlasDesign({
    required this.colorScheme,
    required this.palette,
    required this.paletteDark,
    required this.typography,
    required this.radius,
    required this.controlRadius,
    required this.borderWidth,
    required this.cardShadow,
    required this.density,
    required this.cardStyle,
    required this.cardBlur,
    required this.cardWidth,
    required this.logoSize,
    required this.buttonStyle,
    required this.socialLayout,
    required this.inputStyle,
    this.logoUrl,
    this.logoDarkUrl,
  });

  final AtlasColorScheme colorScheme;
  final AtlasPalette palette;
  final AtlasPalette paletteDark;
  final AtlasTypography typography;

  /// Card corner radius (0…32).
  final int radius;

  /// Button + input corner radius; 999 = pill.
  final int controlRadius;
  final int borderWidth;
  final AtlasCardShadow cardShadow;
  final AtlasDensity density;
  final AtlasCardStyle cardStyle;
  final int cardBlur;
  final AtlasCardWidth cardWidth;
  final AtlasLogoSize logoSize;
  final AtlasButtonStyle buttonStyle;
  final AtlasSocialLayout socialLayout;
  final AtlasInputStyle inputStyle;
  final String? logoUrl;
  final String? logoDarkUrl;

  /// The Atlas baseline (the `minimal` preset) — what a missing key resolves to.
  static final AtlasDesign defaults = AtlasDesign(
    colorScheme: AtlasColorScheme.auto,
    palette: AtlasPalette.fromSpec(
        '#18181b #ffffff #4f46e5 #fafafa #ffffff #18181b #71717a #e4e4e7 #dc2626 #15803d #ffffff #18181b'),
    paletteDark: AtlasPalette.fromSpec(
        '#fafafa #18181b #818cf8 #09090b #18181b #fafafa #a1a1aa #3f3f46 #f87171 #4ade80 #09090b #fafafa'),
    typography: const AtlasTypography(
      font: 'inter',
      headingFont: 'inter',
      baseSize: 15,
      headingWeight: 600,
      bodyWeight: 400,
      letterCase: AtlasLetterCase.none,
      scale: 'perfect-fourth',
    ),
    radius: 12,
    controlRadius: 8,
    borderWidth: 1,
    cardShadow: AtlasCardShadow.md,
    density: AtlasDensity.comfortable,
    cardStyle: AtlasCardStyle.solid,
    cardBlur: 16,
    cardWidth: AtlasCardWidth.normal,
    logoSize: AtlasLogoSize.md,
    buttonStyle: AtlasButtonStyle.solid,
    socialLayout: AtlasSocialLayout.list,
    inputStyle: AtlasInputStyle.outline,
  );

  /// Decode `design.resolved` TOLERANTLY: unknown keys are ignored, and a
  /// missing, mistyped or out-of-range value falls back to [defaults] — a newer
  /// server never breaks an older app.
  factory AtlasDesign.fromResolved(Map<String, dynamic> json, {String? logoUrl, String? logoDarkUrl}) {
    final d = defaults;
    Map<String, dynamic> section(String key) {
      final v = json[key];
      return v is Map ? v.cast<String, dynamic>() : const {};
    }

    int intIn(Map<String, dynamic> m, String key, int min, int max, int dflt) {
      final v = m[key];
      if (v is! num || v != v.roundToDouble()) return dflt;
      final i = v.toInt();
      return i >= min && i <= max ? i : dflt;
    }

    String font(Map<String, dynamic> m, String key, String dflt) =>
        AtlasFontCatalog.isKnown(m[key]) ? m[key] as String : dflt;

    final t = section('typography');
    final bodyFont = font(t, 'font', d.typography.font);
    // A design that sets `font` but no `headingFont` uses it for headings too.
    final headingFont = font(t, 'headingFont', t.containsKey('font') ? bodyFont : d.typography.headingFont);
    final s = section('shape');
    final c = section('card');
    final b = section('buttons');
    final scale = t['scale'];
    return AtlasDesign(
      colorScheme: _parseEnum(AtlasColorScheme.values, json['colorScheme']) ?? d.colorScheme,
      palette: AtlasPalette.fromJson(json['palette'], d.palette),
      paletteDark: AtlasPalette.fromJson(json['paletteDark'], d.paletteDark),
      typography: AtlasTypography(
        font: bodyFont,
        headingFont: headingFont,
        baseSize: intIn(t, 'baseSize', 12, 20, d.typography.baseSize),
        headingWeight: intIn(t, 'headingWeight', 300, 900, d.typography.headingWeight),
        bodyWeight: intIn(t, 'bodyWeight', 100, 900, d.typography.bodyWeight),
        letterCase: _parseEnum(AtlasLetterCase.values, t['letterCase']) ?? d.typography.letterCase,
        scale: scale is String && _typeScales.containsKey(scale) ? scale : d.typography.scale,
      ),
      radius: intIn(s, 'radius', 0, 32, d.radius),
      controlRadius: intIn(s, 'controlRadius', 0, 999, d.controlRadius),
      borderWidth: intIn(s, 'borderWidth', 0, 3, d.borderWidth),
      cardShadow: _parseEnum(AtlasCardShadow.values, section('elevation')['cardShadow']) ?? d.cardShadow,
      density: _parseEnum(AtlasDensity.values, section('spacing')['density']) ?? d.density,
      cardStyle: _parseEnum(AtlasCardStyle.values, c['style']) ?? d.cardStyle,
      cardBlur: intIn(c, 'blur', 0, 40, d.cardBlur),
      cardWidth: _parseEnum(AtlasCardWidth.values, c['width']) ?? d.cardWidth,
      logoSize: _parseEnum(AtlasLogoSize.values, section('layout')['logoSize']) ?? d.logoSize,
      buttonStyle: _parseEnum(AtlasButtonStyle.values, b['style']) ?? d.buttonStyle,
      socialLayout: _parseEnum(AtlasSocialLayout.values, b['socialLayout']) ?? d.socialLayout,
      inputStyle: _parseEnum(AtlasInputStyle.values, section('inputs')['style']) ?? d.inputStyle,
      logoUrl: logoUrl,
      logoDarkUrl: logoDarkUrl,
    );
  }

  /// Decode the whole `design` member of `GET /v1/appearance`; null for `null`.
  static AtlasDesign? fromBundle(Object? bundle) {
    if (bundle is! Map) return null;
    final resolved = bundle['resolved'];
    String? url(String key) => bundle[key] is String ? bundle[key] as String : null;
    return AtlasDesign.fromResolved(
      resolved is Map ? resolved.cast<String, dynamic>() : const {},
      logoUrl: url('logo_url'),
      logoDarkUrl: url('logo_dark_url'),
    );
  }

  /// The design the native UI renders. Precedence, lowest first: Atlas
  /// defaults < the dashboard design < the code-level [appearance].
  ///
  /// Returns null — "render exactly the pre-design look" — when there is no
  /// dashboard design (or [AtlasAppearance.applyDashboardDesign] is false) AND no
  /// code override.
  static AtlasDesign? resolve(AtlasDesign? dashboard, AtlasAppearance? appearance) {
    final base = appearance?.applyDashboardDesign == false ? null : dashboard;
    if (appearance == null || appearance.isEmpty) return base;
    return appearance.applyTo(base ?? defaults);
  }

  // ---- derived values --------------------------------------------------------

  /// Whether the dark palette applies, given the platform brightness.
  bool usesDark({required bool platformIsDark}) => switch (colorScheme) {
        AtlasColorScheme.dark => true,
        AtlasColorScheme.light => false,
        AtlasColorScheme.auto => platformIsDark,
      };

  /// The palette for the current brightness (honouring a forced scheme).
  AtlasPalette activePalette({required bool platformIsDark}) =>
      usesDark(platformIsDark: platformIsDark) ? paletteDark : palette;

  /// The logo for the current mode: the dark upload in dark mode, else the light one.
  String? logo({required bool platformIsDark}) =>
      usesDark(platformIsDark: platformIsDark) ? (logoDarkUrl ?? logoUrl) : (logoUrl ?? logoDarkUrl);

  bool get isPill => controlRadius >= 999;

  AtlasSpacing get spacing => switch (density) {
        AtlasDensity.compact => (unit: 3, card: 20, gap: 10, control: 36),
        AtlasDensity.comfortable => (unit: 4, card: 28, gap: 14, control: 40),
        AtlasDensity.spacious => (unit: 5, card: 36, gap: 18, control: 46),
      };

  double get cardMaxWidth => switch (cardWidth) {
        AtlasCardWidth.narrow => 340,
        AtlasCardWidth.normal => 380,
        AtlasCardWidth.wide => 460,
      };

  double get logoHeight => switch (logoSize) {
        AtlasLogoSize.sm => 32,
        AtlasLogoSize.md => 48,
        AtlasLogoSize.lg => 64,
      };

  /// The card's shadow; null for none. An outline / none card never casts one.
  AtlasShadow? get shadow {
    if (cardStyle == AtlasCardStyle.outline || cardStyle == AtlasCardStyle.none) return null;
    return switch (cardShadow) {
      AtlasCardShadow.none => null,
      AtlasCardShadow.sm => (opacity: 0.05, blur: 2, y: 1),
      AtlasCardShadow.md => (opacity: 0.12, blur: 40, y: 12),
      AtlasCardShadow.lg => (opacity: 0.14, blur: 48, y: 16),
      AtlasCardShadow.xl => (opacity: 0.24, blur: 80, y: 32),
    };
  }

  /// The card border: outline cards always get one, none cards never do.
  int get cardBorderWidth => switch (cardStyle) {
        AtlasCardStyle.none => 0,
        AtlasCardStyle.outline => math.max(1, borderWidth),
        _ => borderWidth,
      };

  AtlasDesign copyWith({
    AtlasColorScheme? colorScheme,
    AtlasPalette? palette,
    AtlasPalette? paletteDark,
    AtlasTypography? typography,
    int? radius,
    int? controlRadius,
    int? borderWidth,
    AtlasCardShadow? cardShadow,
    AtlasDensity? density,
    AtlasCardStyle? cardStyle,
    int? cardBlur,
    AtlasCardWidth? cardWidth,
    AtlasLogoSize? logoSize,
    AtlasButtonStyle? buttonStyle,
    AtlasSocialLayout? socialLayout,
    AtlasInputStyle? inputStyle,
    String? logoUrl,
    String? logoDarkUrl,
  }) =>
      AtlasDesign(
        colorScheme: colorScheme ?? this.colorScheme,
        palette: palette ?? this.palette,
        paletteDark: paletteDark ?? this.paletteDark,
        typography: typography ?? this.typography,
        radius: radius ?? this.radius,
        controlRadius: controlRadius ?? this.controlRadius,
        borderWidth: borderWidth ?? this.borderWidth,
        cardShadow: cardShadow ?? this.cardShadow,
        density: density ?? this.density,
        cardStyle: cardStyle ?? this.cardStyle,
        cardBlur: cardBlur ?? this.cardBlur,
        cardWidth: cardWidth ?? this.cardWidth,
        logoSize: logoSize ?? this.logoSize,
        buttonStyle: buttonStyle ?? this.buttonStyle,
        socialLayout: socialLayout ?? this.socialLayout,
        inputStyle: inputStyle ?? this.inputStyle,
        logoUrl: logoUrl ?? this.logoUrl,
        logoDarkUrl: logoDarkUrl ?? this.logoDarkUrl,
      );

  @override
  bool operator ==(Object other) =>
      other is AtlasDesign &&
      other.colorScheme == colorScheme &&
      other.palette == palette &&
      other.paletteDark == paletteDark &&
      other.typography == typography &&
      other.radius == radius &&
      other.controlRadius == controlRadius &&
      other.borderWidth == borderWidth &&
      other.cardShadow == cardShadow &&
      other.density == density &&
      other.cardStyle == cardStyle &&
      other.cardBlur == cardBlur &&
      other.cardWidth == cardWidth &&
      other.logoSize == logoSize &&
      other.buttonStyle == buttonStyle &&
      other.socialLayout == socialLayout &&
      other.inputStyle == inputStyle &&
      other.logoUrl == logoUrl &&
      other.logoDarkUrl == logoDarkUrl;

  @override
  int get hashCode => Object.hashAll([
        colorScheme, palette, paletteDark, typography, radius, controlRadius, borderWidth, cardShadow,
        density, cardStyle, cardBlur, cardWidth, logoSize, buttonStyle, socialLayout, inputStyle,
        logoUrl, logoDarkUrl,
      ]);
}

/// Code-level design overrides — the same tokens as the dashboard's design
/// editor. Every field is optional; a set field wins over the dashboard design.
///
/// ```dart
/// AtlasSignIn(
///   client: client,
///   appearance: const AtlasAppearance(
///     palette: {AtlasPaletteSlot.primary: '#0f766e'},
///     controlRadius: 999,             // pill buttons + inputs
///     buttonStyle: AtlasButtonStyle.soft,
///   ),
/// )
/// ```
class AtlasAppearance {
  const AtlasAppearance({
    this.applyDashboardDesign = true,
    this.colorScheme,
    this.palette = const {},
    this.paletteDark = const {},
    this.font,
    this.headingFont,
    this.baseSize,
    this.headingWeight,
    this.bodyWeight,
    this.letterCase,
    this.scale,
    this.radius,
    this.controlRadius,
    this.borderWidth,
    this.cardShadow,
    this.density,
    this.cardStyle,
    this.cardWidth,
    this.logoSize,
    this.buttonStyle,
    this.socialLayout,
    this.inputStyle,
    this.logoUrl,
    this.logoDarkUrl,
  });

  /// Apply the design saved in the Atlas dashboard (default true); false = only
  /// these overrides, over the Atlas defaults.
  final bool applyDashboardDesign;
  final AtlasColorScheme? colorScheme;

  /// Light-mode slot overrides (`#rrggbb`). Brand slots (primary, accent,
  /// danger, success) also apply in dark mode unless [paletteDark] sets them.
  final Map<AtlasPaletteSlot, String> palette;
  final Map<AtlasPaletteSlot, String> paletteDark;

  /// A font catalog id (`inter`, `source-serif`, `system-mono`, …).
  final String? font;
  final String? headingFont;
  final int? baseSize;
  final int? headingWeight;
  final int? bodyWeight;
  final AtlasLetterCase? letterCase;
  final String? scale;
  final int? radius;
  final int? controlRadius;
  final int? borderWidth;
  final AtlasCardShadow? cardShadow;
  final AtlasDensity? density;
  final AtlasCardStyle? cardStyle;
  final AtlasCardWidth? cardWidth;
  final AtlasLogoSize? logoSize;
  final AtlasButtonStyle? buttonStyle;
  final AtlasSocialLayout? socialLayout;
  final AtlasInputStyle? inputStyle;
  final String? logoUrl;
  final String? logoDarkUrl;

  /// True when no token is overridden ([applyDashboardDesign] is not a token).
  bool get isEmpty =>
      colorScheme == null &&
      palette.isEmpty &&
      paletteDark.isEmpty &&
      font == null &&
      headingFont == null &&
      baseSize == null &&
      headingWeight == null &&
      bodyWeight == null &&
      letterCase == null &&
      scale == null &&
      radius == null &&
      controlRadius == null &&
      borderWidth == null &&
      cardShadow == null &&
      density == null &&
      cardStyle == null &&
      cardWidth == null &&
      logoSize == null &&
      buttonStyle == null &&
      socialLayout == null &&
      inputStyle == null &&
      logoUrl == null &&
      logoDarkUrl == null;

  AtlasDesign applyTo(AtlasDesign base) {
    int? inRange(int? v, int min, int max) => v != null && v >= min && v <= max ? v : null;
    final light = {for (final e in palette.entries) if (AtlasHex.isValid(e.value)) e.key: e.value};
    final lightOver = {...light};
    final p = light[AtlasPaletteSlot.primary];
    if (p != null && !light.containsKey(AtlasPaletteSlot.primaryInk)) {
      lightOver[AtlasPaletteSlot.primaryInk] = AtlasHex.readableOn(p);
    }
    final darkOver = {for (final e in paletteDark.entries) if (AtlasHex.isValid(e.value)) e.key: e.value};
    for (final slot in AtlasPaletteSlot.brand) {
      if (!darkOver.containsKey(slot) && light[slot] != null) darkOver[slot] = light[slot]!;
    }
    final dp = darkOver[AtlasPaletteSlot.primary];
    if (dp != null && !darkOver.containsKey(AtlasPaletteSlot.primaryInk)) {
      darkOver[AtlasPaletteSlot.primaryInk] = light[AtlasPaletteSlot.primaryInk] ?? AtlasHex.readableOn(dp);
    }
    final validFont = AtlasFontCatalog.isKnown(font) ? font : null;
    final validHeading = AtlasFontCatalog.isKnown(headingFont) ? headingFont : null;
    return base.copyWith(
      colorScheme: colorScheme,
      palette: base.palette.withColors(lightOver),
      paletteDark: base.paletteDark.withColors(darkOver),
      typography: base.typography.copyWith(
        font: validFont,
        headingFont: validHeading ?? validFont,
        baseSize: inRange(baseSize, 12, 20),
        headingWeight: inRange(headingWeight, 300, 900),
        bodyWeight: inRange(bodyWeight, 100, 900),
        letterCase: letterCase,
        scale: scale != null && _typeScales.containsKey(scale) ? scale : null,
      ),
      radius: inRange(radius, 0, 32),
      controlRadius: inRange(controlRadius, 0, 999),
      borderWidth: inRange(borderWidth, 0, 3),
      cardShadow: cardShadow,
      density: density,
      cardStyle: cardStyle,
      cardWidth: cardWidth,
      logoSize: logoSize,
      buttonStyle: buttonStyle,
      socialLayout: socialLayout,
      inputStyle: inputStyle,
      logoUrl: logoUrl,
      logoDarkUrl: logoDarkUrl,
    );
  }
}

/// The public appearance of an instance (`GET /v1/appearance`), as far as the
/// native UI uses it.
class AtlasAppearanceInfo {
  const AtlasAppearanceInfo({this.design, this.providers = const [], this.applicationName});

  /// Decode a `GET /v1/appearance` body tolerantly.
  factory AtlasAppearanceInfo.fromJson(Map<String, dynamic> json) {
    final providers = json['providers'];
    final appearance = json['appearance'];
    return AtlasAppearanceInfo(
      design: AtlasDesign.fromBundle(json['design']),
      providers: providers is List ? providers.whereType<String>().toList(growable: false) : const [],
      applicationName:
          appearance is Map && appearance['applicationName'] is String ? appearance['applicationName'] as String : null,
    );
  }

  /// The dashboard design, or null when none has been saved.
  final AtlasDesign? design;

  /// Enabled social provider ids (`google`, `github`, …).
  final List<String> providers;
  final String? applicationName;
}

/// Display names for provider ids.
String atlasProviderName(String id) {
  const known = {
    'github': 'GitHub',
    'gitlab': 'GitLab',
    'linkedin': 'LinkedIn',
    'linkedin_oidc': 'LinkedIn',
    'x': 'X',
    'twitter': 'X',
    'tiktok': 'TikTok',
    'hubspot': 'HubSpot',
    'huggingface': 'Hugging Face',
    'cognito': 'AWS Cognito',
    'paybin': 'Paybin',
    'railway': 'Railway',
  };
  return known[id] ??
      id
          .split(RegExp('[_-]'))
          .where((p) => p.isNotEmpty)
          .map((p) => p[0].toUpperCase() + p.substring(1))
          .join(' ');
}
