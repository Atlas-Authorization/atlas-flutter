import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../atlas_client.dart';
import '../atlas_exception.dart';
import '../design.dart';
import '../models.dart';
import 'design_style.dart';

// Account-management screens, mirroring the web components: AtlasOrganizationSwitcher,
// AtlasPricingTable, AtlasBillingOverview, AtlasApiKeys and AtlasDeviceApproval.
// They read the instance's dashboard design (`GET /v1/appearance`) and the
// code-level AtlasAppearance exactly as AtlasSignIn does; with neither they follow
// the ambient Theme. Labels are the same English strings as the web catalog.
// The logic lives in the controllers (ChangeNotifiers), which are unit-testable
// without a widget tree. Checkout and the portal hand `onOpenUrl` the provider's
// hosted URL (open it with url_launcher).

String _messageOf(Object e) => e is AtlasException ? e.message : e.toString();

/// `Acme Corp!` becomes `acme-corp`: letters and digits only, dashes between.
String atlasOrganizationSlug(String name) {
  final out = StringBuffer();
  var last = '';
  for (final ch in name.toLowerCase().split('')) {
    if (RegExp('[a-z0-9]').hasMatch(ch)) {
      out.write(ch);
      last = ch;
    } else if (last.isNotEmpty && last != '-') {
      out.write('-');
      last = '-';
    }
  }
  return out.toString().replaceAll(RegExp(r'^-+|-+$'), '');
}

/* ── organization switcher ──────────────────────────────────────────────────── */

/// Lists the user's organizations, switches the active one and creates a new one.
class AtlasOrganizationSwitcherController extends ChangeNotifier {
  AtlasOrganizationSwitcherController(this.client);

  final AtlasClient client;
  List<OrganizationMembership> memberships = const [];

  /// The active organization id; null = the personal account.
  String? activeOrganizationId;
  bool isLoaded = false;
  bool isBusy = false;
  String? message;

  Future<void> load() async {
    try {
      memberships = await client.listOrganizationMemberships();
      activeOrganizationId = await client.activeOrganizationId();
      message = null;
    } on AtlasException catch (e) {
      message = _messageOf(e);
    }
    isLoaded = true;
    notifyListeners();
  }

  /// Switch the active organization; null selects the personal account.
  Future<void> select(String? organizationId) async {
    isBusy = true;
    notifyListeners();
    try {
      await client.setActiveOrganization(organizationId);
      activeOrganizationId = organizationId;
      message = null;
    } on AtlasException catch (e) {
      message = _messageOf(e);
    }
    isBusy = false;
    notifyListeners();
  }

  /// Create an organization and make it active. True on success.
  Future<bool> create(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    isBusy = true;
    notifyListeners();
    try {
      final org = await client.createOrganization(name: trimmed, slug: atlasOrganizationSlug(trimmed));
      await client.setActiveOrganization(org.id);
      memberships = await client.listOrganizationMemberships();
      activeOrganizationId = org.id;
      message = null;
      isBusy = false;
      notifyListeners();
      return true;
    } on AtlasException catch (e) {
      message = _messageOf(e);
      isBusy = false;
      notifyListeners();
      return false;
    }
  }
}

/* ── billing ────────────────────────────────────────────────────────────────── */

/// Plans, the subject's subscription, invoices and card.
///
/// [orgId] bills an organization the user administers instead of the user;
/// [returnUrl] is where the provider sends the user back (your app link).
class AtlasBillingController extends ChangeNotifier {
  AtlasBillingController(this.client, {this.orgId, required this.returnUrl});

  final AtlasClient client;
  final String? orgId;
  final String returnUrl;
  List<BillingPlan> plans = const [];
  BillingSubscription? subscription;
  List<BillingInvoice> invoices = const [];
  BillingPaymentMethod? paymentMethod;
  bool isLoaded = false;
  String? busyPlanId;
  String? message;

  Future<void> load() async {
    try {
      plans = await client.billingPlans();
      try {
        subscription = await client.billingSubscription(orgId: orgId);
      } on AtlasException {
        subscription = null;
      }
      try {
        invoices = await client.billingInvoices(orgId: orgId);
      } on AtlasException {
        invoices = const [];
      }
      try {
        paymentMethod = await client.billingPaymentMethod(orgId: orgId);
      } on AtlasException {
        paymentMethod = null;
      }
      message = null;
    } on AtlasException catch (e) {
      message = _messageOf(e);
    }
    isLoaded = true;
    notifyListeners();
  }

  /// Buy a plan, or switch in place when a base subscription is already live.
  /// Returns the hosted Checkout URL to open, or null when the plan was switched.
  Future<Uri?> subscribe(BillingPlan plan, {String? interval}) async {
    busyPlanId = plan.id;
    notifyListeners();
    try {
      final current = subscription;
      if (plan.kind != 'addon' && current != null && current.isLive && current.plan != null && current.plan!.kind != 'addon') {
        subscription = await client.billingChangePlan(planId: plan.id, interval: interval, orgId: orgId);
        message = null;
        return null;
      }
      final url = await client.billingCheckout(
        planId: plan.id,
        successUrl: returnUrl,
        cancelUrl: returnUrl,
        orgId: orgId,
        interval: plan.annualAvailable ? interval : null,
      );
      message = null;
      return url;
    } on AtlasException catch (e) {
      message = _messageOf(e);
      return null;
    } finally {
      busyPlanId = null;
      notifyListeners();
    }
  }

  Future<Uri?> portalUrl({String? subscriptionId}) async {
    try {
      final url = await client.billingPortal(returnUrl: returnUrl, orgId: orgId, subscriptionId: subscriptionId);
      message = null;
      return url;
    } on AtlasException catch (e) {
      message = _messageOf(e);
      notifyListeners();
      return null;
    }
  }

  Future<void> cancel() => _mutate(() => client.billingCancel(orgId: orgId));
  Future<void> restore() => _mutate(() => client.billingRestore(orgId: orgId));

  Future<void> _mutate(Future<BillingSubscription> Function() work) async {
    try {
      subscription = await work();
      message = null;
    } on AtlasException catch (e) {
      message = _messageOf(e);
    }
    notifyListeners();
  }
}

/* ── API keys ───────────────────────────────────────────────────────────────── */

enum AtlasApiKeysStatus { loading, ready, disabled, failed }

/// List, create, rename and revoke the user's (or an organization's) API keys,
/// with the step-up wired in.
class AtlasApiKeysController extends ChangeNotifier {
  AtlasApiKeysController(this.client, {this.organizationId});

  final AtlasClient client;
  final String? organizationId;
  AtlasApiKeysStatus status = AtlasApiKeysStatus.loading;
  UserApiKeyList list = const UserApiKeyList();
  String? message;

  /// True when the last create needs a fresh re-authentication ([completeStepUp]).
  bool needsStepUp = false;

  /// The one-time secret of the key just created; call [dismissSecret] once copied.
  String? createdSecret;
  ({String? name, int? expiresInSeconds, List<String>? scopes})? _parked;

  Future<void> load() async {
    try {
      list = await client.listApiKeys(organizationId: organizationId);
      status = AtlasApiKeysStatus.ready;
      message = null;
    } on AtlasException catch (e) {
      status = e.status == 403 ? AtlasApiKeysStatus.disabled : AtlasApiKeysStatus.failed;
      message = _messageOf(e);
    }
    notifyListeners();
  }

  Future<void> create({String? name, int? expiresInDays, List<String>? scopes}) {
    final trimmed = name?.trim();
    return _attempt(
      name: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      expiresInSeconds: expiresInDays == null ? null : expiresInDays * 86400,
      scopes: (scopes == null || scopes.isEmpty) ? null : scopes,
    );
  }

  Future<void> _attempt({String? name, int? expiresInSeconds, List<String>? scopes}) async {
    try {
      final created = await client.createApiKey(
        name: name,
        expiresInSeconds: expiresInSeconds,
        scopes: scopes,
        organizationId: organizationId,
      );
      createdSecret = created.secret;
      needsStepUp = false;
      _parked = null;
      message = null;
      await load();
    } on AtlasException catch (e) {
      if (e.isStepUpRequired) {
        _parked = (name: name, expiresInSeconds: expiresInSeconds, scopes: scopes);
        needsStepUp = true;
      } else {
        message = _messageOf(e);
      }
      notifyListeners();
    }
  }

  /// Re-authenticate with the password, then finish the parked create.
  Future<void> completeStepUp(String password) async {
    try {
      await client.stepUp(strategy: 'password', password: password);
    } on AtlasException catch (e) {
      message = _messageOf(e);
      notifyListeners();
      return;
    }
    final p = _parked;
    if (p != null) await _attempt(name: p.name, expiresInSeconds: p.expiresInSeconds, scopes: p.scopes);
  }

  Future<void> rename(UserApiKey key, String name) async {
    try {
      await client.renameApiKey(key.id, name.isEmpty ? null : name);
      await load();
    } on AtlasException catch (e) {
      message = _messageOf(e);
      notifyListeners();
    }
  }

  Future<void> revoke(UserApiKey key) async {
    try {
      await client.revokeApiKey(key.id);
      await load();
    } on AtlasException catch (e) {
      message = _messageOf(e);
      notifyListeners();
    }
  }

  void dismissSecret() {
    createdSecret = null;
    notifyListeners();
  }

  void cancelStepUp() {
    _parked = null;
    needsStepUp = false;
    notifyListeners();
  }
}

/* ── device approval ────────────────────────────────────────────────────────── */

enum AtlasDeviceApprovalPhase { entering, pending, approved, denied }

/// Approve (or deny) the code a TV, console or CLI shows. A QR code that carries
/// `?user_code=` can be handed to [lookup] through [AtlasClient.userCodeFromUrl].
class AtlasDeviceApprovalController extends ChangeNotifier {
  AtlasDeviceApprovalController(this.client);

  final AtlasClient client;
  AtlasDeviceApprovalPhase phase = AtlasDeviceApprovalPhase.entering;
  DeviceAuthorization? authorization;
  String? message;
  bool needsStepUp = false;
  bool isBusy = false;

  Future<void> lookup(String input) async {
    isBusy = true;
    notifyListeners();
    try {
      authorization = await client.lookupDeviceAuthorization(input);
      phase = AtlasDeviceApprovalPhase.pending;
      message = null;
    } on AtlasException {
      message = 'That code is not valid. It may have expired or already been used.';
    }
    isBusy = false;
    notifyListeners();
  }

  Future<void> decide({required bool approve}) async {
    final auth = authorization;
    if (auth == null) return;
    isBusy = true;
    notifyListeners();
    try {
      if (approve) {
        await client.approveDeviceAuthorization(auth);
      } else {
        await client.denyDeviceAuthorization(auth);
      }
      phase = approve ? AtlasDeviceApprovalPhase.approved : AtlasDeviceApprovalPhase.denied;
      needsStepUp = false;
      message = null;
    } on AtlasException catch (e) {
      if (e.isStepUpRequired) {
        needsStepUp = true;
      } else {
        message = _messageOf(e);
      }
    }
    isBusy = false;
    notifyListeners();
  }

  Future<void> completeStepUp(String password) async {
    try {
      await client.stepUp(strategy: 'password', password: password);
    } on AtlasException catch (e) {
      message = _messageOf(e);
      notifyListeners();
      return;
    }
    await decide(approve: true);
  }

  void reset() {
    phase = AtlasDeviceApprovalPhase.entering;
    authorization = null;
    message = null;
    needsStepUp = false;
    notifyListeners();
  }
}

/* ── widgets ────────────────────────────────────────────────────────────────── */

/// Resolves the design for a management screen (fetched once, code wins) and
/// wraps [builder] in the design's Theme; with no design the ambient Theme stays.
class _AtlasThemed extends StatefulWidget {
  const _AtlasThemed({
    required this.client,
    required this.appearance,
    required this.appearanceInfo,
    required this.fonts,
    required this.builder,
  });

  final AtlasClient client;
  final AtlasAppearance? appearance;
  final AtlasAppearanceInfo? appearanceInfo;
  final Map<String, String> fonts;
  final Widget Function(BuildContext context, AtlasDesignStyle? style) builder;

  @override
  State<_AtlasThemed> createState() => _AtlasThemedState();
}

class _AtlasThemedState extends State<_AtlasThemed> {
  AtlasAppearanceInfo? _info;

  @override
  void initState() {
    super.initState();
    _info = widget.appearanceInfo;
    if (_info == null) {
      // A failed fetch is not a user-facing error: the screen keeps its default look.
      widget.client.appearance().then((info) {
        if (mounted) setState(() => _info = info);
      }, onError: (Object _) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final design = AtlasDesign.resolve(_info?.design, widget.appearance);
    if (design == null) return widget.builder(context, null);
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final style = AtlasDesignStyle(design, platformIsDark: dark, fonts: widget.fonts);
    return Theme(
      data: style.theme(Theme.of(context)),
      child: Builder(builder: (context) => widget.builder(context, style)),
    );
  }
}

Widget _error(BuildContext context, String? message) =>
    message == null ? const SizedBox.shrink() : Text(message, style: TextStyle(color: Theme.of(context).colorScheme.error));

/// The active organization with a menu to switch (or return to the personal
/// account) and, when [allowCreate], "or create a new organization".
class AtlasOrganizationSwitcher extends StatefulWidget {
  const AtlasOrganizationSwitcher({
    super.key,
    required this.client,
    this.allowCreate = true,
    this.onChange,
    this.appearance,
    this.appearanceInfo,
    this.fonts = const {},
  });

  final AtlasClient client;
  final bool allowCreate;

  /// Called with the new active organization id (null = personal).
  final ValueChanged<String?>? onChange;
  final AtlasAppearance? appearance;
  final AtlasAppearanceInfo? appearanceInfo;
  final Map<String, String> fonts;

  @override
  State<AtlasOrganizationSwitcher> createState() => _AtlasOrganizationSwitcherState();
}

class _AtlasOrganizationSwitcherState extends State<AtlasOrganizationSwitcher> {
  late final AtlasOrganizationSwitcherController _c = AtlasOrganizationSwitcherController(widget.client)..load();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create organization'),
        content: TextField(controller: name, decoration: const InputDecoration(labelText: 'Organization name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create organization')),
        ],
      ),
    );
    if (ok == true && await _c.create(name.text)) widget.onChange?.call(_c.activeOrganizationId);
    name.dispose();
  }

  @override
  Widget build(BuildContext context) => _AtlasThemed(
        client: widget.client,
        appearance: widget.appearance,
        appearanceInfo: widget.appearanceInfo,
        fonts: widget.fonts,
        builder: (context, style) => ListenableBuilder(
          listenable: _c,
          builder: (context, _) {
            final active = _c.memberships.where((m) => m.organization.id == _c.activeOrganizationId);
            final label = active.isEmpty ? 'Personal account' : active.first.organization.name;
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              PopupMenuButton<String>(
                key: const Key('atlas.org_switcher'),
                tooltip: 'Switch organization',
                enabled: !_c.isBusy,
                onSelected: (value) async {
                  if (value == '\u0000create') return _create();
                  final id = value == '\u0000personal' ? null : value;
                  await _c.select(id);
                  if (_c.message == null) widget.onChange?.call(id);
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: '\u0000personal',
                    child: Text(_c.activeOrganizationId == null ? 'Personal account (active)' : 'Personal account'),
                  ),
                  for (final m in _c.memberships)
                    PopupMenuItem(
                      value: m.organization.id,
                      child: Text(m.organization.id == _c.activeOrganizationId
                          ? '${m.organization.name} (active)'
                          : m.organization.name),
                    ),
                  if (widget.allowCreate)
                    const PopupMenuItem(value: '\u0000create', child: Text('or create a new organization')),
                ],
                child: Padding(padding: const EdgeInsets.all(8), child: Text(label)),
              ),
              _error(context, _c.message),
            ]);
          },
        ),
      );
}

/// The instance's plans as cards: price (promotion, trial, monthly/yearly switch),
/// features and a Subscribe button that starts the provider's hosted Checkout
/// through [onOpenUrl]; the plan the subject is on shows Manage billing instead.
class AtlasPricingTable extends StatefulWidget {
  const AtlasPricingTable({
    super.key,
    required this.client,
    required this.returnUrl,
    required this.onOpenUrl,
    this.orgId,
    this.audience,
    this.appearance,
    this.appearanceInfo,
    this.fonts = const {},
  });

  final AtlasClient client;
  final String returnUrl;
  final ValueChanged<Uri> onOpenUrl;
  final String? orgId;

  /// `user` or `org` to show only those plans.
  final String? audience;
  final AtlasAppearance? appearance;
  final AtlasAppearanceInfo? appearanceInfo;
  final Map<String, String> fonts;

  @override
  State<AtlasPricingTable> createState() => _AtlasPricingTableState();
}

class _AtlasPricingTableState extends State<AtlasPricingTable> {
  late final AtlasBillingController _c =
      AtlasBillingController(widget.client, orgId: widget.orgId, returnUrl: widget.returnUrl)..load();
  String _interval = 'month';

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _AtlasThemed(
        client: widget.client,
        appearance: widget.appearance,
        appearanceInfo: widget.appearanceInfo,
        fonts: widget.fonts,
        builder: (context, style) => ListenableBuilder(
          listenable: _c,
          builder: (context, _) {
            final shown = _c.plans.where((p) => widget.audience == null || p.audience == widget.audience).toList();
            return ListView(padding: const EdgeInsets.all(16), children: [
              if (shown.any((p) => p.annualAvailable))
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'month', label: Text('Monthly')),
                    ButtonSegment(value: 'year', label: Text('Yearly')),
                  ],
                  selected: {_interval},
                  onSelectionChanged: (s) => setState(() => _interval = s.first),
                ),
              for (final plan in shown) _card(context, plan),
              _error(context, _c.message),
            ]);
          },
        ),
      );

  Widget _card(BuildContext context, BillingPlan plan) {
    final isAddon = plan.kind == 'addon';
    final held = _c.subscription?.liveAddons.where((s) => s.plan?.id == plan.id).firstOrNull;
    final current = isAddon ? held != null : plan.id == _c.subscription?.plan?.id;
    final view = plan.priceView(wantedInterval: _interval);
    final theme = Theme.of(context);
    return Card(
      key: Key('atlas.plan.${plan.id}'),
      shape: current ? RoundedRectangleBorder(side: BorderSide(color: theme.colorScheme.primary), borderRadius: BorderRadius.circular(12)) : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(plan.name, style: theme.textTheme.titleMedium),
          if (plan.badge != null) Text(plan.badge!, style: theme.textTheme.bodySmall),
          if (plan.description != null) Text(plan.description!),
          if (view.promotionLabel != null) Text(view.promotionLabel!, style: theme.textTheme.bodySmall),
          Row(children: [
            if (view.originalPrice != null)
              Text('${view.originalPrice} ', style: const TextStyle(decoration: TextDecoration.lineThrough)),
            Text(view.free ? 'Free' : '${view.price} / ${view.interval == 'year' ? 'year' : 'month'}',
                style: theme.textTheme.titleMedium),
          ]),
          if (view.trialDays != null) Text('${view.trialDays}-day free trial', style: theme.textTheme.bodySmall),
          if (view.promotionCode != null) Text('Use code ${view.promotionCode} at checkout', style: theme.textTheme.bodySmall),
          for (final f in plan.features) Text('• $f'),
          const SizedBox(height: 8),
          if (current)
            FilledButton(
              onPressed: () async {
                final url = await _c.portalUrl(subscriptionId: held?.id);
                if (url != null) widget.onOpenUrl(url);
              },
              child: const Text('Manage billing'),
            )
          else
            FilledButton(
              onPressed: _c.busyPlanId == plan.id
                  ? null
                  : () async {
                      final url = await _c.subscribe(plan, interval: _interval);
                      if (url != null) {
                        widget.onOpenUrl(url);
                      } else {
                        await _c.load();
                      }
                    },
              child: const Text('Subscribe'),
            ),
        ]),
      ),
    );
  }
}

/// The subscription's status, the card on file, Manage billing / cancel / resume,
/// and the invoice history.
class AtlasBillingOverview extends StatefulWidget {
  const AtlasBillingOverview({
    super.key,
    required this.client,
    required this.returnUrl,
    required this.onOpenUrl,
    this.orgId,
    this.appearance,
    this.appearanceInfo,
    this.fonts = const {},
  });

  final AtlasClient client;
  final String returnUrl;
  final ValueChanged<Uri> onOpenUrl;
  final String? orgId;
  final AtlasAppearance? appearance;
  final AtlasAppearanceInfo? appearanceInfo;
  final Map<String, String> fonts;

  @override
  State<AtlasBillingOverview> createState() => _AtlasBillingOverviewState();
}

class _AtlasBillingOverviewState extends State<AtlasBillingOverview> {
  late final AtlasBillingController _c =
      AtlasBillingController(widget.client, orgId: widget.orgId, returnUrl: widget.returnUrl)..load();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String _date(double millis) => DateTime.fromMillisecondsSinceEpoch(millis.toInt()).toIso8601String().substring(0, 10);

  @override
  Widget build(BuildContext context) => _AtlasThemed(
        client: widget.client,
        appearance: widget.appearance,
        appearanceInfo: widget.appearanceInfo,
        fonts: widget.fonts,
        builder: (context, style) => ListenableBuilder(
          listenable: _c,
          builder: (context, _) {
            final sub = _c.subscription;
            final theme = Theme.of(context);
            return ListView(padding: const EdgeInsets.all(16), children: [
              if (sub?.status != null) ...[
                Text(sub!.plan?.name ?? 'Subscription', style: theme.textTheme.titleMedium),
                Text(sub.status!.replaceAll('_', ' '), style: theme.textTheme.bodySmall),
                if (sub.currentPeriodEnd != null)
                  Text('${sub.cancelAtPeriodEnd ? 'Ends' : 'Renews'} ${_date(sub.currentPeriodEnd!)}',
                      style: theme.textTheme.bodySmall),
                if (_c.paymentMethod != null)
                  Text('${_c.paymentMethod!.brand} ending ${_c.paymentMethod!.last4}, expires ${_c.paymentMethod!.expMonth}/${_c.paymentMethod!.expYear}',
                      style: theme.textTheme.bodySmall),
                Wrap(spacing: 8, children: [
                  FilledButton(
                    onPressed: () async {
                      final url = await _c.portalUrl();
                      if (url != null) widget.onOpenUrl(url);
                    },
                    child: const Text('Manage billing'),
                  ),
                  if (sub.isLive && sub.cancelAtPeriodEnd)
                    OutlinedButton(onPressed: _c.restore, child: const Text('Resume subscription')),
                  if (sub.isLive && !sub.cancelAtPeriodEnd)
                    OutlinedButton(onPressed: _c.cancel, child: const Text('Cancel subscription')),
                ]),
              ] else if (_c.isLoaded)
                const Text('No subscription yet.'),
              const SizedBox(height: 16),
              Text('Invoices', style: theme.textTheme.titleMedium),
              if (_c.invoices.isEmpty && _c.isLoaded) const Text('No invoices yet.'),
              for (final inv in _c.invoices)
                ListTile(
                  dense: true,
                  title: Text(inv.number ?? inv.id),
                  subtitle: Text(inv.status),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(BillingPlan.formatMoney(inv.amountDue, inv.currency)),
                    if (inv.hostedInvoiceUrl != null)
                      TextButton(onPressed: () => widget.onOpenUrl(Uri.parse(inv.hostedInvoiceUrl!)), child: const Text('View')),
                  ]),
                ),
              _error(context, _c.message),
            ]);
          },
        ),
      );
}

/// The user's (or, with [organizationId], an organization's) API keys: list,
/// create (name, expiry, scopes, with the re-authentication prompt on a stale
/// session), rename and revoke. The new key's secret is shown once with Copy.
class AtlasApiKeys extends StatefulWidget {
  const AtlasApiKeys({
    super.key,
    required this.client,
    this.organizationId,
    this.appearance,
    this.appearanceInfo,
    this.fonts = const {},
  });

  final AtlasClient client;
  final String? organizationId;
  final AtlasAppearance? appearance;
  final AtlasAppearanceInfo? appearanceInfo;
  final Map<String, String> fonts;

  @override
  State<AtlasApiKeys> createState() => _AtlasApiKeysState();
}

class _AtlasApiKeysState extends State<AtlasApiKeys> {
  late final AtlasApiKeysController _c = AtlasApiKeysController(widget.client, organizationId: widget.organizationId)..load();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String _date(double millis) => DateTime.fromMillisecondsSinceEpoch(millis.toInt()).toIso8601String().substring(0, 10);

  String _status(UserApiKey key) {
    if (key.revokedAt != null) return 'Revoked';
    if (!key.isActive()) return 'Expired';
    final used = key.lastUsedAt != null ? 'Last used ${_date(key.lastUsedAt!)}' : 'Never used';
    return key.expiresAt != null ? '$used · Expires ${_date(key.expiresAt!)}' : used;
  }

  Future<void> _createDialog() async {
    final name = TextEditingController();
    final password = TextEditingController();
    var days = 0;
    final picked = <String>{};
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => ListenableBuilder(
          listenable: _c,
          builder: (context, _) => AlertDialog(
            title: const Text('Create key'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. CI pipeline')),
                const SizedBox(height: 8),
                const Text('Expires'),
                Wrap(spacing: 4, children: [
                  for (final (d, label) in [(0, 'Never'), (30, 'In 30 days'), (90, 'In 90 days'), (365, 'In 365 days')])
                    ChoiceChip(label: Text(label), selected: days == d, onSelected: (_) => setDialog(() => days = d)),
                ]),
                if (_c.list.allowedScopes.isNotEmpty) ...[
                  const Text('Scopes'),
                  for (final s in _c.list.allowedScopes)
                    CheckboxListTile(
                      dense: true,
                      title: Text(s),
                      value: picked.contains(s),
                      onChanged: (on) => setDialog(() => on == true ? picked.add(s) : picked.remove(s)),
                    ),
                ],
                if (_c.needsStepUp) ...[
                  const Text('Enter your password to confirm.'),
                  TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
                ],
                _error(context, _c.message),
              ]),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _c.cancelStepUp();
                  Navigator.pop(context);
                },
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  if (_c.needsStepUp) {
                    await _c.completeStepUp(password.text);
                  } else {
                    await _c.create(name: name.text, expiresInDays: days == 0 ? null : days, scopes: picked.toList()..sort());
                  }
                  if (!_c.needsStepUp && _c.message == null && context.mounted) Navigator.pop(context);
                },
                child: Text(_c.needsStepUp ? 'Confirm' : 'Create key'),
              ),
            ],
          ),
        ),
      ),
    );
    name.dispose();
    password.dispose();
  }

  Future<void> _secretDialog(String secret) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Copy your new key'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(secret),
          const SizedBox(height: 8),
          const Text('This is the only time it will be shown. If you lose it, revoke it and create another.'),
        ]),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: secret));
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ],
      ),
    );
    _c.dismissSecret();
  }

  @override
  Widget build(BuildContext context) => _AtlasThemed(
        client: widget.client,
        appearance: widget.appearance,
        appearanceInfo: widget.appearanceInfo,
        fonts: widget.fonts,
        builder: (context, style) => ListenableBuilder(
          listenable: _c,
          builder: (context, _) {
            final theme = Theme.of(context);
            final secret = _c.createdSecret;
            if (secret != null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _secretDialog(secret) : null);
            final atLimit = _c.list.maxActiveKeys > 0 && _c.list.activeCount >= _c.list.maxActiveKeys;
            return ListView(padding: const EdgeInsets.all(16), children: [
              Text('API keys', style: theme.textTheme.titleMedium),
              Text(
                widget.organizationId == null
                    ? 'Keys let scripts and integrations act as you. Treat them like passwords.'
                    : 'Keys let scripts and integrations act as this organization. Treat them like passwords.',
                style: theme.textTheme.bodySmall,
              ),
              if (_c.status == AtlasApiKeysStatus.disabled)
                const Text('API keys are not available for this account.')
              else ...[
                if (_c.list.keys.isEmpty && _c.status == AtlasApiKeysStatus.ready) const Text('No API keys yet.'),
                for (final key in _c.list.keys)
                  ListTile(
                    key: Key('atlas.api_key.${key.id}'),
                    title: Text(key.name ?? 'Unnamed key'),
                    subtitle: Text('${key.prefix}\n${_status(key)}'),
                    isThreeLine: true,
                    trailing: key.isActive()
                        ? Row(mainAxisSize: MainAxisSize.min, children: [
                            TextButton(
                              onPressed: () async {
                                final text = TextEditingController(text: key.name ?? '');
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Rename'),
                                    content: TextField(controller: text, decoration: const InputDecoration(labelText: 'Name')),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
                                    ],
                                  ),
                                );
                                if (ok == true) await _c.rename(key, text.text);
                                text.dispose();
                              },
                              child: const Text('Rename'),
                            ),
                            TextButton(
                              onPressed: () async {
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Revoke this key? Anything using it will stop working.'),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                      FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Yes, revoke')),
                                    ],
                                  ),
                                );
                                if (ok == true) await _c.revoke(key);
                              },
                              child: const Text('Revoke'),
                            ),
                          ])
                        : null,
                  ),
                if (atLimit)
                  Text("You've reached the maximum of ${_c.list.maxActiveKeys} active keys. Revoke one to create another.",
                      style: theme.textTheme.bodySmall),
                FilledButton(onPressed: atLimit ? null : _createDialog, child: const Text('Create key')),
                _error(context, _c.message),
              ],
            ]);
          },
        ),
      );
}

/// Approve (or deny) the code a TV, console or CLI shows: type the code (or pass
/// one read from its QR code as [userCode]), check the app and scopes, tap Allow.
class AtlasDeviceApproval extends StatefulWidget {
  const AtlasDeviceApproval({
    super.key,
    required this.client,
    this.userCode,
    this.appearance,
    this.appearanceInfo,
    this.fonts = const {},
  });

  final AtlasClient client;
  final String? userCode;
  final AtlasAppearance? appearance;
  final AtlasAppearanceInfo? appearanceInfo;
  final Map<String, String> fonts;

  @override
  State<AtlasDeviceApproval> createState() => _AtlasDeviceApprovalState();
}

class _AtlasDeviceApprovalState extends State<AtlasDeviceApproval> {
  late final AtlasDeviceApprovalController _c = AtlasDeviceApprovalController(widget.client);
  late final TextEditingController _code = TextEditingController(text: widget.userCode ?? '');
  final TextEditingController _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    final code = widget.userCode;
    if (code != null && code.isNotEmpty) _c.lookup(code);
  }

  @override
  void dispose() {
    _c.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _AtlasThemed(
        client: widget.client,
        appearance: widget.appearance,
        appearanceInfo: widget.appearanceInfo,
        fonts: widget.fonts,
        builder: (context, style) => ListenableBuilder(
          listenable: _c,
          builder: (context, _) {
            final theme = Theme.of(context);
            final auth = _c.authorization;
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text('Sign in on a device', style: theme.textTheme.titleMedium),
                if (_c.phase == AtlasDeviceApprovalPhase.entering) ...[
                  Text('Enter the code shown on your TV, console or terminal.', style: theme.textTheme.bodySmall),
                  TextField(
                    key: const Key('atlas.device_code'),
                    controller: _code,
                    decoration: const InputDecoration(labelText: 'Code'),
                    onChanged: (v) {
                      final f = AtlasClient.formatUserCode(v);
                      if (f != v) _code.value = TextEditingValue(text: f, selection: TextSelection.collapsed(offset: f.length));
                    },
                  ),
                  FilledButton(
                    onPressed: _c.isBusy || _code.text.isEmpty ? null : () => _c.lookup(_code.text),
                    child: const Text('Continue'),
                  ),
                ] else if (_c.phase == AtlasDeviceApprovalPhase.pending && auth != null) ...[
                  Text('${auth.client.name} wants to sign in to your account on a device.'),
                  if (auth.scopes.isNotEmpty) ...[
                    Text('It will be able to:', style: theme.textTheme.bodySmall),
                    for (final s in auth.scopes) Text('• ${s.description.isEmpty ? s.scope : s.description}'),
                  ],
                  Text('Only continue if your device shows this code: ${auth.userCode}', style: theme.textTheme.bodySmall),
                  if (_c.needsStepUp) ...[
                    Text('Enter your password to confirm.', style: theme.textTheme.bodySmall),
                    TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
                  ],
                  Row(children: [
                    OutlinedButton(onPressed: _c.isBusy ? null : () => _c.decide(approve: false), child: const Text('Deny')),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _c.isBusy
                          ? null
                          : () => _c.needsStepUp ? _c.completeStepUp(_password.text) : _c.decide(approve: true),
                      child: const Text('Allow'),
                    ),
                  ]),
                ] else ...[
                  Text(_c.phase == AtlasDeviceApprovalPhase.approved
                      ? 'Your device is signed in. You can go back to it now.'
                      : 'Sign-in denied. Nothing was shared with the device.'),
                  OutlinedButton(
                    onPressed: () {
                      _code.clear();
                      _c.reset();
                    },
                    child: const Text('Enter another code'),
                  ),
                ],
                _error(context, _c.message),
              ]),
            );
          },
        ),
      );
}
