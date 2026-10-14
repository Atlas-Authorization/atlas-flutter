import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../design.dart';

/// Maps an [AtlasDesign] onto Flutter: a [ThemeData] the prebuilt widgets pick up
/// (buttons, inputs, text, colours), plus the card, logo and social buttons.
///
/// `AtlasSignIn` uses it only when a design applies (a dashboard design was
/// saved, or the app passed an [AtlasAppearance]); without one the widgets keep
/// following the ambient [Theme], untouched.
class AtlasDesignStyle {
  AtlasDesignStyle(this.design, {required bool platformIsDark, this.fonts = const {}})
      : isDark = design.usesDark(platformIsDark: platformIsDark),
        palette = design.activePalette(platformIsDark: platformIsDark);

  final AtlasDesign design;
  final bool isDark;
  final AtlasPalette palette;

  /// Font family names the app provides, keyed by catalog id (`inter`, …).
  final Map<String, String> fonts;

  /// The colour of a palette slot.
  Color color(AtlasPaletteSlot slot) => atlasColor(palette[slot]);

  AtlasTypography get _t => design.typography;

  /// The family for a catalog id: the app's mapping, else the catalog family
  /// (used when the app bundles it), with a same-category platform fallback.
  String? family(String id) => fonts[id] ?? AtlasFontCatalog.family(id);

  List<String> fallback(String id) => switch (AtlasFontCatalog.category(id)) {
        AtlasFontCategory.serif => const ['Georgia', 'Times New Roman', 'serif', 'Noto Serif'],
        AtlasFontCategory.monospace => const ['Menlo', 'SF Mono', 'Courier', 'monospace', 'Roboto Mono'],
        AtlasFontCategory.sansSerif => const [],
      };

  static FontWeight weight(int w) => FontWeight.values[((w.clamp(100, 900) / 100).round() - 1)];

  TextStyle get body => TextStyle(
        fontFamily: family(_t.font),
        fontFamilyFallback: fallback(_t.font),
        fontSize: _t.baseSize.toDouble(),
        fontWeight: weight(_t.bodyWeight),
        color: color(AtlasPaletteSlot.text),
      );

  TextStyle get small => body.copyWith(fontSize: _t.smallSize, color: color(AtlasPaletteSlot.muted));

  TextStyle get heading => TextStyle(
        fontFamily: family(_t.headingFont),
        fontFamilyFallback: fallback(_t.headingFont),
        fontSize: _t.headingSize,
        fontWeight: weight(_t.headingWeight),
        color: color(AtlasPaletteSlot.text),
      );

  TextStyle get button => body.copyWith(
        fontWeight: weight(math.max(500, _t.bodyWeight)),
        letterSpacing: _t.letterCase == AtlasLetterCase.uppercase ? _t.baseSize * 0.04 : null,
      );

  /// A button label in the design's letter case.
  String label(String text) => _t.letterCase == AtlasLetterCase.uppercase ? text.toUpperCase() : text;

  double get controlHeight => design.spacing.control;

  /// Control corner radius; a pill (999) becomes half the control height.
  BorderRadius get controlRadius =>
      BorderRadius.circular(math.min(design.controlRadius.toDouble(), controlHeight / 2));

  double get borderWidth => design.borderWidth.toDouble();

  ButtonStyle get primaryButton {
    final primary = color(AtlasPaletteSlot.primary);
    final ink = color(AtlasPaletteSlot.primaryInk);
    final shape = RoundedRectangleBorder(borderRadius: controlRadius);
    final base = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size.fromHeight(controlHeight)),
      shape: WidgetStatePropertyAll(shape),
      textStyle: WidgetStatePropertyAll(button),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: design.spacing.unit * 3)),
      elevation: const WidgetStatePropertyAll(0),
    );
    Color dim(Color c, Set<WidgetState> s) => s.contains(WidgetState.disabled) ? c.withValues(alpha: c.a * 0.6) : c;
    return switch (design.buttonStyle) {
      AtlasButtonStyle.solid => base.copyWith(
          backgroundColor: WidgetStateProperty.resolveWith((s) => dim(primary, s)),
          foregroundColor: WidgetStatePropertyAll(ink),
        ),
      AtlasButtonStyle.outline => base.copyWith(
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith((s) => dim(primary, s)),
          side: WidgetStatePropertyAll(BorderSide(color: primary, width: math.max(1, borderWidth))),
        ),
      AtlasButtonStyle.soft => base.copyWith(
          backgroundColor: WidgetStatePropertyAll(primary.withValues(alpha: 0.14)),
          foregroundColor: WidgetStateProperty.resolveWith((s) => dim(primary, s)),
        ),
      AtlasButtonStyle.gradient => base.copyWith(
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStatePropertyAll(ink),
          backgroundBuilder: (context, states, child) => DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: controlRadius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  dim(primary, states),
                  dim(color(AtlasPaletteSlot.accent), states),
                ],
              ),
            ),
            child: child,
          ),
        ),
    };
  }

  /// Secondary buttons (social, "start over"): bordered, text-coloured.
  ButtonStyle get secondaryButton => ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(controlHeight, controlHeight)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: controlRadius)),
        textStyle: WidgetStatePropertyAll(small.copyWith(fontWeight: FontWeight.w500)),
        foregroundColor: WidgetStatePropertyAll(color(AtlasPaletteSlot.text)),
        backgroundColor: WidgetStatePropertyAll(color(AtlasPaletteSlot.surface)),
        side: WidgetStatePropertyAll(
            BorderSide(color: color(AtlasPaletteSlot.border), width: math.max(1, borderWidth))),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: design.spacing.unit * 3)),
      );

  InputDecorationTheme get inputDecoration {
    final border = color(AtlasPaletteSlot.border);
    final primary = color(AtlasPaletteSlot.primary);
    final pad = EdgeInsets.symmetric(horizontal: design.spacing.unit * 3, vertical: design.spacing.unit * 2.5);
    final labelStyle = small.copyWith(color: color(AtlasPaletteSlot.muted));
    switch (design.inputStyle) {
      case AtlasInputStyle.outline:
        OutlineInputBorder b(Color c, double w) => OutlineInputBorder(
            borderRadius: controlRadius,
            borderSide: w == 0 ? BorderSide.none : BorderSide(color: c, width: w));
        return InputDecorationTheme(
          filled: true,
          fillColor: color(AtlasPaletteSlot.inputBackground),
          contentPadding: pad,
          labelStyle: labelStyle,
          enabledBorder: b(border, borderWidth),
          border: b(border, borderWidth),
          focusedBorder: b(primary, math.max(1, borderWidth)),
          errorBorder: b(color(AtlasPaletteSlot.danger), math.max(1, borderWidth)),
        );
      case AtlasInputStyle.filled:
        // Text colour washed 6% over the input background, no border (as on the web).
        final fill = Color.alphaBlend(
            color(AtlasPaletteSlot.text).withValues(alpha: 0.06), color(AtlasPaletteSlot.inputBackground));
        final none = OutlineInputBorder(borderRadius: controlRadius, borderSide: BorderSide.none);
        return InputDecorationTheme(
          filled: true,
          fillColor: fill,
          contentPadding: pad,
          labelStyle: labelStyle,
          enabledBorder: none,
          border: none,
          focusedBorder: OutlineInputBorder(
              borderRadius: controlRadius, borderSide: BorderSide(color: primary, width: math.max(1, borderWidth))),
        );
      case AtlasInputStyle.underline:
        final w = math.max(1.0, borderWidth);
        return InputDecorationTheme(
          filled: false,
          contentPadding: EdgeInsets.symmetric(vertical: design.spacing.unit * 2.5),
          labelStyle: labelStyle,
          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: border, width: w)),
          border: UnderlineInputBorder(borderSide: BorderSide(color: border, width: w)),
          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primary, width: w)),
        );
    }
  }

  /// The theme the sign-in form renders under, layered over the ambient one.
  ThemeData theme(ThemeData base) {
    final danger = color(AtlasPaletteSlot.danger);
    final scheme = ColorScheme(
      brightness: isDark ? Brightness.dark : Brightness.light,
      primary: color(AtlasPaletteSlot.primary),
      onPrimary: color(AtlasPaletteSlot.primaryInk),
      secondary: color(AtlasPaletteSlot.accent),
      onSecondary: atlasColor(AtlasHex.readableOn(palette[AtlasPaletteSlot.accent])),
      error: danger,
      onError: atlasColor(AtlasHex.readableOn(palette[AtlasPaletteSlot.danger])),
      errorContainer: Color.alphaBlend(danger.withValues(alpha: 0.12), color(AtlasPaletteSlot.surface)),
      onErrorContainer: danger,
      surface: color(AtlasPaletteSlot.surface),
      onSurface: color(AtlasPaletteSlot.text),
      onSurfaceVariant: color(AtlasPaletteSlot.muted),
      outline: color(AtlasPaletteSlot.border),
    );
    final text = base.textTheme.copyWith(
      headlineSmall: heading,
      bodyLarge: body,
      bodyMedium: body,
      titleMedium: body.copyWith(fontWeight: weight(math.max(500, _t.bodyWeight))),
      labelLarge: button,
    );
    return base.copyWith(
      colorScheme: scheme,
      textTheme: text,
      inputDecorationTheme: inputDecoration,
      filledButtonTheme: FilledButtonThemeData(style: primaryButton),
      outlinedButtonTheme: OutlinedButtonThemeData(style: secondaryButton),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: color(AtlasPaletteSlot.primary), textStyle: small),
      ),
      textSelectionTheme: TextSelectionThemeData(cursorColor: color(AtlasPaletteSlot.primary)),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: color(AtlasPaletteSlot.primary)),
    );
  }
}

/// A Flutter colour from `#rrggbb`; transparent when not a hex colour.
Color atlasColor(String hex) {
  final n = AtlasHex.rgb(hex);
  return n == null ? const Color(0x00000000) : Color(0xFF000000 | n);
}

/// The card around the sign-in form: surface, radius, border, shadow, padding, width.
class AtlasDesignCard extends StatelessWidget {
  const AtlasDesignCard({super.key, required this.style, required this.child});

  final AtlasDesignStyle style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final d = style.design;
    final radius = BorderRadius.circular(d.radius.toDouble());
    final shadow = d.shadow;
    final surface = switch (d.cardStyle) {
      AtlasCardStyle.none => const Color(0x00000000),
      AtlasCardStyle.glass => style.color(AtlasPaletteSlot.surface).withValues(alpha: style.isDark ? 0.6 : 0.72),
      _ => style.color(AtlasPaletteSlot.surface),
    };
    Widget card = Container(
      key: const Key('atlas.card'),
      padding: EdgeInsets.all(d.cardStyle == AtlasCardStyle.none ? 0 : d.spacing.card),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: radius,
        border: d.cardBorderWidth > 0
            ? Border.all(color: style.color(AtlasPaletteSlot.border), width: d.cardBorderWidth.toDouble())
            : null,
        boxShadow: shadow == null
            ? null
            : [
                BoxShadow(
                  color: Color.fromRGBO(0, 0, 0, shadow.opacity),
                  blurRadius: shadow.blur,
                  offset: Offset(0, shadow.y),
                ),
              ],
      ),
      child: child,
    );
    if (d.cardStyle == AtlasCardStyle.glass && d.cardBlur > 0) {
      // The shadow lives on an outer box so the blur clip does not cut it off.
      card = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: shadow == null
              ? null
              : [BoxShadow(color: Color.fromRGBO(0, 0, 0, shadow.opacity), blurRadius: shadow.blur, offset: Offset(0, shadow.y))],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: d.cardBlur / 2, sigmaY: d.cardBlur / 2),
            child: card,
          ),
        ),
      );
    }
    return ConstrainedBox(constraints: BoxConstraints(maxWidth: d.cardMaxWidth), child: card);
  }
}

/// Social sign-in buttons laid out per the design (list / grid / icons). The
/// widget only reports the tapped provider id; start OAuth yourself with
/// `AtlasClient.oauthAuthorizeUrl` + a browser session.
class AtlasSocialButtons extends StatelessWidget {
  const AtlasSocialButtons({
    super.key,
    required this.providers,
    required this.onSelected,
    this.design,
    this.fonts = const {},
  });

  final List<String> providers;
  final void Function(String provider) onSelected;

  /// The design to draw with; null = the Atlas defaults.
  final AtlasDesign? design;
  final Map<String, String> fonts;

  @override
  Widget build(BuildContext context) {
    final d = design ?? AtlasDesign.defaults;
    final style = AtlasDesignStyle(d,
        platformIsDark: MediaQuery.platformBrightnessOf(context) == Brightness.dark, fonts: fonts);
    final gap = d.spacing.unit * 2;
    Widget button(String id, String text) => OutlinedButton(
          key: Key('atlas.social.$id'),
          style: style.secondaryButton,
          onPressed: () => onSelected(id),
          child: Text(style.label(text)),
        );
    switch (d.socialLayout) {
      case AtlasSocialLayout.list:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final id in providers) ...[
              if (id != providers.first) SizedBox(height: gap),
              button(id, 'Continue with ${atlasProviderName(id)}'),
            ],
          ],
        );
      case AtlasSocialLayout.grid:
        final rows = <Widget>[];
        for (var i = 0; i < providers.length; i += 2) {
          if (i > 0) rows.add(SizedBox(height: gap));
          rows.add(Row(children: [
            Expanded(child: button(providers[i], atlasProviderName(providers[i]))),
            SizedBox(width: gap),
            Expanded(
              child: i + 1 < providers.length
                  ? button(providers[i + 1], atlasProviderName(providers[i + 1]))
                  : const SizedBox.shrink(),
            ),
          ]));
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
      case AtlasSocialLayout.icons:
        return Wrap(
          alignment: WrapAlignment.center,
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final id in providers)
              Semantics(
                label: 'Continue with ${atlasProviderName(id)}',
                button: true,
                excludeSemantics: true,
                child: button(id, atlasProviderName(id).substring(0, 1)),
              ),
          ],
        );
    }
  }
}
