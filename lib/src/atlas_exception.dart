import 'dart:convert';

/// One item of the §9.1 error envelope: `{ errors: [{ code, message, param?, meta? }] }`.
///
/// The API writes [message] for humans, so it is surfaced verbatim. [param]
/// attaches the message to a field so a form can render it inline rather than
/// dumping everything into a single banner.
class AtlasErrorItem {
  const AtlasErrorItem({
    required this.code,
    required this.message,
    this.param,
    this.meta,
    this.didYouMean = const [],
    this.allowedMethods = const [],
    this.docsUrl,
  });

  final String code;
  final String message;
  final String? param;

  /// Structured detail some errors carry (e.g. `meta.required_scope` on
  /// `INSUFFICIENT_SCOPE`).
  final Map<String, dynamic>? meta;

  /// `ROUTE_NOT_FOUND` only: the closest documented paths.
  final List<String> didYouMean;

  /// `ROUTE_NOT_FOUND` only: the methods the path does support.
  final List<String> allowedMethods;

  /// Where the error code is documented (`https://atlasauth.net/errors/<code>`).
  final String? docsUrl;

  static List<String> _strings(Object? v) =>
      v is List ? v.whereType<String>().toList(growable: false) : const [];

  factory AtlasErrorItem.fromJson(Map<String, dynamic> json) {
    final meta = json['meta'];
    return AtlasErrorItem(
      code: json['code'] as String? ?? '',
      message: json['message'] as String? ?? '',
      param: json['param'] as String?,
      meta: meta is Map ? meta.cast<String, dynamic>() : null,
      didYouMean: _strings(json['did_you_mean']),
      allowedMethods: _strings(json['allowed_methods']),
      docsUrl: json['docs_url'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        if (param != null) 'param': param,
        if (meta != null) 'meta': meta,
        if (didYouMean.isNotEmpty) 'did_you_mean': didYouMean,
        if (allowedMethods.isNotEmpty) 'allowed_methods': allowedMethods,
        if (docsUrl != null) 'docs_url': docsUrl,
      };

  @override
  bool operator ==(Object other) =>
      other is AtlasErrorItem &&
      other.code == code &&
      other.message == message &&
      other.param == param;

  @override
  int get hashCode => Object.hash(code, message, param);

  @override
  String toString() => 'AtlasErrorItem($code: $message${param == null ? '' : ' [$param]'})';
}

/// Server error codes the SDK names. [wire] is the code on the wire;
/// [AtlasException.code] still carries every code, known or not.
enum AtlasErrorCode {
  /// 422 — a flow would send an email (code, link, reset, verification) but the
  /// app has no way to deliver it. Refused before anything is issued, so a form
  /// never says "we sent you a code" when nothing will arrive.
  emailDeliveryNotConfigured('EMAIL_DELIVERY_NOT_CONFIGURED'),
  validationFailed('VALIDATION_FAILED'),
  rateLimited('RATE_LIMITED'),
  identifierNotFound('IDENTIFIER_NOT_FOUND'),
  identifierExists('IDENTIFIER_EXISTS'),
  verificationExpired('VERIFICATION_EXPIRED'),
  verificationFailed('VERIFICATION_FAILED'),
  emailNotVerified('EMAIL_NOT_VERIFIED'),
  tooManyAttempts('TOO_MANY_ATTEMPTS'),
  passwordBreached('PASSWORD_BREACHED'),
  passwordPolicy('PASSWORD_POLICY'),
  locked('LOCKED'),

  /// 400 — the instance challenges this step and no `captcha_token` was sent
  /// (e.g. a passkey sign-in begin). Run the captcha and retry with its token.
  captchaRequired('CAPTCHA_REQUIRED'),

  /// 400 — the `captcha_token` sent was refused.
  captchaFailed('CAPTCHA_FAILED'),

  /// 403 — the step needs a challenge but no captcha provider is configured.
  challengeUnavailable('CHALLENGE_UNAVAILABLE'),

  /// 403 — the key or token lacks a scope; `meta.required_scope` names it.
  insufficientScope('INSUFFICIENT_SCOPE'),

  /// The pre-2026-10 spelling of [insufficientScope]; still tolerated.
  scopeMissing('SCOPE_MISSING'),

  /// 403 — the request origin is not one the key or app allows.
  originNotAllowed('ORIGIN_NOT_ALLOWED'),

  /// 403 — a recent MFA / re-authentication is required first.
  stepUpRequired('STEP_UP_REQUIRED'),

  /// 404 — no such method + path; carries `did_you_mean` / `allowed_methods`.
  routeNotFound('ROUTE_NOT_FOUND');

  const AtlasErrorCode(this.wire);

  /// The code as the API sends it.
  final String wire;

  /// The known code for a wire value, or null.
  static AtlasErrorCode? fromWire(String? code) {
    for (final c in values) {
      if (c.wire == code) return c;
    }
    return null;
  }
}

/// The kind of failure an [AtlasException] represents. Mirrors the cases of the
/// Swift `AtlasError` enum.
enum AtlasErrorKind {
  /// The server's §9.1 error envelope, with the HTTP status in [AtlasException.status].
  api,

  /// A network / transport failure (host unreachable, connection dropped).
  transport,

  /// A malformed body — contract drift, worth distinguishing from a network drop.
  decoding,

  /// Raised locally, before a request is attempted, when an authenticated call
  /// has no stored session to present.
  notSignedIn,
}

/// Every failure the SDK can surface, kept as one type so a caller has exactly
/// one thing to catch.
///
/// ```dart
/// try {
///   await client.signIn(email: e, password: p);
/// } on AtlasException catch (e) {
///   if (e.code == 'form_password_incorrect') showError(e.message);
/// }
/// ```
class AtlasException implements Exception {
  const AtlasException._({
    required this.kind,
    this.status,
    this.errors = const [],
    String? detail,
  }) : _detail = detail;

  /// Which category of failure this is.
  final AtlasErrorKind kind;

  /// The HTTP status for an [AtlasErrorKind.api] error; null for
  /// local/transport failures.
  final int? status;

  /// The server's error items for an [AtlasErrorKind.api] error; empty otherwise.
  final List<AtlasErrorItem> errors;

  final String? _detail;

  /// The server's §9.1 envelope with the HTTP status.
  factory AtlasException.api({
    required int status,
    required List<AtlasErrorItem> errors,
  }) =>
      AtlasException._(kind: AtlasErrorKind.api, status: status, errors: errors);

  /// A network / transport failure.
  factory AtlasException.transport(String detail) =>
      AtlasException._(kind: AtlasErrorKind.transport, detail: detail);

  /// A malformed / undecodable response body.
  factory AtlasException.decoding(String detail) =>
      AtlasException._(kind: AtlasErrorKind.decoding, detail: detail);

  /// An authenticated call was made with no stored session.
  factory AtlasException.notSignedIn() =>
      const AtlasException._(kind: AtlasErrorKind.notSignedIn);

  /// Decode the §9.1 envelope from a non-2xx body. Falls back to a synthetic
  /// item when the body is not the expected shape (a proxy error page, an empty
  /// 500), so a caller always gets a code to branch on rather than a decode
  /// crash.
  factory AtlasException.fromResponse(int status, String body) {
    List<AtlasErrorItem> items = const [];
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['errors'] is List) {
        items = (decoded['errors'] as List)
            .whereType<Map>()
            .map((e) => AtlasErrorItem.fromJson(e.cast<String, dynamic>()))
            .where((e) => e.code.isNotEmpty)
            .toList(growable: false);
      }
    } catch (_) {
      // Not JSON, or not the expected shape — fall through to the synthetic item.
    }
    if (items.isEmpty) {
      items = [
        AtlasErrorItem(
          code: 'unexpected',
          message: 'The request failed (HTTP $status).',
        ),
      ];
    }
    return AtlasException.api(status: status, errors: items);
  }

  /// The first server error code — the value most callers branch on
  /// (`form_password_incorrect`, `form_identifier_not_found`, …). Null for
  /// non-API failures.
  String? get code => errors.isNotEmpty ? errors.first.code : null;

  /// The first server error code as a typed [AtlasErrorCode], when the SDK
  /// knows it; null for other codes and non-API failures ([code] has them all).
  AtlasErrorCode? get knownCode => AtlasErrorCode.fromWire(code);

  /// The app cannot send email (422 `EMAIL_DELIVERY_NOT_CONFIGURED`); nothing
  /// was sent. [message] is the server's end-user wording — show it as-is and
  /// offer another sign-in method.
  bool get isEmailDeliveryNotConfigured => knownCode == AtlasErrorCode.emailDeliveryNotConfigured;

  /// The step needs a captcha (`CAPTCHA_REQUIRED`) or the one sent was refused
  /// (`CAPTCHA_FAILED`): run the captcha and retry with its token.
  bool get isCaptchaRequired =>
      knownCode == AtlasErrorCode.captchaRequired || knownCode == AtlasErrorCode.captchaFailed;

  /// 403 `INSUFFICIENT_SCOPE`: the key or token lacks a scope. The older
  /// `SCOPE_MISSING` spelling is still tolerated. [requiredScope] names the scope.
  bool get isInsufficientScope =>
      knownCode == AtlasErrorCode.insufficientScope || knownCode == AtlasErrorCode.scopeMissing;

  /// The scope an `INSUFFICIENT_SCOPE` refusal asks for (`meta.required_scope`);
  /// null otherwise.
  String? get requiredScope {
    for (final item in errors) {
      final scope = item.meta?['required_scope'];
      if (scope is String) return scope;
    }
    return null;
  }

  /// 403 `STEP_UP_REQUIRED`: a recent re-authentication (MFA) is needed; run it
  /// and retry.
  bool get isStepUpRequired => knownCode == AtlasErrorCode.stepUpRequired;

  /// 403 `ORIGIN_NOT_ALLOWED`: the request came from an origin the key or app
  /// does not allow.
  bool get isOriginNotAllowed => knownCode == AtlasErrorCode.originNotAllowed;

  /// 404 `ROUTE_NOT_FOUND`: no such method + path (a missing object is
  /// `NOT_FOUND`).
  bool get isRouteNotFound => knownCode == AtlasErrorCode.routeNotFound;

  AtlasErrorItem? get _routeNotFoundItem {
    for (final item in errors) {
      if (item.code == AtlasErrorCode.routeNotFound.wire) return item;
    }
    return null;
  }

  /// `ROUTE_NOT_FOUND`: the closest documented paths; empty for any other error.
  List<String> get didYouMean => _routeNotFoundItem?.didYouMean ?? const [];

  /// `ROUTE_NOT_FOUND`: the methods the path does support; empty for any other
  /// error.
  List<String> get allowedMethods => _routeNotFoundItem?.allowedMethods ?? const [];

  /// A human-readable message, always non-null so it can go straight to a UI.
  String get message {
    switch (kind) {
      case AtlasErrorKind.api:
        return errors.isNotEmpty
            ? errors.first.message
            : 'The request failed (HTTP $status).';
      case AtlasErrorKind.transport:
      case AtlasErrorKind.decoding:
        return _detail ?? 'The request failed.';
      case AtlasErrorKind.notSignedIn:
        return 'You must be signed in.';
    }
  }

  @override
  String toString() => 'AtlasException(${kind.name}): $message';
}
