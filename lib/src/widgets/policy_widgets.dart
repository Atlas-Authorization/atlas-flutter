import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart' as launcher;

import '../atlas_client.dart';
import '../atlas_exception.dart';
import '../policy_html.dart';

// Prebuilt Flutter UI for policy acceptance. Every piece reads and writes a
// [PolicyAcceptanceController], the same state machine the headless API uses, so
// an app can mix them with its own screens:
//
//  - [AtlasPolicyConsent]    the checkbox(es) for a sign-up form, with an in-app viewer;
//  - [AtlasPolicyClickwrap]  the "By continuing you agree to ..." sentence for `link` policies;
//  - [runScrollPolicies]     the unskippable scroll-to-accept dialog for `scroll` policies;
//  - [AtlasPolicyAcceptStep] the step a held sign-in shows ([AcceptPolicies]);
//  - [AtlasPolicyGate]       the banner + re-accept flow for a signed-in user.
//
// Documents are drawn natively from the server's sanitised HTML
// ([parsePolicyHtml]); nothing is rendered in a web view.

Future<void> _defaultOpenLink(String href) async {
  try {
    await launcher.launchUrl(Uri.parse(href), mode: launcher.LaunchMode.externalApplication);
  } catch (_) {
    // A link that cannot open is not worth interrupting acceptance for.
  }
}

/// A policy document drawn from sanitised HTML: headings, paragraphs, lists,
/// quotes, bold / italic / code and safe links (opened with [onLink], default the
/// system browser).
class AtlasPolicyDocument extends StatefulWidget {
  const AtlasPolicyDocument({super.key, required this.html, this.onLink});

  final String html;
  final void Function(String href)? onLink;

  @override
  State<AtlasPolicyDocument> createState() => _AtlasPolicyDocumentState();
}

class _AtlasPolicyDocumentState extends State<AtlasPolicyDocument> {
  final List<TapGestureRecognizer> _recognizers = [];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  TextSpan _span(PolicySpan s, TextStyle base, Color linkColor) {
    TapGestureRecognizer? tap;
    if (s.href != null) {
      final href = s.href!;
      tap = TapGestureRecognizer()..onTap = () => (widget.onLink ?? _defaultOpenLink)(href);
      _recognizers.add(tap);
    }
    return TextSpan(
      text: s.text,
      recognizer: tap,
      style: base.copyWith(
        fontWeight: s.bold ? FontWeight.bold : null,
        fontStyle: s.italic ? FontStyle.italic : null,
        fontFamily: s.code ? 'monospace' : null,
        color: s.href != null ? linkColor : null,
        decoration: s.href != null ? TextDecoration.underline : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final theme = Theme.of(context);
    final blocks = parsePolicyHtml(widget.html);
    final children = <Widget>[];
    for (final b in blocks) {
      if (b.kind == PolicyBlockKind.rule) {
        children.add(const Divider());
        continue;
      }
      var style = theme.textTheme.bodyMedium ?? const TextStyle();
      if (b.kind == PolicyBlockKind.heading) {
        style = switch (b.level) {
          1 => theme.textTheme.titleLarge,
          2 => theme.textTheme.titleMedium,
          _ => theme.textTheme.titleSmall,
        }!
            .copyWith(fontWeight: FontWeight.w600);
      } else if (b.kind == PolicyBlockKind.quote) {
        style = style.copyWith(fontStyle: FontStyle.italic);
      }
      final text = Text.rich(
        TextSpan(children: [for (final s in b.spans) _span(s, style, theme.colorScheme.primary)]),
        style: style,
      );
      final indent = b.depth * 16.0 + (b.kind == PolicyBlockKind.quote ? 12.0 : 0.0);
      children.add(Padding(
        padding: EdgeInsets.only(left: indent, bottom: 8),
        child: b.marker == null
            ? text
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(right: 6), child: Text(b.marker!, style: style)),
                  Expanded(child: text),
                ],
              ),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

String _policyMeta(AtlasPolicy policy, AtlasPolicyStrings strings) {
  final parts = <String>[];
  if (policy.version.isNotEmpty) {
    parts.add(fillPolicyTemplate(strings.version, {'version': policy.version}));
  }
  final date = formatPolicyDate(policy.effectiveAt);
  if (date.isNotEmpty) parts.add(fillPolicyTemplate(strings.effective, {'date': date}));
  return parts.join(' · ');
}

/// A sentence with each policy title tappable.
class _PolicySentence extends StatefulWidget {
  const _PolicySentence({
    super.key,
    required this.template,
    required this.titles,
    required this.strings,
    required this.onTitle,
    this.onPlainTap,
  });

  final String template;
  final List<AtlasPolicy> titles;
  final AtlasPolicyStrings strings;
  final void Function(AtlasPolicy policy) onTitle;
  final VoidCallback? onPlainTap;

  @override
  State<_PolicySentence> createState() => _PolicySentenceState();
}

class _PolicySentenceState extends State<_PolicySentence> {
  final List<TapGestureRecognizer> _recognizers = [];

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final theme = Theme.of(context);
    final name = widget.template.contains('{policies}') ? 'policies' : 'policy';
    final (before, after) = splitPolicyTemplate(widget.template, name);
    final spans = <InlineSpan>[TextSpan(text: before)];
    for (var i = 0; i < widget.titles.length; i++) {
      final p = widget.titles[i];
      if (i > 0) {
        spans.add(TextSpan(text: i == widget.titles.length - 1 ? ' ${widget.strings.and} ' : ', '));
      }
      final tap = TapGestureRecognizer()..onTap = () => widget.onTitle(p);
      _recognizers.add(tap);
      spans.add(TextSpan(
        text: p.title,
        recognizer: tap,
        style: TextStyle(color: theme.colorScheme.primary, decoration: TextDecoration.underline),
      ));
    }
    spans.add(TextSpan(text: after));
    final text = Text.rich(TextSpan(children: spans), style: theme.textTheme.bodyMedium);
    if (widget.onPlainTap == null) return text;
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onPlainTap, child: text);
  }
}

/// Open a policy document in the in-app viewer (a full-screen page with a Back
/// button). Records the reading time as `view_ms` on [controller].
Future<void> showAtlasPolicyViewer(
  BuildContext context,
  PolicyAcceptanceController controller,
  AtlasPolicy policy, {
  AtlasPolicyStrings strings = const AtlasPolicyStrings(),
  void Function(String href)? onLink,
}) async {
  controller.openDocument(policy.key);
  try {
    await Navigator.of(context).push<void>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _PolicyViewerPage(controller: controller, policy: policy, strings: strings, onLink: onLink),
    ));
  } finally {
    controller.closeDocument();
  }
}

class _PolicyViewerPage extends StatefulWidget {
  const _PolicyViewerPage({required this.controller, required this.policy, required this.strings, this.onLink});

  final PolicyAcceptanceController controller;
  final AtlasPolicy policy;
  final AtlasPolicyStrings strings;
  final void Function(String href)? onLink;

  @override
  State<_PolicyViewerPage> createState() => _PolicyViewerPageState();
}

class _PolicyViewerPageState extends State<_PolicyViewerPage> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (isPolicyScrolledToEnd(pos.pixels, pos.maxScrollExtent)) {
      widget.controller.markScrolledToEnd(widget.policy.key);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = _policyMeta(widget.policy, widget.strings);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.policy.title),
        leading: const BackButton(key: Key('atlas.policy_viewer_back')),
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('atlas.policy_viewer'),
          controller: _scroll,
          padding: const EdgeInsets.all(16),
          children: [
            if (meta.isNotEmpty) ...[
              Text(meta, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
            ],
            AtlasPolicyDocument(html: widget.policy.html, onLink: widget.onLink),
          ],
        ),
      ),
    );
  }
}

/// The agreement checkbox(es) for a sign-up form: one combined "I agree to the A
/// and B" box (or one each when the controller was built with `combined: false`)
/// for the `checkbox` policies. Tapping a title opens the document in the in-app
/// viewer. Read [PolicyAcceptanceController.canSubmit] to enable the submit button.
class AtlasPolicyConsent extends StatefulWidget {
  const AtlasPolicyConsent({
    super.key,
    required this.controller,
    this.strings = const AtlasPolicyStrings(),
    this.onLink,
  });

  final PolicyAcceptanceController controller;
  final AtlasPolicyStrings strings;
  final void Function(String href)? onLink;

  @override
  State<AtlasPolicyConsent> createState() => _AtlasPolicyConsentState();
}

class _AtlasPolicyConsentState extends State<AtlasPolicyConsent> {
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(AtlasPolicyConsent old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  Widget _row({
    required Key key,
    required bool checked,
    required ValueChanged<bool> onChanged,
    required String template,
    required List<AtlasPolicy> titles,
  }) {
    return Row(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Checkbox(value: checked, onChanged: (v) => onChanged(v ?? false)),
        Expanded(
          child: _PolicySentence(
            template: template,
            titles: titles,
            strings: widget.strings,
            onPlainTap: () => onChanged(!checked),
            onTitle: (p) => showAtlasPolicyViewer(context, widget.controller, p, strings: widget.strings, onLink: widget.onLink),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final boxes = c.checkboxPolicies;
    if (boxes.isEmpty) return const SizedBox.shrink();
    if (c.combined) {
      return _row(
        key: const Key('atlas.policy_consent'),
        checked: c.combinedChecked,
        onChanged: c.setAllChecked,
        template: widget.strings.agreeCombined,
        titles: boxes,
      );
    }
    return Column(
      key: const Key('atlas.policy_consent'),
      children: [
        for (final p in boxes)
          _row(
            key: Key('atlas.policy_consent.${p.key}'),
            checked: c.isChecked(p.key),
            onChanged: (v) => c.setChecked(p.key, v),
            template: widget.strings.agreeOne,
            titles: [p],
          ),
      ],
    );
  }
}

/// The clickwrap sentence for `link` policies ("By continuing you agree to the A
/// and B"), meant to sit under the submit button: submitting accepts them. Draws
/// nothing when there are none.
class AtlasPolicyClickwrap extends StatefulWidget {
  const AtlasPolicyClickwrap({
    super.key,
    required this.controller,
    this.strings = const AtlasPolicyStrings(),
    this.onLink,
  });

  final PolicyAcceptanceController controller;
  final AtlasPolicyStrings strings;
  final void Function(String href)? onLink;

  @override
  State<AtlasPolicyClickwrap> createState() => _AtlasPolicyClickwrapState();
}

class _AtlasPolicyClickwrapState extends State<AtlasPolicyClickwrap> {
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(AtlasPolicyClickwrap old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final links = widget.controller.linkPolicies;
    if (links.isEmpty) return const SizedBox.shrink();
    return _PolicySentence(
      key: const Key('atlas.policy_clickwrap'),
      template: widget.strings.clickwrap,
      titles: links,
      strings: widget.strings,
      onTitle: (p) => showAtlasPolicyViewer(context, widget.controller, p, strings: widget.strings, onLink: widget.onLink),
    );
  }
}

/// The unskippable dialog for one `scroll` policy: it cannot be dismissed (back
/// button and outside taps are ignored), Accept turns on only once the end of the
/// text has been seen (or at once when the text fits), and Decline cancels. For a
/// re-acceptance it shows what changed. Pops `true` on Accept and `false` on Decline.
class AtlasPolicyScrollDialog extends StatefulWidget {
  const AtlasPolicyScrollDialog({
    super.key,
    required this.controller,
    required this.policy,
    this.strings = const AtlasPolicyStrings(),
    this.onLink,
  });

  final PolicyAcceptanceController controller;
  final AtlasPolicy policy;
  final AtlasPolicyStrings strings;
  final void Function(String href)? onLink;

  @override
  State<AtlasPolicyScrollDialog> createState() => _AtlasPolicyScrollDialogState();
}

class _AtlasPolicyScrollDialogState extends State<AtlasPolicyScrollDialog> {
  final ScrollController _scroll = ScrollController();
  bool _atEnd = false;

  @override
  void initState() {
    super.initState();
    widget.controller.startClock(widget.policy.key);
    _scroll.addListener(_check);
    // Text that fits needs no scrolling.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    if (!_scroll.hasClients || _atEnd) return;
    final pos = _scroll.position;
    if (isPolicyScrolledToEnd(pos.pixels, pos.maxScrollExtent)) {
      widget.controller.markScrolledToEnd(widget.policy.key);
      if (mounted) setState(() => _atEnd = true);
    }
  }

  @override
  void dispose() {
    widget.controller.stopClock(widget.policy.key);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.strings;
    final p = widget.policy;
    final meta = _policyMeta(p, s);
    final title = p.reaccept == true ? fillPolicyTemplate(s.reacceptTitle, {'policy': p.title}) : p.title;
    return PopScope(
      canPop: false,
      child: Dialog.fullscreen(
        key: const Key('atlas.policy_dialog'),
        child: Semantics(
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: title,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title, style: theme.textTheme.headlineSmall),
                  if (meta.isNotEmpty) Text(meta, style: theme.textTheme.bodySmall),
                  if (p.reaccept == true && (p.summaryOfChanges ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.summaryTitle, style: theme.textTheme.titleSmall),
                            Text(p.summaryOfChanges!, style: theme.textTheme.bodyMedium),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Expanded(
                    child: NotificationListener<ScrollMetricsNotification>(
                      onNotification: (_) {
                        WidgetsBinding.instance.addPostFrameCallback((_) => _check());
                        return false;
                      },
                      child: SingleChildScrollView(
                        key: const Key('atlas.policy_scroll'),
                        controller: _scroll,
                        child: AtlasPolicyDocument(html: p.html, onLink: widget.onLink),
                      ),
                    ),
                  ),
                  if (!_atEnd)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(s.scrollHint, style: theme.textTheme.bodySmall),
                      ),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        key: const Key('atlas.policy_decline'),
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text(s.decline),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const Key('atlas.policy_accept'),
                        onPressed: _atEnd ? () => Navigator.of(context).pop(true) : null,
                        child: Text(s.accept),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Walk the `scroll` policies one dialog at a time: each accepts into
/// [controller]. Returns the policy the user declined (and stops), or `null` when
/// every one was accepted (send the sign-up or accept the held sign-in then).
Future<AtlasPolicy?> runScrollPolicies(
  BuildContext context,
  PolicyAcceptanceController controller, {
  AtlasPolicyStrings strings = const AtlasPolicyStrings(),
  void Function(String href)? onLink,
}) async {
  while (true) {
    final next = controller.pendingScroll();
    if (next == null) return null;
    if (!context.mounted) return next;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AtlasPolicyScrollDialog(controller: controller, policy: next, strings: strings, onLink: onLink),
    );
    if (accepted != true) return next;
    controller.acceptScroll(next.key);
  }
}

/// The step a sign-in shows when the server holds the attempt at
/// `needs_policy_acceptance` ([AcceptPolicies]): the policies to accept
/// (checkboxes, the clickwrap sentence, and scroll dialogs on submit), then
/// [onAccept] gets the `policy_acceptances` to send with `acceptPolicies`.
/// [onDecline] abandons the sign-in.
///
/// [controller]: build it with [AtlasClient.policyController] from the held attempt.
class AtlasPolicyAcceptStep extends StatefulWidget {
  const AtlasPolicyAcceptStep({
    super.key,
    required this.controller,
    required this.onAccept,
    required this.onDecline,
    this.enabled = true,
    this.strings = const AtlasPolicyStrings(),
    this.onLink,
  });

  final PolicyAcceptanceController controller;
  final void Function(List<PolicyAcceptance> acceptances) onAccept;
  final VoidCallback onDecline;
  final bool enabled;
  final AtlasPolicyStrings strings;
  final void Function(String href)? onLink;

  @override
  State<AtlasPolicyAcceptStep> createState() => _AtlasPolicyAcceptStepState();
}

class _AtlasPolicyAcceptStepState extends State<AtlasPolicyAcceptStep> {
  String? _message;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  Future<void> _submit() async {
    final c = widget.controller;
    setState(() => _message = null);
    if (c.scrollPolicies.any((p) => !c.isChecked(p.key))) {
      final declined = await runScrollPolicies(context, c, strings: widget.strings, onLink: widget.onLink);
      if (!mounted) return;
      if (declined != null) {
        setState(() => _message = fillPolicyTemplate(widget.strings.declined, {'policy': declined.title}));
        widget.onDecline();
        return;
      }
    }
    widget.onAccept(c.build());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.strings;
    final c = widget.controller;
    final changed = c.policies.where((p) => p.reaccept == true && (p.summaryOfChanges ?? '').isNotEmpty);
    return Column(
      key: const Key('atlas.policy_step'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(s.pendingTitle, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(s.pendingIntro, style: theme.textTheme.bodyMedium),
        for (final p in changed)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('${p.title}: ${p.summaryOfChanges}', style: theme.textTheme.bodySmall),
          ),
        const SizedBox(height: 12),
        AtlasPolicyConsent(controller: c, strings: s, onLink: widget.onLink),
        const SizedBox(height: 12),
        FilledButton(
          key: const Key('atlas.policy_submit'),
          onPressed: widget.enabled && c.canSubmit() ? _submit : null,
          child: Text(s.submit),
        ),
        const SizedBox(height: 8),
        AtlasPolicyClickwrap(controller: c, strings: s, onLink: widget.onLink),
        TextButton(
          key: const Key('atlas.policy_step_decline'),
          onPressed: widget.enabled ? widget.onDecline : null,
          child: Text(s.decline),
        ),
        if (_message != null)
          Text(_message!, style: TextStyle(color: theme.colorScheme.error)),
      ],
    );
  }
}

/// A banner for a signed-in user whose policies need re-accepting (a newer version
/// is in force, perhaps with a grace window). Draws nothing when there is nothing
/// to accept. "Review and accept" opens the acceptance step in a dialog and posts
/// the result to `POST /v1/client/me/policies/accept`.
///
/// ```dart
/// AtlasPolicyGate(client: atlas)   // put it at the top of your signed-in screen
/// ```
class AtlasPolicyGate extends StatefulWidget {
  const AtlasPolicyGate({
    super.key,
    required this.client,
    this.locale,
    this.strings = const AtlasPolicyStrings(),
    this.onAccepted,
    this.onLink,
  });

  final AtlasClient client;
  final String? locale;
  final AtlasPolicyStrings strings;
  final VoidCallback? onAccepted;
  final void Function(String href)? onLink;

  @override
  State<AtlasPolicyGate> createState() => _AtlasPolicyGateState();
}

class _AtlasPolicyGateState extends State<AtlasPolicyGate> {
  late final PolicyGate _gate = PolicyGate(widget.client, locale: widget.locale);
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _gate.load();
    } catch (_) {
      // A failed load just hides the banner: it must never block the signed-in screen.
    }
    if (mounted) setState(() {});
  }

  Future<void> _review() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final controller = await _gate.begin();
      if (!mounted) return;
      setState(() => _busy = false);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: AtlasPolicyAcceptStep(
                controller: controller,
                strings: widget.strings.copyWith(
                  pendingTitle: widget.strings.bannerTitle,
                  pendingIntro: widget.strings.reacceptIntro,
                ),
                onLink: widget.onLink,
                onDecline: () => Navigator.of(dialogContext).pop(),
                onAccept: (acceptances) async {
                  try {
                    await widget.client.acceptMyPolicies(acceptances);
                    await _gate.load();
                    if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                    widget.onAccepted?.call();
                  } on AtlasException catch (e) {
                    if (mounted) setState(() => _error = e.message);
                    if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                  }
                },
              ),
            ),
          ),
        ),
      );
    } on AtlasException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_gate.pending.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final s = widget.strings;
    final titles = joinPolicyTitles(_gate.pending.map((p) => p.title).toList(), s.and);
    final grace = _gate.graceEndsAt;
    return Card(
      key: const Key('atlas.policy_gate'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.bannerTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(fillPolicyTemplate(s.bannerBody, {'policies': titles}), style: theme.textTheme.bodyMedium),
            if (grace != null)
              Text(fillPolicyTemplate(s.bannerGrace, {'date': formatPolicyDate(grace)}), style: theme.textTheme.bodySmall),
            if (_error != null) Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('atlas.policy_gate_review'),
              onPressed: _busy ? null : _review,
              child: Text(s.bannerReview),
            ),
          ],
        ),
      ),
    );
  }
}
