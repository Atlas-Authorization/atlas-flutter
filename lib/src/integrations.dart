part of 'atlas_client.dart';

// Identity integrations — `getToken({ for })`.
//
// Mirrors `@atlasauth/js` `getIntegrationToken` / `getAtlasIdIntegrationToken`.

String _integrationSeg(String value) => Uri.encodeComponent(value);

/// A short-lived token for a configured identity integration — what
/// [AtlasIntegrations.getToken] resolves. Any service that verifies the user
/// with a JWT (the built-in presets `chatly`, `forumulate`, `cookiemunch`,
/// `referalli`, or a custom integration id) accepts it as the user's identity.
class IntegrationToken {
  const IntegrationToken({
    required this.jwt,
    required this.expiresIn,
    required this.integration,
    required this.audience,
    this.orgId,
    this.spaceId,
    this.redeemUrl,
  });

  final String jwt;
  final int expiresIn;

  /// The integration id it was minted for (a preset or a custom id).
  final String integration;

  /// The token's `aud`.
  final String audience;

  /// Forumulate preset: the organization the reader belongs to.
  final String? orgId;

  /// Forumulate preset: the space the token is for.
  final String? spaceId;

  /// Forumulate preset: where the reader's browser redeems the token.
  final String? redeemUrl;

  factory IntegrationToken.fromJson(Map<String, dynamic> json, {String integration = ''}) {
    final jwt = json['jwt'];
    if (jwt is! String || jwt.isEmpty) {
      throw AtlasException.decoding('The server returned no jwt.');
    }
    return IntegrationToken(
      jwt: jwt,
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 0,
      integration: json['integration'] as String? ?? integration,
      audience: json['audience'] as String? ?? '',
      orgId: json['org_id'] as String?,
      spaceId: json['space_id'] as String?,
      redeemUrl: json['redeem_url'] as String?,
    );
  }
}

/// An integration token for a Sign in with Atlas user (see
/// [AtlasIntegrations.getAtlasIdToken]).
class AtlasIdIntegrationToken extends IntegrationToken {
  const AtlasIdIntegrationToken({
    required super.jwt,
    required super.expiresIn,
    required super.integration,
    required super.audience,
    required this.issuer,
    required this.jwksUri,
  });

  /// The Sign in with Atlas issuer: the token's `iss`.
  final String issuer;

  /// Where the receiving service fetches the keys to verify it.
  final String jwksUri;

  factory AtlasIdIntegrationToken.fromJson(Map<String, dynamic> json, {String integration = ''}) {
    final base = IntegrationToken.fromJson(json, integration: integration);
    return AtlasIdIntegrationToken(
      jwt: base.jwt,
      expiresIn: base.expiresIn,
      integration: base.integration,
      audience: base.audience,
      issuer: json['issuer'] as String? ?? '',
      jwksUri: json['jwks_uri'] as String? ?? '',
    );
  }
}

extension AtlasIntegrations on AtlasClient {
  /// `getToken({ for })` for the signed-in session
  /// (`POST /v1/client/sessions/:id/integration_tokens/:integration`): a
  /// short-lived token for a configured identity integration. The stored refresh
  /// cookie is presented, never rotated.
  ///
  /// Returns null when the integration is not enabled (404). A refusal such as
  /// 401 or 403 throws [AtlasException]; no stored session throws
  /// [AtlasErrorKind.notSignedIn].
  ///
  /// - [integration]: the integration id (a preset such as `chatly`, or a custom id).
  /// - [spaceId]: Forumulate preset only — the space to mint the reader token for.
  Future<IntegrationToken?> getToken(String integration, {String? spaceId}) async {
    final stored = await tokenStore.load();
    if (stored == null) throw AtlasException.notSignedIn();
    final query = (spaceId == null || spaceId.isEmpty)
        ? ''
        : '?space_id=${_integrationSeg(spaceId)}';
    try {
      final json = await _authedJson(
        'POST',
        '/v1/client/sessions/${_integrationSeg(stored.sessionId)}/integration_tokens/${_integrationSeg(integration)}$query',
      );
      return IntegrationToken.fromJson(json, integration: integration);
    } on AtlasException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// `getToken({ for })` for a user who signed in with Sign in with Atlas (not a
  /// session of this instance), from an app with no server of its own
  /// (`POST /v1/client/integrations/:integration/atlas_id_tokens`).
  ///
  /// The user's Sign in with Atlas access token goes as `Authorization: Bearer`,
  /// or as `DPoP` with [dpopProof] when the token is DPoP-bound. Atlas checks the
  /// request's `Origin` against the web origins of the Sign in with Atlas app the
  /// token was issued to; a native app that shares that app's registration
  /// passes one of those origins as [origin]. No cookie is sent.
  ///
  /// Returns null when the integration is not enabled for Sign in with Atlas
  /// users (404). Other refusals — 401 for a token Atlas does not accept, 403
  /// `ORIGIN_NOT_ALLOWED` — throw [AtlasException].
  Future<AtlasIdIntegrationToken?> getAtlasIdToken(
    String integration,
    String accessToken, {
    String? origin,
    String? dpopProof,
  }) async {
    final headers = <String, String>{
      if (dpopProof != null) 'Authorization': 'DPoP $accessToken' else 'Authorization': 'Bearer $accessToken',
      if (dpopProof != null) 'DPoP': dpopProof,
      if (origin != null && origin.isNotEmpty) 'Origin': origin,
    };
    final response = await _send(
      'POST',
      '/v1/client/integrations/${_integrationSeg(integration)}/atlas_id_tokens?publishable_key=${_integrationSeg(publishableKey)}',
      extraHeaders: headers,
    );
    if (response.statusCode == 404) return null;
    _throwIfError(response);
    return AtlasIdIntegrationToken.fromJson(_decode(response), integration: integration);
  }
}
