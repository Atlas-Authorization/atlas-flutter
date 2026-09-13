/// Immutable data models mirroring the Swift SDK's `Models.swift`.
///
/// Each type decodes the FAPI wire shape (snake_case keys) via [fromJson] and
/// re-encodes via [toJson]. Customer-defined metadata (`public_metadata`,
/// `unsafe_metadata`) is kept as a plain `Map<String, dynamic>` — idiomatic Dart
/// JSON — rather than a bespoke `JSONValue` wrapper.
library;

/// Helper: read a value from JSON as a specific type, or null.
T? _as<T>(Object? value) => value is T ? value : null;

/// Helper: decode a JSON list into a typed list via [decode].
List<E>? _list<E>(Object? value, E Function(Map<String, dynamic>) decode) {
  if (value is! List) return null;
  return value
      .whereType<Map>()
      .map((e) => decode(e.cast<String, dynamic>()))
      .toList(growable: false);
}

/// A sign-in attempt (§5). The SDK never advances the flow itself — it reads
/// [status] and lets the server say what the next step is. Mirrors the FAPI
/// `sign_in_attempt` / `AttemptView` shape.
class SignInAttempt {
  const SignInAttempt({
    required this.id,
    required this.status,
    this.supportedFirstFactors,
    this.createdSessionId,
    this.authorizationUrl,
    this.ticket,
  });

  final String id;
  final String status;

  /// The server's list of first-factor strategies. §13.2 makes this identical
  /// for unknown identifiers, so it must never be filtered client-side.
  final List<String>? supportedFirstFactors;
  final String? createdSessionId;

  /// Present only when a redirect flow returns an authorize URL.
  final String? authorizationUrl;

  /// Present for exactly one step — the one that reached `complete`. Exchanged
  /// for a session, then gone.
  final String? ticket;

  bool get isComplete => status == 'complete';

  factory SignInAttempt.fromJson(Map<String, dynamic> json) {
    final factors = json['supported_first_factors'];
    return SignInAttempt(
      id: _as<String>(json['id']) ?? '',
      status: _as<String>(json['status']) ?? '',
      supportedFirstFactors: factors is List
          ? factors.whereType<String>().toList(growable: false)
          : null,
      createdSessionId: _as<String>(json['created_session_id']),
      authorizationUrl: _as<String>(json['authorization_url']),
      ticket: _as<String>(json['ticket']),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'status': status,
        if (supportedFirstFactors != null)
          'supported_first_factors': supportedFirstFactors,
        if (createdSessionId != null) 'created_session_id': createdSessionId,
        if (authorizationUrl != null) 'authorization_url': authorizationUrl,
        if (ticket != null) 'ticket': ticket,
      };
}

/// The response of a ticket exchange or a token rotation (§9.2). [jwt] is the
/// short-lived session token; the long-lived refresh token is delivered as an
/// HttpOnly cookie and captured separately.
class SessionTokens {
  const SessionTokens({
    required this.jwt,
    this.id,
    this.sessionId,
    this.expiresIn,
  });

  final String jwt;
  final String? id;
  final String? sessionId;
  final int? expiresIn;

  /// The session id, whichever key the endpoint used (`id` on exchange,
  /// `session_id` on rotate).
  String? get resolvedSessionId => id ?? sessionId;

  factory SessionTokens.fromJson(Map<String, dynamic> json) => SessionTokens(
        jwt: _as<String>(json['jwt']) ?? '',
        id: _as<String>(json['id']),
        sessionId: _as<String>(json['session_id']),
        expiresIn: _as<int>(json['expires_in']),
      );

  Map<String, dynamic> toJson() => {
        'jwt': jwt,
        if (id != null) 'id': id,
        if (sessionId != null) 'session_id': sessionId,
        if (expiresIn != null) 'expires_in': expiresIn,
      };
}

/// The FAPI view of the signed-in user (`GET /v1/client/me`). `private_metadata`
/// and `password_hash` are absent by construction on the server (§4.1); the
/// frontend may write `unsafe_metadata` and nothing else.
class AtlasUser {
  const AtlasUser({
    required this.id,
    this.firstName,
    this.lastName,
    this.username,
    this.imageUrl,
    this.locale,
    this.publicMetadata,
    this.unsafeMetadata,
    this.mfaEnabled,
    this.hasPassword,
    this.createdAt,
    this.primaryEmailId,
    this.emailAddresses,
    this.externalAccounts,
    this.passkeys,
  });

  final String id;
  final String? firstName;
  final String? lastName;
  final String? username;
  final String? imageUrl;
  final String? locale;
  final Map<String, dynamic>? publicMetadata;
  final Map<String, dynamic>? unsafeMetadata;
  final bool? mfaEnabled;
  final bool? hasPassword;
  final int? createdAt;
  final String? primaryEmailId;
  final List<EmailAddress>? emailAddresses;
  final List<ExternalAccount>? externalAccounts;
  final List<Passkey>? passkeys;

  factory AtlasUser.fromJson(Map<String, dynamic> json) => AtlasUser(
        id: _as<String>(json['id']) ?? '',
        firstName: _as<String>(json['first_name']),
        lastName: _as<String>(json['last_name']),
        username: _as<String>(json['username']),
        imageUrl: _as<String>(json['image_url']),
        locale: _as<String>(json['locale']),
        publicMetadata: _as<Map>(json['public_metadata'])?.cast<String, dynamic>(),
        unsafeMetadata: _as<Map>(json['unsafe_metadata'])?.cast<String, dynamic>(),
        mfaEnabled: _as<bool>(json['mfa_enabled']),
        hasPassword: _as<bool>(json['has_password']),
        createdAt: _as<int>(json['created_at']),
        primaryEmailId: _as<String>(json['primary_email_id']),
        emailAddresses: _list(json['email_addresses'], EmailAddress.fromJson),
        externalAccounts:
            _list(json['external_accounts'], ExternalAccount.fromJson),
        passkeys: _list(json['passkeys'], Passkey.fromJson),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (firstName != null) 'first_name': firstName,
        if (lastName != null) 'last_name': lastName,
        if (username != null) 'username': username,
        if (imageUrl != null) 'image_url': imageUrl,
        if (locale != null) 'locale': locale,
        if (publicMetadata != null) 'public_metadata': publicMetadata,
        if (unsafeMetadata != null) 'unsafe_metadata': unsafeMetadata,
        if (mfaEnabled != null) 'mfa_enabled': mfaEnabled,
        if (hasPassword != null) 'has_password': hasPassword,
        if (createdAt != null) 'created_at': createdAt,
        if (primaryEmailId != null) 'primary_email_id': primaryEmailId,
        if (emailAddresses != null)
          'email_addresses': emailAddresses!.map((e) => e.toJson()).toList(),
        if (externalAccounts != null)
          'external_accounts':
              externalAccounts!.map((e) => e.toJson()).toList(),
        if (passkeys != null)
          'passkeys': passkeys!.map((e) => e.toJson()).toList(),
      };
}

class EmailAddress {
  const EmailAddress({
    required this.id,
    required this.emailAddress,
    required this.verified,
    required this.primary,
  });

  final String id;
  final String emailAddress;
  final bool verified;
  final bool primary;

  factory EmailAddress.fromJson(Map<String, dynamic> json) => EmailAddress(
        id: _as<String>(json['id']) ?? '',
        emailAddress: _as<String>(json['email_address']) ?? '',
        verified: _as<bool>(json['verified']) ?? false,
        primary: _as<bool>(json['primary']) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email_address': emailAddress,
        'verified': verified,
        'primary': primary,
      };
}

class ExternalAccount {
  const ExternalAccount({
    required this.id,
    required this.provider,
    this.providerEmail,
    this.connectedAt,
  });

  final String id;
  final String provider;

  /// The provider's email is a snapshot, not authoritative for ownership
  /// (§4.2) — do not treat it as identity.
  final String? providerEmail;
  final int? connectedAt;

  factory ExternalAccount.fromJson(Map<String, dynamic> json) => ExternalAccount(
        id: _as<String>(json['id']) ?? '',
        provider: _as<String>(json['provider']) ?? '',
        providerEmail: _as<String>(json['provider_email']),
        connectedAt: _as<int>(json['connected_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'provider': provider,
        if (providerEmail != null) 'provider_email': providerEmail,
        if (connectedAt != null) 'connected_at': connectedAt,
      };
}

class Passkey {
  const Passkey({required this.id, this.name});

  final String id;
  final String? name;

  factory Passkey.fromJson(Map<String, dynamic> json) => Passkey(
        id: _as<String>(json['id']) ?? '',
        name: _as<String>(json['name']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (name != null) 'name': name,
      };
}

/// What the SDK persists after sign-in. The [token] (session JWT) goes in secure
/// storage; [refreshToken] is the HttpOnly `__atlas_rt` cookie the SDK
/// re-presents on authenticated calls and rotates on refresh.
class AtlasSession {
  const AtlasSession({
    required this.sessionId,
    required this.token,
    this.refreshToken,
  });

  final String sessionId;
  final String token;
  final String? refreshToken;

  factory AtlasSession.fromJson(Map<String, dynamic> json) => AtlasSession(
        sessionId: _as<String>(json['sessionId']) ?? '',
        token: _as<String>(json['token']) ?? '',
        refreshToken: _as<String>(json['refreshToken']),
      );

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'token': token,
        if (refreshToken != null) 'refreshToken': refreshToken,
      };

  AtlasSession copyWith({String? sessionId, String? token, String? refreshToken}) =>
      AtlasSession(
        sessionId: sessionId ?? this.sessionId,
        token: token ?? this.token,
        refreshToken: refreshToken ?? this.refreshToken,
      );

  @override
  bool operator ==(Object other) =>
      other is AtlasSession &&
      other.sessionId == sessionId &&
      other.token == token &&
      other.refreshToken == refreshToken;

  @override
  int get hashCode => Object.hash(sessionId, token, refreshToken);

  @override
  String toString() =>
      'AtlasSession(sessionId: $sessionId, token: <redacted>, '
      'refreshToken: ${refreshToken == null ? 'null' : '<redacted>'})';
}
