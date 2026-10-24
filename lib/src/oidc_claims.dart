import 'dart:convert';

/// OIDC scope names for the sign-in and token-exchange helpers.
class AtlasScopes {
  const AtlasScopes._();

  static const String openid = 'openid';
  static const String profile = 'profile';
  static const String email = 'email';
  static const String offlineAccess = 'offline_access';

  /// Adds the `orgs` claim — `[{ id, slug, role }]`, at most 20 — to the ID token
  /// and userinfo.
  static const String organizations = 'organizations';

  /// [base] plus `organizations` (once), for helpers that take a scope list.
  static List<String> withOrganizations([List<String> base = const ['openid', 'profile', 'email']]) =>
      base.contains(organizations) ? base : [...base, organizations];
}

/// One entry of the `orgs` claim (`organizations` scope).
class OidcOrganization {
  const OidcOrganization({required this.id, this.slug, this.role});

  final String id;
  final String? slug;
  final String? role;
}

/// The enterprise SSO connection a sign-in came through (`sso_*` claims).
class OidcSso {
  const OidcSso({required this.connectionId, this.tenantId, this.issuer, this.domain});

  final String connectionId;
  final String? tenantId;
  final String? issuer;
  final String? domain;
}

/// The organization and enterprise-SSO claims of an Atlas ID token, access token
/// or userinfo response.
///
/// - `org_id`, `org_slug`, `org_role`, `org_permissions`: the organization the
///   sign-in applies to (absent when none applies).
/// - `orgs`: every organization, with the `organizations` scope.
/// - `sso_connection_id`, `sso_tenant_id`, `sso_issuer`, `sso_domain`: present
///   only for sign-ins through an enterprise SSO connection.
class OidcClaims {
  const OidcClaims({
    this.orgId,
    this.orgSlug,
    this.orgRole,
    this.orgPermissions = const [],
    this.orgs = const [],
    this.sso,
    this.ssoOrganizationId,
    this.ssoConnectionType,
  });

  final String? orgId;
  final String? orgSlug;
  final String? orgRole;
  final List<String> orgPermissions;
  final List<OidcOrganization> orgs;
  final OidcSso? sso;

  /// `sso_organization_id`: the Atlas organization that owns the SSO connection (independent of `org_id`).
  final String? ssoOrganizationId;

  /// `sso_connection_type`: `saml` or `oidc`; absent on a non-SSO sign-in.
  final String? ssoConnectionType;

  static String? _str(Object? v) => v is String ? v : null;

  /// Read the claims off a decoded claims object (userinfo, introspection, or a
  /// JWT payload).
  factory OidcClaims.fromClaims(Map<String, dynamic> claims) {
    final permissions = claims['org_permissions'];
    final orgList = claims['orgs'];
    final orgs = <OidcOrganization>[];
    if (orgList is List) {
      for (final entry in orgList) {
        if (entry is Map && entry['id'] is String) {
          orgs.add(OidcOrganization(
            id: entry['id'] as String,
            slug: _str(entry['slug']),
            role: _str(entry['role']),
          ));
        }
      }
    }
    final connection = _str(claims['sso_connection_id']);
    return OidcClaims(
      orgId: _str(claims['org_id']),
      orgSlug: _str(claims['org_slug']),
      orgRole: _str(claims['org_role']),
      orgPermissions: permissions is List ? permissions.whereType<String>().toList(growable: false) : const [],
      orgs: orgs,
      sso: connection == null
          ? null
          : OidcSso(
              connectionId: connection,
              tenantId: _str(claims['sso_tenant_id']),
              issuer: _str(claims['sso_issuer']),
              domain: _str(claims['sso_domain']),
            ),
      ssoOrganizationId: _str(claims['sso_organization_id']),
      ssoConnectionType: _str(claims['sso_connection_type']),
    );
  }

  /// Read the claims off a JWT's payload. The signature is NOT verified here —
  /// use this for display and routing on a token your app just received from
  /// Atlas, never to authorize on a token that arrived from elsewhere. Returns
  /// null for something that is not a JWT.
  static OidcClaims? fromJwt(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) return null;
    try {
      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      return OidcClaims.fromClaims(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }
}
