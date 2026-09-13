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
  });

  final String code;
  final String message;
  final String? param;

  factory AtlasErrorItem.fromJson(Map<String, dynamic> json) => AtlasErrorItem(
        code: json['code'] as String? ?? '',
        message: json['message'] as String? ?? '',
        param: json['param'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'code': code,
        'message': message,
        if (param != null) 'param': param,
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
