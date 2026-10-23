part of 'atlas_client.dart';

// Policy acceptance (terms of service, privacy, any policy) — the client half.
//
// Mirrors `@atlasauth/js` `policy-acceptance`: the wire types with tolerant
// readers, a small state machine ([PolicyAcceptanceController]) behind every
// policy UI, and the Frontend API calls (load the policies, accept them in a
// sign-up or a held sign-in, accept from inside the app).
//
// Display modes (a policy's `display`):
//  - `checkbox`: a checkbox, combined into one sentence when several policies use
//    it; the policy name opens the document in an in-app viewer;
//  - `scroll`: an unskippable dialog, accepted only after the end of the text is
//    seen (or the text fits); declining cancels;
//  - `link`: a clickwrap sentence under the submit button; submitting accepts.
//
// `scrolled_to_end` and `view_ms` are client-attested evidence the server records
// beside the acceptance; neither is a security boundary.

String? _polStr(Object? v) => v is String && v.isNotEmpty ? v : null;

int? _polMs(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

/// One policy's current version as the Frontend API serves it.
class AtlasPolicy {
  const AtlasPolicy({
    required this.key,
    required this.title,
    this.display = 'checkbox',
    this.required = true,
    this.appliesTo = 'sign_up',
    required this.versionId,
    this.version = '',
    this.contentHtml,
    this.contentMarkdown,
    this.contentUrl,
    this.contentSha256 = '',
    this.effectiveAt,
    this.summaryOfChanges,
    this.reaccept,
  });

  final String key;
  final String title;

  /// `checkbox`, `scroll` or `link`.
  final String display;
  final bool required;

  /// `sign_up` or `sign_in_and_sign_up`.
  final String appliesTo;
  final String versionId;
  final String version;

  /// Sanitised HTML: what the user sees and what [contentSha256] covers.
  final String? contentHtml;
  final String? contentMarkdown;
  final String? contentUrl;
  final String contentSha256;

  /// Epoch milliseconds.
  final int? effectiveAt;
  final String? summaryOfChanges;

  /// On a held sign-in's pending policy: whether an earlier version was accepted
  /// (so "what changed" applies). Null when unknown.
  final bool? reaccept;

  /// Whether this policy has any content to show.
  bool get hasContent => contentHtml != null || contentMarkdown != null;

  /// The document HTML to draw: the sanitised HTML, else the markdown rendered safely.
  String get html =>
      contentHtml ?? (contentMarkdown != null ? policyMarkdownToSafeHtml(contentMarkdown!) : '');

  AtlasPolicy copyWith({
    String? title,
    String? display,
    bool? required,
    String? versionId,
    String? version,
    String? contentHtml,
    String? contentMarkdown,
    String? contentSha256,
    String? summaryOfChanges,
    bool? reaccept,
  }) =>
      AtlasPolicy(
        key: key,
        title: title ?? this.title,
        display: display ?? this.display,
        required: required ?? this.required,
        appliesTo: appliesTo,
        versionId: versionId ?? this.versionId,
        version: version ?? this.version,
        contentHtml: contentHtml ?? this.contentHtml,
        contentMarkdown: contentMarkdown ?? this.contentMarkdown,
        contentUrl: contentUrl,
        contentSha256: contentSha256 ?? this.contentSha256,
        effectiveAt: effectiveAt,
        summaryOfChanges: summaryOfChanges ?? this.summaryOfChanges,
        reaccept: reaccept ?? this.reaccept,
      );

  /// Read one policy from the wire (flat, or with a nested `version` /
  /// `current_version` object). Null when it names no policy or version.
  static AtlasPolicy? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final r = raw.cast<String, dynamic>();
    final nestedRaw = r['version'] is Map ? r['version'] : r['current_version'];
    final nested = nestedRaw is Map ? nestedRaw.cast<String, dynamic>() : null;
    Object? pick(String name) => r[name] ?? nested?[name];
    final key = _polStr(r['key']) ?? _polStr(r['policy']);
    final versionId = _polStr(pick('version_id')) ?? _polStr(nested?['id']);
    if (key == null || versionId == null) return null;
    final display = _polStr(r['display']);
    return AtlasPolicy(
      key: key,
      title: _polStr(r['title']) ?? key,
      display: display == 'scroll' || display == 'link' ? display! : 'checkbox',
      required: r['required'] != false,
      appliesTo: r['applies_to'] == 'sign_in_and_sign_up' ? 'sign_in_and_sign_up' : 'sign_up',
      versionId: versionId,
      version: _polStr(r['version']) ?? _polStr(nested?['version']) ?? '',
      contentHtml: _polStr(pick('content_html')),
      contentMarkdown: _polStr(pick('content_markdown')),
      contentUrl: _polStr(pick('content_url')),
      contentSha256: _polStr(pick('content_sha256')) ?? '',
      effectiveAt: _polMs(pick('effective_at')),
      summaryOfChanges: _polStr(pick('summary_of_changes')),
      reaccept: r['reaccept'] is bool ? r['reaccept'] as bool : null,
    );
  }

  /// Read a list of policies from any shape the API uses (`[..]`, `{policies}`, `{data}`).
  static List<AtlasPolicy> listFromJson(Object? body) {
    final list = body is List
        ? body
        : body is Map
            ? (body['policies'] ?? body['data'])
            : null;
    if (list is! List) return const [];
    return list.map(fromJson).whereType<AtlasPolicy>().toList(growable: false);
  }
}

/// The policies a held attempt is waiting on (`pending_policies`).
List<AtlasPolicy> pendingPoliciesOf(SignInAttempt? attempt) =>
    (attempt?.pendingPolicies ?? const <Map<String, dynamic>>[])
        .map(AtlasPolicy.fromJson)
        .whereType<AtlasPolicy>()
        .toList(growable: false);

/// The legacy single legal checkbox (send `consent: true` on sign-up), when the
/// instance has one.
class AtlasLegacyConsent {
  const AtlasLegacyConsent({required this.required, this.termsUrl, this.privacyUrl});
  final bool required;
  final String? termsUrl;
  final String? privacyUrl;
}

/// `GET /v1/client/policies`: the current version of every policy.
class AtlasPolicies {
  const AtlasPolicies(this.policies, this.legacyConsent);
  final List<AtlasPolicy> policies;
  final AtlasLegacyConsent? legacyConsent;

  /// Only the policies a sign-in has to show.
  List<AtlasPolicy> get signIn =>
      policies.where((p) => p.appliesTo == 'sign_in_and_sign_up').toList(growable: false);
}

/// A signed-in user's standing on one policy (`GET /v1/client/me/policies`).
class AtlasPolicyStanding {
  const AtlasPolicyStanding({
    required this.key,
    required this.title,
    this.acceptedVersion,
    this.currentVersion,
    this.needsReaccept = false,
    this.graceEndsAt,
    this.blocking = false,
  });

  final String key;
  final String title;
  final String? acceptedVersion;
  final String? currentVersion;
  final bool needsReaccept;

  /// Epoch milliseconds: sign-in still works until then.
  final int? graceEndsAt;

  /// The next sign-in will stop for this policy.
  final bool blocking;

  static List<AtlasPolicyStanding> listFromJson(Object? body) {
    final list = body is List
        ? body
        : body is Map
            ? (body['policies'] ?? body['data'])
            : null;
    if (list is! List) return const [];
    final out = <AtlasPolicyStanding>[];
    for (final item in list) {
      if (item is! Map) continue;
      final r = item.cast<String, dynamic>();
      final key = _polStr(r['key']) ?? _polStr(r['policy']);
      if (key == null) continue;
      out.add(AtlasPolicyStanding(
        key: key,
        title: _polStr(r['title']) ?? key,
        acceptedVersion: _polStr(r['accepted_version']),
        currentVersion: _polStr(r['current_version']),
        needsReaccept: r['needs_reaccept'] == true,
        graceEndsAt: _polMs(r['grace_ends_at']),
        blocking: r['blocking'] == true,
      ));
    }
    return out;
  }
}

/// One entry of `policy_acceptances`.
class PolicyAcceptance {
  const PolicyAcceptance({
    required this.policy,
    required this.versionId,
    required this.contentSha256,
    this.display,
    this.scrolledToEnd,
    this.viewMs,
    this.locale,
  });

  final String policy;
  final String versionId;
  final String contentSha256;
  final String? display;
  final bool? scrolledToEnd;
  final int? viewMs;
  final String? locale;

  Map<String, dynamic> toJson() => {
        'policy': policy,
        'version_id': versionId,
        'content_sha256': contentSha256,
        if (display != null) 'display': display,
        if (scrolledToEnd != null) 'scrolled_to_end': scrolledToEnd,
        if (viewMs != null) 'view_ms': viewMs,
        if (locale != null) 'locale': locale,
      };
}

/// The `accept_policies` request body: the acceptances plus the proof of the held
/// attempt, the one-time `policy_acceptance_token` (else the attempt's
/// `poll_secret`). The attempt id alone is never enough.
Map<String, dynamic> acceptPoliciesBody(
  List<PolicyAcceptance> acceptances,
  String? policyToken, [
  String? pollSecret,
]) =>
    {
      'policy_acceptances': acceptances.map((a) => a.toJson()).toList(growable: false),
      if (policyToken != null && policyToken.isNotEmpty)
        'policy_acceptance_token': policyToken
      else if (pollSecret != null && pollSecret.isNotEmpty)
        'poll_secret': pollSecret,
    };

/// What a redirect, custom-tab or web-auth callback URL carries about an attempt.
class AtlasRedirectResult {
  const AtlasRedirectResult({this.attemptId, this.status, this.ticket, this.policyToken});

  final String? attemptId;
  final String? status;

  /// `__atlas_ticket`: a completed attempt's one-time ticket.
  final String? ticket;

  /// `__atlas_policy_token`: the proof that goes with `accept_policies` (only with
  /// `needs_policy_acceptance`).
  final String? policyToken;

  /// Whether the attempt is held until policies are accepted.
  bool get needsPolicyAcceptance => status == 'needs_policy_acceptance';

  /// Read the `__atlas_*` parameters of a callback URL (query or fragment); null
  /// when it carries none.
  static AtlasRedirectResult? parse(String url) {
    final hashAt = url.indexOf('#');
    final fragment = hashAt < 0 ? '' : url.substring(hashAt + 1);
    final beforeHash = hashAt < 0 ? url : url.substring(0, hashAt);
    final qAt = beforeHash.indexOf('?');
    final query = qAt < 0 ? '' : beforeHash.substring(qAt + 1);
    final params = <String, String>{};
    for (final part in [...fragment.split('&'), ...query.split('&')]) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final k = eq < 0 ? part : part.substring(0, eq);
      final v = eq < 0 ? '' : part.substring(eq + 1);
      if (k.startsWith('__atlas_')) {
        try {
          params[k] = Uri.decodeQueryComponent(v);
        } catch (_) {
          params[k] = v;
        }
      }
    }
    final attempt = params['__atlas_attempt'];
    final status = params['__atlas_status'];
    final ticket = params['__atlas_ticket'];
    if (attempt == null && status == null && ticket == null) return null;
    return AtlasRedirectResult(
      attemptId: attempt,
      status: status,
      ticket: ticket,
      policyToken: status == 'needs_policy_acceptance' ? params['__atlas_policy_token'] : null,
    );
  }
}

/// Whether the server refused with "accept the policies" (422
/// `POLICY_ACCEPTANCE_REQUIRED`).
extension AtlasPolicyException on AtlasException {
  bool get isPolicyAcceptanceRequired =>
      code == 'POLICY_ACCEPTANCE_REQUIRED' ||
      errors.any((e) => e.code == 'POLICY_ACCEPTANCE_REQUIRED');
}

class _PolicyEntry {
  bool checked = false;
  bool scrolledToEnd = false;
  int viewMs = 0;
  int? openedAt;
}

/// The state behind every policy UI. Listen for changes; read [canSubmit] to
/// enable the submit button and [build] for the request body. State is kept per
/// version id, so a refreshed list (after a 422) keeps the ticks the user already
/// made on versions that did not change.
class PolicyAcceptanceController {
  PolicyAcceptanceController(
    List<AtlasPolicy> policies, {
    this.combined = true,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _list = policies;
  }

  /// One checkbox for every checkbox-mode policy (default) or one each.
  final bool combined;
  final int Function() _now;

  List<AtlasPolicy> _list = const [];
  final Map<String, _PolicyEntry> _entries = {};
  String? _open;
  final Set<void Function()> _listeners = {};

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _emit() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  _PolicyEntry _entry(String key) {
    final id = _list.where((p) => p.key == key).map((p) => p.versionId).firstOrNull ?? key;
    return _entries.putIfAbsent(id, _PolicyEntry.new);
  }

  List<AtlasPolicy> get policies => _list;

  /// The document open in the in-app viewer, or null.
  AtlasPolicy? get viewing => _list.where((p) => p.key == _open).firstOrNull;

  /// Replace the policies (e.g. after a refresh); ticks on unchanged versions survive.
  void setPolicies(List<AtlasPolicy> policies) {
    _list = policies;
    if (_open != null && !policies.any((p) => p.key == _open)) _open = null;
    _emit();
  }

  List<AtlasPolicy> get checkboxPolicies =>
      _list.where((p) => p.display == 'checkbox').toList(growable: false);
  List<AtlasPolicy> get scrollPolicies =>
      _list.where((p) => p.display == 'scroll').toList(growable: false);
  List<AtlasPolicy> get linkPolicies =>
      _list.where((p) => p.display == 'link').toList(growable: false);

  bool isChecked(String key) {
    final p = _list.where((x) => x.key == key).firstOrNull;
    if (p == null) return false;
    // A clickwrap sentence is accepted by submitting.
    if (p.display == 'link') return true;
    return _entry(key).checked;
  }

  void setChecked(String key, bool checked) {
    _entry(key).checked = checked;
    _emit();
  }

  /// Whether every checkbox-mode policy is ticked (the combined box).
  bool get combinedChecked {
    final boxes = checkboxPolicies;
    return boxes.isNotEmpty && boxes.every((p) => isChecked(p.key));
  }

  /// Tick or untick every checkbox-mode policy at once (the combined box).
  void setAllChecked(bool checked) {
    for (final p in checkboxPolicies) {
      _entry(p.key).checked = checked;
    }
    _emit();
  }

  /// The user accepted a scroll-mode policy in its dialog.
  void acceptScroll(String key) {
    final e = _entry(key);
    e.checked = true;
    e.scrolledToEnd = true;
    _emit();
  }

  /// The first scroll-mode policy still to be read and accepted, or null.
  AtlasPolicy? pendingScroll() =>
      scrollPolicies.where((p) => !isChecked(p.key)).firstOrNull;

  /// Open a document in the in-app viewer and start its reading clock.
  void openDocument(String key) {
    if (_open != null) closeDocument();
    if (!_list.any((p) => p.key == key)) return;
    _open = key;
    _entry(key).openedAt = _now();
    _emit();
  }

  void closeDocument() {
    final k = _open;
    if (k == null) return;
    stopClock(k);
    _open = null;
    _emit();
  }

  /// Start the reading clock for a policy shown some other way (a dialog).
  void startClock(String key) {
    final e = _entry(key);
    e.openedAt ??= _now();
  }

  void stopClock(String key) {
    final e = _entry(key);
    final at = e.openedAt;
    if (at == null) return;
    e.viewMs += (_now() - at).clamp(0, 1 << 31).toInt();
    e.openedAt = null;
  }

  /// The end of the document was reached while reading [key].
  void markScrolledToEnd(String key) {
    final e = _entry(key);
    if (!e.scrolledToEnd) {
      e.scrolledToEnd = true;
      _emit();
    }
  }

  bool hasScrolledToEnd(String key) => _entry(key).scrolledToEnd;

  int viewMs(String key) {
    final e = _entry(key);
    final at = e.openedAt;
    return e.viewMs + (at == null ? 0 : (_now() - at).clamp(0, 1 << 31).toInt());
  }

  /// The required policies still unaccepted.
  List<AtlasPolicy> missing() =>
      _list.where((p) => p.required && !isChecked(p.key)).toList(growable: false);

  /// Whether every required policy is accepted.
  bool satisfied() => missing().isEmpty;

  /// Whether the submit button may be enabled: scroll-mode policies are read on
  /// submit, so they do not block it.
  bool canSubmit() =>
      _list.every((p) => !p.required || p.display == 'scroll' || isChecked(p.key));

  /// The `policy_acceptances` body: every accepted policy (and every clickwrap one).
  List<PolicyAcceptance> build({String? locale}) {
    final out = <PolicyAcceptance>[];
    for (final p in _list) {
      if (!isChecked(p.key)) continue;
      final e = _entry(p.key);
      final ms = viewMs(p.key);
      out.add(PolicyAcceptance(
        policy: p.key,
        versionId: p.versionId,
        contentSha256: p.contentSha256,
        display: p.display,
        scrolledToEnd: p.display == 'scroll' || e.scrolledToEnd ? e.scrolledToEnd : null,
        viewMs: ms > 0 ? ms : null,
        locale: locale,
      ));
    }
    return out;
  }
}

/// In-app re-acceptance for a signed-in user: loads the standing, builds a
/// controller for the policies that need accepting, and posts the result.
class PolicyGate {
  PolicyGate(this._client, {this.locale});

  final AtlasClient _client;
  final String? locale;

  /// The policies that need re-acceptance (empty when none, or before [load]).
  List<AtlasPolicyStanding> pending = const [];
  bool loaded = false;

  Future<void> load() async {
    pending = (await _client.myPolicies()).where((p) => p.needsReaccept).toList(growable: false);
    loaded = true;
  }

  /// The soonest end of grace among the pending policies (epoch ms), or null.
  int? get graceEndsAt {
    final times = pending.map((p) => p.graceEndsAt).whereType<int>().toList()..sort();
    return times.isEmpty ? null : times.first;
  }

  /// A controller over the pending policies' current versions, all required.
  Future<PolicyAcceptanceController> begin() async {
    final wanted = pending.map((p) => p.key).toSet();
    final all = (await _client.policies(locale: locale)).policies;
    return PolicyAcceptanceController(
      all.where((p) => wanted.contains(p.key)).map((p) => p.copyWith(required: true)).toList(),
    );
  }

  Future<void> accept(PolicyAcceptanceController controller) async {
    await _client.acceptMyPolicies(controller.build(locale: locale));
    pending = const [];
  }
}

/// The Frontend API calls for policy acceptance.
extension AtlasPolicyApi on AtlasClient {
  /// `GET /v1/client/policies`: the current version of every policy (publishable key only).
  Future<AtlasPolicies> policies({String? locale}) async {
    final q = locale == null || locale.isEmpty ? '' : '?locale=${Uri.encodeQueryComponent(locale)}';
    final response = await _send('GET', '/v1/client/policies$q');
    _throwIfError(response);
    final root = _decode(response);
    final legacy = root['legacy_consent'];
    return AtlasPolicies(
      AtlasPolicy.listFromJson(root),
      legacy is Map
          ? AtlasLegacyConsent(
              required: legacy['required'] == true,
              termsUrl: _polStr(legacy['terms_url']),
              privacyUrl: _polStr(legacy['privacy_url']),
            )
          : null,
    );
  }

  /// `GET /v1/client/me/policies`: the signed-in user's standing on every policy.
  Future<List<AtlasPolicyStanding>> myPolicies() async =>
      AtlasPolicyStanding.listFromJson(await _authedJson('GET', '/v1/client/me/policies'));

  /// `POST /v1/client/me/policies/accept`: accept from inside the app (a banner
  /// during a grace window).
  Future<void> acceptMyPolicies(List<PolicyAcceptance> acceptances) async {
    await _authedJson('POST', '/v1/client/me/policies/accept', body: {
      'policy_acceptances': acceptances.map((a) => a.toJson()).toList(growable: false),
    });
  }

  /// A controller for the policies a sign-up must show: every policy with a
  /// published version. Required ones block the submit; optional ones may stay
  /// unticked.
  Future<PolicyAcceptanceController> signUpPolicyController({
    String? locale,
    bool combined = true,
  }) async =>
      PolicyAcceptanceController((await policies(locale: locale)).policies, combined: combined);

  /// A controller for the policies a held attempt is waiting on, with their
  /// content filled in from `GET /v1/client/policies` when the attempt only listed
  /// them. An attempt resumed from a redirect carries no list: every required
  /// policy is shown and the server checks each acceptance.
  Future<PolicyAcceptanceController> policyController(
    SignInAttempt? attempt, {
    String? locale,
    bool combined = true,
  }) async {
    var pending = pendingPoliciesOf(attempt);
    if (pending.isEmpty) {
      return PolicyAcceptanceController(
        (await policies(locale: locale)).policies.where((p) => p.required).toList(),
        combined: combined,
      );
    }
    if (pending.any((p) => !p.hasContent)) {
      final all = (await policies(locale: locale)).policies;
      pending = pending.map((p) {
        final full = all.where((a) => a.key == p.key).firstOrNull;
        if (full == null) return p;
        return AtlasPolicy(
          key: p.key,
          title: p.title != p.key ? p.title : full.title,
          display: p.display,
          required: full.required,
          appliesTo: full.appliesTo,
          versionId: p.versionId,
          version: p.version.isNotEmpty ? p.version : full.version,
          contentHtml: p.contentHtml ?? full.contentHtml,
          contentMarkdown: p.contentMarkdown ?? full.contentMarkdown,
          contentUrl: p.contentUrl ?? full.contentUrl,
          contentSha256: p.contentSha256.isNotEmpty ? p.contentSha256 : full.contentSha256,
          effectiveAt: p.effectiveAt ?? full.effectiveAt,
          summaryOfChanges: p.summaryOfChanges ?? full.summaryOfChanges,
          reaccept: p.reaccept,
        );
      }).toList();
    }
    // A sign-in acceptance is always required of the user, whatever the policy says elsewhere.
    return PolicyAcceptanceController(
      pending.map((p) => p.copyWith(required: true)).toList(),
      combined: combined,
    );
  }

  /// After the server answered 422 `POLICY_ACCEPTANCE_REQUIRED` (a policy was
  /// published or changed while the form was open): reload the policies into the
  /// controller so the form re-shows what is needed now. Returns whether [error]
  /// was that refusal.
  Future<bool> refreshPoliciesOnRequired(
    PolicyAcceptanceController controller,
    AtlasException error, {
    String? locale,
  }) async {
    if (!error.isPolicyAcceptanceRequired) return false;
    final fresh = (await policies(locale: locale)).policies;
    if (fresh.isNotEmpty) controller.setPolicies(fresh);
    return true;
  }

  /// Resume a sign-in the app was handed mid-stream: an OAuth, SSO or magic-link
  /// redirect that came back `needs_policy_acceptance` (parse the callback URL
  /// with [AtlasRedirectResult.parse]). The flow is seeded with the attempt id,
  /// its status and the policy token the redirect carried, so
  /// [SignInFlow.acceptPolicies] can continue it. Show the policies with
  /// [policyController].
  SignInFlow resumeSignIn(AtlasRedirectResult redirect) {
    final flow = createSignIn();
    flow._attempt = _seededAttempt(redirect);
    return flow;
  }

  /// Like [resumeSignIn], for a social or SSO sign-up that came back
  /// `needs_policy_acceptance`.
  SignUpFlow resumeSignUp(AtlasRedirectResult redirect) {
    final flow = createSignUp();
    flow._attempt = _seededAttempt(redirect);
    return flow;
  }
}

SignInAttempt _seededAttempt(AtlasRedirectResult redirect) {
  final id = redirect.attemptId;
  if (id == null) throw AtlasException.decoding('The redirect carries no attempt id.');
  return SignInAttempt(
    id: id,
    status: redirect.status ?? 'needs_policy_acceptance',
    policyAcceptanceToken: redirect.policyToken,
  );
}

// ---- Strings and small helpers ------------------------------------------------

/// Every string the prebuilt policy widgets draw. Override any of them (a
/// translation, different wording) by passing your own instance; `{name}` marks
/// a placeholder.
class AtlasPolicyStrings {
  const AtlasPolicyStrings({
    this.agreeCombined = 'I agree to the {policies}',
    this.agreeOne = 'I agree to the {policy}',
    this.clickwrap = 'By continuing you agree to the {policies}.',
    this.and = 'and',
    this.viewerBack = 'Back',
    this.version = 'Version {version}',
    this.effective = 'Effective {date}',
    this.scrollHint = 'Scroll to the end to accept',
    this.accept = 'Accept',
    this.decline = 'Decline',
    this.summaryTitle = 'What changed',
    this.reacceptTitle = '{policy} has been updated',
    this.reacceptIntro = 'Please review and accept the updated terms to continue.',
    this.pendingTitle = 'Accept to continue',
    this.pendingIntro = 'Please accept the following to continue signing in.',
    this.required = 'Please accept the {policy} to continue.',
    this.requiredGeneric = 'Please accept the required policies to continue.',
    this.declined = 'You need to accept the {policy} to use this app.',
    this.loading = 'Loading…',
    this.bannerTitle = 'Updated policies',
    this.bannerBody = 'We have updated: {policies}. Please review and accept.',
    this.bannerGrace = 'Accept by {date} to keep your access.',
    this.bannerReview = 'Review and accept',
    this.submit = 'Accept and continue',
  });

  final String agreeCombined;
  final String agreeOne;
  final String clickwrap;
  final String and;
  final String viewerBack;
  final String version;
  final String effective;
  final String scrollHint;
  final String accept;
  final String decline;
  final String summaryTitle;
  final String reacceptTitle;
  final String reacceptIntro;
  final String pendingTitle;
  final String pendingIntro;
  final String required;
  final String requiredGeneric;
  final String declined;
  final String loading;
  final String bannerTitle;
  final String bannerBody;
  final String bannerGrace;
  final String bannerReview;
  final String submit;

  AtlasPolicyStrings copyWith({String? pendingTitle, String? pendingIntro}) => AtlasPolicyStrings(
        agreeCombined: agreeCombined,
        agreeOne: agreeOne,
        clickwrap: clickwrap,
        and: and,
        viewerBack: viewerBack,
        version: version,
        effective: effective,
        scrollHint: scrollHint,
        accept: accept,
        decline: decline,
        summaryTitle: summaryTitle,
        reacceptTitle: reacceptTitle,
        reacceptIntro: reacceptIntro,
        pendingTitle: pendingTitle ?? this.pendingTitle,
        pendingIntro: pendingIntro ?? this.pendingIntro,
        required: required,
        requiredGeneric: requiredGeneric,
        declined: declined,
        loading: loading,
        bannerTitle: bannerTitle,
        bannerBody: bannerBody,
        bannerGrace: bannerGrace,
        bannerReview: bannerReview,
        submit: submit,
      );
}

/// Fill the `{name}` placeholders of a template.
String fillPolicyTemplate(String template, Map<String, String> vars) {
  var out = template;
  vars.forEach((k, v) => out = out.replaceAll('{$k}', v));
  return out;
}

/// Split a `{name}` template into the text before and after the placeholder (for
/// sentences that embed links).
(String, String) splitPolicyTemplate(String template, String name) {
  final at = template.indexOf('{$name}');
  if (at < 0) return (template, '');
  return (template.substring(0, at), template.substring(at + name.length + 2));
}

/// Join titles as "A, B and C".
String joinPolicyTitles(List<String> titles, String and) {
  if (titles.length <= 1) return titles.isEmpty ? '' : titles.first;
  return '${titles.sublist(0, titles.length - 1).join(', ')} $and ${titles.last}';
}

/// `2026-10-24` for an epoch-millisecond time, or an empty string.
String formatPolicyDate(int? epochMs) {
  if (epochMs == null) return '';
  return DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true).toIso8601String().substring(0, 10);
}

/// Whether a vertical scroller has reached its end (also true when the content fits).
bool isPolicyScrolledToEnd(double pixels, double maxScrollExtent, {double slack = 2}) =>
    pixels >= maxScrollExtent - slack;
