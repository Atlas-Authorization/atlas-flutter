part of 'atlas_client.dart';

// Billing, API keys, the active organization and step-up re-authentication over
// the Frontend API. Mirrors `packages/react` (billing / api-keys) and the web
// client's `/v1/client/billing/*` and `/v1/client/me/api_keys` calls.

double? _flex(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

String _seg(String v) => Uri.encodeComponent(v);

/// A display-only promotion on a plan.
class BillingPromotion {
  const BillingPromotion({required this.label, this.percentOff, this.amountOff, this.endsAt, this.code});

  factory BillingPromotion.fromJson(Map<String, dynamic> json) => BillingPromotion(
        label: json['label'] as String? ?? '',
        percentOff: _flex(json['percent_off']),
        amountOff: _flex(json['amount_off']),
        endsAt: _flex(json['ends_at']),
        code: json['code'] as String?,
      );

  final String label;
  final double? percentOff;
  final double? amountOff;
  final double? endsAt;
  final String? code;
}

/// How a plan is priced for display ([BillingPlan.priceView]).
class BillingPriceView {
  const BillingPriceView({
    required this.price,
    required this.originalPrice,
    required this.interval,
    required this.free,
    required this.trialDays,
    required this.promotionLabel,
    required this.promotionCode,
    required this.amount,
  });

  final String price;
  final String? originalPrice;

  /// `month` or `year`.
  final String interval;
  final bool free;
  final int? trialDays;
  final String? promotionLabel;
  final String? promotionCode;

  /// Minor units after any promotion.
  final int amount;
}

/// A plan the instance sells (`GET /v1/client/billing/plans`). Amounts are minor
/// units (cents).
class BillingPlan {
  const BillingPlan({
    required this.id,
    this.name = '',
    this.slug = '',
    this.interval = 'month',
    this.amount = 0,
    this.currency = 'usd',
    this.features = const [],
    this.audience = 'user',
    this.provider,
    this.kind,
    this.trialDays,
    this.annualAvailable = false,
    this.annualAmount,
    this.promotion,
    this.description,
    this.badge,
    this.sortOrder,
  });

  factory BillingPlan.fromJson(Map<String, dynamic> json) => BillingPlan(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        slug: json['slug'] as String? ?? '',
        interval: json['interval'] as String? ?? 'month',
        amount: _flex(json['amount']) ?? 0,
        currency: json['currency'] as String? ?? 'usd',
        features: (json['features'] as List?)?.whereType<String>().toList(growable: false) ?? const [],
        audience: json['audience'] as String? ?? 'user',
        provider: json['provider'] as String?,
        kind: json['kind'] as String?,
        trialDays: (json['trial_days'] as num?)?.toInt(),
        annualAvailable: json['annual_available'] == true,
        annualAmount: _flex(json['annual_amount']),
        promotion: json['promotion'] is Map
            ? BillingPromotion.fromJson((json['promotion'] as Map).cast<String, dynamic>())
            : null,
        description: json['description'] as String?,
        badge: json['badge'] as String?,
        sortOrder: (json['sort_order'] as num?)?.toInt(),
      );

  final String id;
  final String name;
  final String slug;

  /// `month` or `year`.
  final String interval;
  final double amount;
  final String currency;
  final List<String> features;

  /// `user` or `org`.
  final String audience;
  final String? provider;

  /// `base` (the subject's main plan) or `addon`.
  final String? kind;
  final int? trialDays;
  final bool annualAvailable;
  final double? annualAmount;
  final BillingPromotion? promotion;
  final String? description;
  final String? badge;
  final int? sortOrder;

  /// A minor-unit amount as a currency string: `12.34 USD` (no locale data in
  /// core Dart; format with `intl` in your app when you need a symbol).
  static String formatMoney(num minor, String currency) =>
      '${(minor / 100).toStringAsFixed(2)} ${currency.toUpperCase()}';

  /// The price, trial and promotion to show at [wantedInterval] (default the
  /// plan's own). A yearly interval uses [annualAmount] when the plan offers one;
  /// an expired promotion is ignored. Mirrors the web `planPriceView`.
  BillingPriceView priceView({String? wantedInterval, DateTime? now}) {
    final own = interval == 'year' ? 'year' : 'month';
    final chosen = wantedInterval ?? own;
    final annual = annualAvailable ? annualAmount : null;
    final base = chosen == own
        ? amount
        : (chosen == 'year' && annual != null ? annual : amount);
    final shown = (chosen == own || (chosen == 'year' && annual != null)) ? chosen : own;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final p = promotion;
    final promo = (p != null && p.endsAt != null && p.endsAt! <= nowMs) ? null : p;
    var finalAmount = base;
    if (promo?.percentOff != null && promo!.percentOff != 0) {
      finalAmount = (base * (1 - promo.percentOff! / 100)).roundToDouble();
    } else if (promo?.amountOff != null && promo!.amountOff != 0) {
      finalAmount = (base - promo.amountOff!).clamp(0, double.infinity).toDouble();
    }
    final discounted = promo != null && finalAmount < base;
    return BillingPriceView(
      price: formatMoney(finalAmount, currency),
      originalPrice: discounted ? formatMoney(base, currency) : null,
      interval: shown,
      free: finalAmount == 0 && base == 0,
      trialDays: (trialDays ?? 0) > 0 ? trialDays : null,
      promotionLabel: promo?.label,
      promotionCode: promo?.code,
      amount: finalAmount.round(),
    );
  }
}

/// A subject's subscription (`GET /v1/client/billing/subscription`). [status] is
/// null when the subject has never subscribed.
class BillingSubscription {
  const BillingSubscription({
    this.id,
    this.subjectType = 'user',
    this.status,
    this.plan,
    this.currentPeriodEnd,
    this.cancelAtPeriodEnd = false,
    this.interval,
    this.scheduledPlanId,
    this.trialEnd,
    this.trialEligible = false,
    this.subscriptions = const [],
  });

  factory BillingSubscription.fromJson(Map<String, dynamic> json) => BillingSubscription(
        id: json['id'] as String?,
        subjectType: json['subject_type'] as String? ?? 'user',
        status: json['status'] as String?,
        plan: json['plan'] is Map ? BillingPlan.fromJson((json['plan'] as Map).cast<String, dynamic>()) : null,
        currentPeriodEnd: _flex(json['current_period_end']),
        cancelAtPeriodEnd: json['cancel_at_period_end'] == true,
        interval: json['interval'] as String?,
        scheduledPlanId: json['scheduled_plan_id'] as String?,
        trialEnd: _flex(json['trial_end']),
        trialEligible: json['trial_eligible'] == true,
        subscriptions: (json['subscriptions'] as List?)
                ?.whereType<Map>()
                .map((e) => BillingSubscription.fromJson(e.cast<String, dynamic>()))
                .toList(growable: false) ??
            const [],
      );

  /// Statuses in which a subscription is still running.
  static const liveStatuses = ['active', 'trialing', 'past_due'];

  final String? id;
  final String subjectType;
  final String? status;
  final BillingPlan? plan;
  final double? currentPeriodEnd;
  final bool cancelAtPeriodEnd;
  final String? interval;
  final String? scheduledPlanId;
  final double? trialEnd;
  final bool trialEligible;

  /// Every subscription the subject holds (base plan and add-ons).
  final List<BillingSubscription> subscriptions;

  bool get isLive => status != null && liveStatuses.contains(status);

  /// Every subscription of the read: [subscriptions], or the one it reports.
  List<BillingSubscription> get all =>
      subscriptions.isNotEmpty ? subscriptions : (status != null ? [this] : const []);

  /// The live add-on subscriptions.
  List<BillingSubscription> get liveAddons =>
      all.where((s) => s.plan?.kind == 'addon' && s.isLive).toList(growable: false);
}

/// A stored invoice (billing history).
class BillingInvoice {
  const BillingInvoice({
    required this.id,
    this.number,
    this.status = '',
    this.amountDue = 0,
    this.amountPaid = 0,
    this.currency = 'usd',
    this.hostedInvoiceUrl,
    this.invoicePdf,
    this.createdAt = 0,
  });

  factory BillingInvoice.fromJson(Map<String, dynamic> json) => BillingInvoice(
        id: json['id'] as String? ?? '',
        number: json['number'] as String?,
        status: json['status'] as String? ?? '',
        amountDue: _flex(json['amount_due']) ?? 0,
        amountPaid: _flex(json['amount_paid']) ?? 0,
        currency: json['currency'] as String? ?? 'usd',
        hostedInvoiceUrl: json['hosted_invoice_url'] as String?,
        invoicePdf: json['invoice_pdf'] as String?,
        createdAt: _flex(json['created_at']) ?? 0,
      );

  final String id;
  final String? number;
  final String status;
  final double amountDue;
  final double amountPaid;
  final String currency;
  final String? hostedInvoiceUrl;
  final String? invoicePdf;
  final double createdAt;
}

/// The subject's default card.
class BillingPaymentMethod {
  const BillingPaymentMethod({required this.brand, required this.last4, required this.expMonth, required this.expYear});

  factory BillingPaymentMethod.fromJson(Map<String, dynamic> json) => BillingPaymentMethod(
        brand: json['brand'] as String? ?? '',
        last4: json['last4'] as String? ?? '',
        expMonth: (json['exp_month'] as num?)?.toInt() ?? 0,
        expYear: (json['exp_year'] as num?)?.toInt() ?? 0,
      );

  final String brand;
  final String last4;
  final int expMonth;
  final int expYear;
}

/// A live feature check. For UI only: enforce on your server or from the token.
class BillingFeatureCheck {
  const BillingFeatureCheck({
    required this.feature,
    required this.allowed,
    this.source,
    this.remaining,
    this.granted,
    this.usage,
    this.unlimited = false,
  });

  factory BillingFeatureCheck.fromJson(Map<String, dynamic> json) => BillingFeatureCheck(
        feature: json['feature'] as String? ?? '',
        allowed: json['allowed'] == true,
        source: json['source'] as String?,
        remaining: _flex(json['remaining']),
        granted: _flex(json['granted']),
        usage: _flex(json['usage']),
        unlimited: json['unlimited'] == true,
      );

  final String feature;
  final bool allowed;
  final String? source;
  final double? remaining;
  final double? granted;
  final double? usage;
  final bool unlimited;
}

/// The result of checking a discount code.
class BillingCouponCheck {
  const BillingCouponCheck({
    required this.valid,
    this.reason,
    this.percentOff,
    this.amountOff,
    this.currency,
    this.duration,
    this.durationMonths,
  });

  factory BillingCouponCheck.fromJson(Map<String, dynamic> json) {
    final d = json['discount'] is Map ? (json['discount'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    return BillingCouponCheck(
      valid: json['valid'] == true,
      reason: json['reason'] as String?,
      percentOff: _flex(d['percent_off']),
      amountOff: _flex(d['amount_off']),
      currency: d['currency'] as String?,
      duration: d['duration'] as String?,
      durationMonths: (d['duration_months'] as num?)?.toInt(),
    );
  }

  final bool valid;

  /// Why it is not valid (`invalid`, ...).
  final String? reason;
  final double? percentOff;
  final double? amountOff;
  final String? currency;
  final String? duration;
  final int? durationMonths;
}

/// An API key as its owner sees it. The secret is never part of it.
class UserApiKey {
  const UserApiKey({
    required this.id,
    this.subjectType = 'user',
    this.subjectId = '',
    this.name,
    this.prefix = '',
    this.type,
    this.scopes,
    this.lastUsedAt,
    this.expiresAt,
    this.revokedAt,
    this.revokedReason,
    this.organizationId,
    this.createdAt = 0,
  });

  factory UserApiKey.fromJson(Map<String, dynamic> json) => UserApiKey(
        id: json['id'] as String? ?? '',
        subjectType: json['subject_type'] as String? ?? 'user',
        subjectId: json['subject_id'] as String? ?? '',
        name: json['name'] as String?,
        prefix: json['prefix'] as String? ?? '',
        type: json['type'] as String?,
        scopes: (json['scopes'] as List?)?.whereType<String>().toList(growable: false),
        lastUsedAt: _flex(json['last_used_at']),
        expiresAt: _flex(json['expires_at']),
        revokedAt: _flex(json['revoked_at']),
        revokedReason: json['revoked_reason'] as String?,
        organizationId: json['organization_id'] as String?,
        createdAt: _flex(json['created_at']) ?? 0,
      );

  final String id;

  /// `user` or `organization`.
  final String subjectType;
  final String subjectId;
  final String? name;

  /// The public `ak_` head: recognises a key, cannot be used as one.
  final String prefix;
  final String? type;
  final List<String>? scopes;
  final double? lastUsedAt;
  final double? expiresAt;
  final double? revokedAt;

  /// Why it was revoked when the owner did not.
  final String? revokedReason;
  final String? organizationId;
  final double createdAt;

  /// Whether the key still works at [now].
  bool isActive({DateTime? now}) =>
      revokedAt == null && (expiresAt == null || expiresAt! > (now ?? DateTime.now()).millisecondsSinceEpoch);
}

/// The create response: the key plus its one-time [secret], shown exactly once.
class CreatedUserApiKey {
  const CreatedUserApiKey({required this.key, required this.secret});

  final UserApiKey key;

  /// The plaintext `ak_` key. Store it now; it is never returned again.
  final String secret;
}

/// The user's keys with the limits of the instance.
class UserApiKeyList {
  const UserApiKeyList({
    this.keys = const [],
    this.allowedScopes = const [],
    this.maxActiveKeys = 0,
    this.activeCount = 0,
  });

  factory UserApiKeyList.fromJson(Map<String, dynamic> json) => UserApiKeyList(
        keys: (json['data'] as List?)
                ?.whereType<Map>()
                .map((e) => UserApiKey.fromJson(e.cast<String, dynamic>()))
                .toList(growable: false) ??
            const [],
        allowedScopes: (json['allowed_scopes'] as List?)?.whereType<String>().toList(growable: false) ?? const [],
        maxActiveKeys: (json['max_active_keys'] as num?)?.toInt() ?? 0,
        activeCount: (json['active_count'] as num?)?.toInt() ?? 0,
      );

  final List<UserApiKey> keys;

  /// The scopes a new key may carry.
  final List<String> allowedScopes;

  /// The most active keys this user (or organization) may hold; 0 when unknown.
  final int maxActiveKeys;
  final int activeCount;
}

/// Billing over the Frontend API: plans, the subject's subscription, invoices
/// and card, and the hosted Checkout / Billing Portal URLs the provider issues.
/// There is no in-app card form: card entry stays on the provider's hosted page.
/// Pass `orgId` to act on an organization the user administers.
extension AtlasBillingApi on AtlasClient {
  String _billingPath(String path, Map<String, String?> query) {
    final q = query.entries.where((e) => e.value != null).map((e) => '${e.key}=${_seg(e.value!)}').join('&');
    return '/v1/client/billing/$path${q.isEmpty ? '' : '?$q'}';
  }

  String _subscriptionPath(String action, String? subscriptionId) => subscriptionId == null
      ? '/v1/client/billing/subscription/$action'
      : '/v1/client/billing/subscriptions/${_seg(subscriptionId)}/$action';

  /// The plans the instance sells, in display order.
  Future<List<BillingPlan>> billingPlans() async {
    final plans = _listOf(await _authedJson('GET', '/v1/client/billing/plans'), BillingPlan.fromJson);
    return [...plans]..sort((a, b) => (a.sortOrder ?? 0).compareTo(b.sortOrder ?? 0));
  }

  /// The subject's subscription (and add-ons); [orgId] reads an organization's.
  Future<BillingSubscription> billingSubscription({String? orgId}) async =>
      BillingSubscription.fromJson(await _authedJson('GET', _billingPath('subscription', {'org_id': orgId})));

  /// The subject's invoices, newest first.
  Future<List<BillingInvoice>> billingInvoices({String? orgId}) async =>
      _listOf(await _authedJson('GET', _billingPath('invoices', {'org_id': orgId})), BillingInvoice.fromJson);

  /// The subject's default card, or null when there is none.
  Future<BillingPaymentMethod?> billingPaymentMethod({String? orgId}) async {
    final pm = (await _authedJson('GET', _billingPath('payment_method', {'org_id': orgId})))['payment_method'];
    return pm is Map ? BillingPaymentMethod.fromJson(pm.cast<String, dynamic>()) : null;
  }

  Uri _hostedUrl(Map<String, dynamic> json) {
    final url = json['url'] as String?;
    if (url == null || url.isEmpty) throw AtlasException.decoding('The server returned no checkout URL.');
    return Uri.parse(url);
  }

  /// Start a provider Checkout and return its hosted URL; open it in a browser.
  /// [successUrl] / [cancelUrl] are where the provider returns, usually your app link.
  Future<Uri> billingCheckout({
    required String planId,
    required String successUrl,
    required String cancelUrl,
    String? orgId,
    String? interval,
    String? couponCode,
  }) async =>
      _hostedUrl(await _authedJson('POST', '/v1/client/billing/checkout', body: {
        'plan_id': planId,
        'success_url': successUrl,
        'cancel_url': cancelUrl,
        if (orgId != null) 'org_id': orgId,
        if (interval != null) 'interval': interval,
        if (couponCode != null && couponCode.isNotEmpty) 'coupon_code': couponCode,
      }));

  /// Open the provider's Billing Portal (card, invoices, cancel) and return its hosted URL.
  Future<Uri> billingPortal({
    required String returnUrl,
    String? orgId,
    String? subscriptionId,
  }) async =>
      _hostedUrl(await _authedJson('POST', '/v1/client/billing/portal', body: {
        'return_url': returnUrl,
        if (orgId != null) 'org_id': orgId,
        if (subscriptionId != null) 'subscription_id': subscriptionId,
      }));

  /// Switch a live subscription to another plan or interval, with no checkout.
  /// [atPeriodEnd] switches when the period ends instead of now (prorated).
  Future<BillingSubscription> billingChangePlan({
    required String planId,
    String? interval,
    bool atPeriodEnd = false,
    String? orgId,
    String? subscriptionId,
  }) async =>
      BillingSubscription.fromJson(await _authedJson('POST', _subscriptionPath('change', subscriptionId), body: {
        'plan_id': planId,
        'schedule_at_period_end': atPeriodEnd,
        if (orgId != null) 'org_id': orgId,
        if (interval != null) 'interval': interval,
      }));

  /// Cancel at the end of the period, or now with [immediately].
  Future<BillingSubscription> billingCancel({bool immediately = false, String? orgId, String? subscriptionId}) async =>
      BillingSubscription.fromJson(await _authedJson('POST', _subscriptionPath('cancel', subscriptionId), body: {
        'immediately': immediately,
        if (orgId != null) 'org_id': orgId,
      }));

  /// Undo a cancellation scheduled for the end of the period.
  Future<BillingSubscription> billingRestore({String? orgId, String? subscriptionId}) async =>
      BillingSubscription.fromJson(await _authedJson('POST', _subscriptionPath('restore', subscriptionId), body: {
        if (orgId != null) 'org_id': orgId,
      }));

  /// May the subject use [feature] (needing [required] units)? For UI only.
  Future<BillingFeatureCheck> billingCheck(String feature, {int? required, String? orgId}) async =>
      BillingFeatureCheck.fromJson(await _authedJson(
        'GET',
        _billingPath('check', {'feature': feature, 'required': required?.toString(), 'org_id': orgId}),
      ));

  /// Would this discount code work for this plan? For a checkout form's apply button.
  Future<BillingCouponCheck> billingValidateCoupon({required String planId, required String code, String? orgId}) async =>
      BillingCouponCheck.fromJson(await _authedJson('POST', '/v1/client/billing/coupons/validate', body: {
        'code': code.trim(),
        'plan_id': planId,
        if (orgId != null) 'org_id': orgId,
      }));
}

/// End-user API key self-service over `/v1/client/me/api_keys`: the signed-in
/// user's own `ak_` keys, or (with `organizationId`) an organization's. The
/// feature is off until the application enables it (a 403 on the list). Creating
/// a key needs a recent re-authentication: a stale session throws an
/// [AtlasException] whose `isStepUpRequired` is true; call [stepUp], then retry.
extension AtlasApiKeysApi on AtlasClient {
  /// The user's API keys, or an organization's with [organizationId]. With
  /// [bound], your own keys bound to that organization instead.
  Future<UserApiKeyList> listApiKeys({String? organizationId, String? type, bool bound = false}) async {
    final q = [
      if (organizationId != null) 'organization_id=${_seg(organizationId)}',
      if (bound && organizationId != null) 'subject_type=user',
      if (type != null) 'type=${_seg(type)}',
    ].join('&');
    return UserApiKeyList.fromJson(await _authedJson('GET', '/v1/client/me/api_keys${q.isEmpty ? '' : '?$q'}'));
  }

  /// Create a key. [expiresInSeconds] and [expiresAt] (epoch milliseconds) are
  /// mutually exclusive. [organizationId] creates the organization's key; with
  /// [bindToOrganization], your own key bound to that organization.
  Future<CreatedUserApiKey> createApiKey({
    String? name,
    int? expiresInSeconds,
    int? expiresAt,
    List<String>? scopes,
    String? organizationId,
    bool bindToOrganization = false,
    String? type,
  }) async {
    final json = await _authedJson('POST', '/v1/client/me/api_keys', body: {
      if (name != null) 'name': name,
      if (expiresInSeconds != null) 'expires_in_seconds': expiresInSeconds,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (scopes != null) 'scopes': scopes,
      if (organizationId != null) 'organization_id': organizationId,
      if (bindToOrganization) 'subject_type': 'user',
      if (type != null) 'type': type,
    });
    final secret = json['secret'] as String?;
    if (secret == null) throw AtlasException.decoding('The server returned no key secret.');
    return CreatedUserApiKey(key: UserApiKey.fromJson(json), secret: secret);
  }

  /// Rename a key; null clears the name.
  Future<UserApiKey> renameApiKey(String id, String? name) async =>
      UserApiKey.fromJson(await _authedJson('PATCH', '/v1/client/me/api_keys/${_seg(id)}', body: {'name': name}));

  /// Revoke a key. Immediate and permanent.
  Future<void> revokeApiKey(String id) async {
    await _authedJson('POST', '/v1/client/me/api_keys/${_seg(id)}/revoke');
  }
}

/// The active organization and step-up re-authentication.
extension AtlasSessionApi on AtlasClient {
  /// Switch the active organization for the current session
  /// (`POST /v1/client/sessions/:id/touch`). Pass null for the personal
  /// workspace. The re-minted JWT is persisted so later calls carry the new
  /// active-org claim. Returns the new active organization id.
  Future<String?> setActiveOrganization(String? organizationId) async {
    final stored = await tokenStore.load();
    if (stored == null) throw AtlasException.notSignedIn();
    final json = await _authedJson(
      'POST',
      '/v1/client/sessions/${_seg(stored.sessionId)}/touch',
      body: {'active_organization_id': organizationId},
    );
    // The touch response carries no new refresh token: keep the stored one.
    await tokenStore.save(AtlasSession(
      sessionId: json['id'] as String? ?? stored.sessionId,
      token: json['jwt'] as String? ?? stored.token,
      refreshToken: stored.refreshToken,
    ));
    return json['last_active_organization_id'] as String?;
  }

  /// The active organization id carried by the stored session token (`org_id`
  /// claim), or null for the personal workspace or when signed out.
  Future<String?> activeOrganizationId() async {
    final stored = await tokenStore.load();
    return stored == null ? null : OidcClaims.fromJwt(stored.token)?.orgId;
  }

  /// Step-up re-authentication (`POST /v1/client/me/step_up`): re-prove one
  /// credential (`password`, `totp`, `backup_code`, `email_code`, `phone_code`)
  /// before a sensitive action such as creating an API key. The fresh session
  /// token is persisted. A pending push/duo answer (202) returns without one.
  Future<void> stepUp({required String strategy, String? password, String? code}) async {
    final stored = await tokenStore.load();
    if (stored == null) throw AtlasException.notSignedIn();
    final json = await _authedJson('POST', '/v1/client/me/step_up', body: {
      'strategy': strategy,
      if (password != null) 'password': password,
      if (code != null) 'code': code,
    });
    await _persistStepUp(stored, json);
  }

  Future<bool> _persistStepUp(AtlasSession stored, Map<String, dynamic> json) async {
    final jwt = json['jwt'] as String?;
    if (jwt == null) return false;
    await tokenStore.save(AtlasSession(
      sessionId: json['id'] as String? ?? stored.sessionId,
      token: jwt,
      refreshToken: stored.refreshToken,
    ));
    return true;
  }

  /// Send the signed-in session a push step-up prompt
  /// (`POST /v1/client/me/step_up/push`; 429 `LOCKED` while prompts are paused
  /// after denials). Returns the number to show on this screen; the user taps it
  /// on their device. Then call [stepUpPush] until it returns true.
  Future<String?> beginPushStepUp() async =>
      (await _authedJson('POST', '/v1/client/me/step_up/push', body: <String, dynamic>{}))['number_match'] as String?;

  /// Ask whether the user answered the push prompt: true once they approved (the
  /// fresh token is persisted), false while it is still pending (202).
  Future<bool> stepUpPush() async {
    final stored = await tokenStore.load();
    if (stored == null) throw AtlasException.notSignedIn();
    return _persistStepUp(stored, await _authedJson('POST', '/v1/client/me/step_up', body: {'strategy': 'push'}));
  }

  /// Step up with a passkey: `POST /v1/client/me/step_up/passkey` for the
  /// challenge, the platform passkey ceremony (the injected
  /// [AtlasPasskeyAuthenticator]), then the assertion to `POST /v1/client/me/step_up`.
  /// The fresh session token is persisted.
  Future<void> stepUpWithPasskey() async {
    final stored = await tokenStore.load();
    if (stored == null) throw AtlasException.notSignedIn();
    final begin = await _authedJson('POST', '/v1/client/me/step_up/passkey', body: <String, dynamic>{});
    final assertion = await _passkeys.authenticate(AuthenticateRequestType.fromJson(begin));
    final json = await _authedJson('POST', '/v1/client/me/step_up', body: stepUpPasskeyBody(begin, assertion));
    await _persistStepUp(stored, json);
  }
}

/// The `POST /me/step_up` body for a passkey assertion: the sign-in finish body
/// without its `handle`, plus the strategy.
Map<String, String> stepUpPasskeyBody(Map<String, dynamic> begin, AuthenticateResponseType assertion) {
  final body = passkeyAssertionFinishBody(begin, assertion)..remove('handle');
  return {'strategy': 'passkey', ...body};
}
