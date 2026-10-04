/// Native session — the first-party OAuth→session exchange, cookie-free.
///
/// A FIRST-PARTY OAuth client (the app IS the tenant's own property, not a
/// third-party integration) already holds an Atlas OAuth access token. On the web
/// that token would ride in a cookie and the browser would carry the session for
/// free; a native app has no cookie jar against the FAPI origin, so it trades that
/// OAuth access token for a real Atlas SESSION and then carries the session
/// itself, by hand, as a bearer.
///
/// This file is the Dart peer of `@atlas/js`'s `native-session.ts` and of the
/// Swift `NativeSession.swift`:
///
///   1. [exchangeForSession] — POST the RFC 8693 token-exchange form to
///      `/oauth2/token` and get back a [NativeSession].
///   2. [refreshNativeSession] — rotate the session WITHOUT a cookie, via
///      `POST /v1/client/sessions/:sid/tokens` with the stored refresh token.
///   3. [NativeSessionManager] — holds the current session, hands out a live JWT
///      (auto-refreshing near expiry, single-flight), and persists each rotated
///      refresh token to the SDK's [TokenStore] (secure storage in production).
///
/// Neither network helper ever throws — a failure is a `null`, the caller's cue
/// to re-run the OAuth flow rather than crash.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'atlas_client.dart';
import 'models.dart';
import 'secure_token_store.dart';
import 'token_store.dart';

/// RFC 8693 token-exchange grant.
const String _tokenExchangeGrant =
    'urn:ietf:params:oauth:grant-type:token-exchange';

/// The subject token the first-party app presents is an OAuth access token.
const String _accessTokenType = 'urn:ietf:params:oauth:token-type:access_token';

/// What we ask for in return: an Atlas session, not another OAuth token.
const String _sessionTokenType = 'urn:atlas:token-type:session';

/// A live Atlas session held outside a cookie.
///
/// [sessionToken] is the short-lived (~60s) session JWT sent as `Authorization:
/// Bearer …` on `/v1/client/me/*`. [refreshToken] mints the next one and ROTATES
/// on every refresh — persist the new value, discard the old. [expiresInSeconds]
/// is the lifetime the server reported for [sessionToken], a scheduling hint only.
class NativeSession {
  const NativeSession({
    required this.sessionToken,
    required this.refreshToken,
    required this.sessionId,
    this.expiresInSeconds = 0,
  });

  /// The short-lived session JWT. Bearer it on `/v1/client/me/*`.
  final String sessionToken;

  /// The rotating refresh token. Persist the latest; the previous one is dead.
  final String refreshToken;

  /// The session id (`sess_…`), the path segment the refresh call needs.
  final String sessionId;

  /// Reported lifetime of [sessionToken], in seconds. A hint, not a guarantee.
  final int expiresInSeconds;

  /// Map to the [AtlasSession] the SDK's [TokenStore] persists, so a native
  /// session reuses the same secure-storage entry as the cookie-based client.
  AtlasSession toSession() => AtlasSession(
        sessionId: sessionId,
        token: sessionToken,
        refreshToken: refreshToken,
      );

  /// Rebuild from a persisted [AtlasSession]. The reported expiry is not
  /// persisted, so it rehydrates as `0` — the manager treats the token as due for
  /// a refresh on its first use, which is the safe default.
  factory NativeSession.fromSession(AtlasSession session) => NativeSession(
        sessionToken: session.token,
        refreshToken: session.refreshToken ?? '',
        sessionId: session.sessionId,
      );

  @override
  bool operator ==(Object other) =>
      other is NativeSession &&
      other.sessionToken == sessionToken &&
      other.refreshToken == refreshToken &&
      other.sessionId == sessionId &&
      other.expiresInSeconds == expiresInSeconds;

  @override
  int get hashCode =>
      Object.hash(sessionToken, refreshToken, sessionId, expiresInSeconds);

  @override
  String toString() =>
      'NativeSession(sessionId: $sessionId, sessionToken: <redacted>, '
      'refreshToken: <redacted>, expiresInSeconds: $expiresInSeconds)';
}

bool _is2xx(int status) => status >= 200 && status < 300;

int _asInt(Object? value) => value is int ? value : 0;

/// Exchange a first-party OAuth access token for an Atlas session.
///
/// POSTs the RFC 8693 token-exchange form to `{baseUrl}/oauth2/token` and parses
/// the result into a [NativeSession]. Returns `null` — never throws — on a network
/// failure, a non-2xx, or a body missing the session token or id, so a caller
/// treats a failed exchange as "re-run OAuth" rather than a crash.
Future<NativeSession?> exchangeForSession({
  required String baseUrl,
  required String clientId,
  required String accessToken,
  required http.Client httpClient,
}) async {
  try {
    // A Map body is encoded `application/x-www-form-urlencoded` by package:http.
    final response = await httpClient.post(
      Uri.parse('$baseUrl/oauth2/token'),
      body: <String, String>{
        'grant_type': _tokenExchangeGrant,
        'client_id': clientId,
        'subject_token': accessToken,
        'subject_token_type': _accessTokenType,
        'requested_token_type': _sessionTokenType,
      },
    );
    if (!_is2xx(response.statusCode)) return null;

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return null;
    final map = decoded.cast<String, dynamic>();

    // A session is only a session if it carries both the JWT and the id the
    // refresh path needs; anything short of that is a failed exchange.
    final token = map['access_token'];
    final sessionId = map['session_id'];
    if (token is! String || sessionId is! String) return null;

    return NativeSession(
      sessionToken: token,
      refreshToken: map['refresh_token'] is String ? map['refresh_token'] as String : '',
      sessionId: sessionId,
      expiresInSeconds: _asInt(map['expires_in']),
    );
  } catch (_) {
    return null;
  }
}

/// Rotate a native session WITHOUT a cookie.
///
/// POSTs the stored refresh token to `/v1/client/sessions/{sessionId}/tokens` with
/// the publishable-key header, and returns the rotated [NativeSession]. Each
/// refresh ROTATES the refresh token — the caller MUST persist what comes back. If
/// the server omits a fresh `refresh_token` (it may, when it reuses the presented
/// one), the presented token is carried forward. Returns `null` — never throws —
/// on a network failure, a non-2xx, or a body with no `jwt`.
Future<NativeSession?> refreshNativeSession({
  required String baseUrl,
  required String publishableKey,
  required String sessionId,
  required String refreshToken,
  required http.Client httpClient,
}) async {
  try {
    final response = await httpClient.post(
      Uri.parse(
          '$baseUrl/v1/client/sessions/${Uri.encodeComponent(sessionId)}/tokens'),
      headers: <String, String>{
        'content-type': 'application/json',
        'x-publishable-key': publishableKey,
      },
      body: jsonEncode(<String, String>{'refresh_token': refreshToken}),
    );
    if (!_is2xx(response.statusCode)) return null;

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) return null;
    final map = decoded.cast<String, dynamic>();

    final jwt = map['jwt'];
    if (jwt is! String) return null;

    return NativeSession(
      sessionToken: jwt,
      // Carry the rotated token; fall back to the presented one if the server
      // reused it rather than issuing a new value.
      refreshToken:
          map['refresh_token'] is String ? map['refresh_token'] as String : refreshToken,
      sessionId: map['session_id'] is String ? map['session_id'] as String : sessionId,
      expiresInSeconds: _asInt(map['expires_in']),
    );
  } catch (_) {
    return null;
  }
}

/// Holds the current [NativeSession] and keeps its JWT live.
///
/// It refreshes LAZILY — on [token]/[authHeaders], when the token is within the
/// refresh lead (~10s) of expiry — rather than on a timer, because a backgrounded
/// app cannot keep one alive anyway. Concurrent [token] calls share one in-flight
/// [refresh] (single-flight). Each rotation persists the new session to the
/// [TokenStore] so secure storage captures the rotated refresh token.
class NativeSessionManager {
  NativeSessionManager({
    required this.publishableKey,
    required String frontendApi,
    this.clientId,
    TokenStore? tokenStore,
    http.Client? httpClient,
    Duration refreshLead = const Duration(seconds: 10),
    DateTime Function()? now,
  })  : baseUrl = AtlasClient.resolveBaseUrl(frontendApi),
        tokenStore = tokenStore ?? SecureTokenStore(account: publishableKey),
        _http = httpClient ?? http.Client(),
        _refreshLead = refreshLead,
        _now = now ?? DateTime.now;

  final String publishableKey;

  /// The resolved FAPI base URL, e.g. `https://clerk.example.com`.
  final String baseUrl;

  /// The first-party OAuth client id; `null` disables in-manager [exchange].
  final String? clientId;
  final TokenStore tokenStore;
  final http.Client _http;
  final Duration _refreshLead;
  final DateTime Function() _now;

  NativeSession? _session;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<NativeSession?>? _refreshing;

  /// The current session, or `null` when signed out. Does NOT refresh.
  NativeSession? get current => _session;

  /// Rehydrate a persisted session from the [TokenStore]. The reported expiry is
  /// not persisted, so the session is treated as due for a refresh on first use.
  Future<void> load() async {
    final stored = await tokenStore.load();
    if (stored != null) {
      _session = NativeSession.fromSession(stored);
      _expiresAt = _now();
    }
  }

  /// Exchange a first-party OAuth access token for a session, store it, and return
  /// it. Returns `null` when no [clientId] was configured or the exchange fails
  /// (the caller's cue to re-run OAuth).
  Future<NativeSession?> exchange(String accessToken) async {
    final id = clientId;
    if (id == null) return null;
    final session = await exchangeForSession(
      baseUrl: baseUrl,
      clientId: id,
      accessToken: accessToken,
      httpClient: _http,
    );
    if (session != null) await _setSession(session);
    return session;
  }

  /// The current session JWT, refreshed first if within the refresh lead of
  /// expiry. Returns `null` when signed out. If the refresh fails the EXISTING
  /// token is handed back rather than `null` — a truly-dead token is rejected on
  /// use (the 401 is the caller's cue), a better failure than a pre-emptive
  /// sign-out on a flaky connection.
  Future<String?> token() async {
    final session = _session;
    if (session == null) return null;
    if (_needsRefresh()) {
      final rotated = await refresh();
      if (rotated != null) return rotated.sessionToken;
    }
    return _session?.sessionToken;
  }

  /// The headers an authenticated `/v1/client/me/*` call needs: a fresh bearer
  /// (auto-refreshed like [token]) plus the publishable key. When signed out, only
  /// the publishable key is returned.
  Future<Map<String, String>> authHeaders() async {
    final t = await token();
    return t != null
        ? {'Authorization': 'Bearer $t', 'x-publishable-key': publishableKey}
        : {'x-publishable-key': publishableKey};
  }

  /// Replace the current session and persist it (e.g. after a manual exchange).
  Future<void> setSession(NativeSession session) => _setSession(session);

  /// Rotate the session now. Single-flight: a refresh already in progress is
  /// shared rather than duplicated. On success the new session is stored; `null`
  /// on failure, leaving the current session untouched.
  Future<NativeSession?> refresh() {
    final existing = _refreshing;
    if (existing != null) return existing;
    final session = _session;
    if (session == null) return Future.value(null);

    final future = refreshNativeSession(
      baseUrl: baseUrl,
      publishableKey: publishableKey,
      sessionId: session.sessionId,
      refreshToken: session.refreshToken,
      httpClient: _http,
    ).then((rotated) async {
      if (rotated != null) await _setSession(rotated);
      return rotated;
    }).whenComplete(() => _refreshing = null);

    _refreshing = future;
    return future;
  }

  /// Forget the session (sign-out). Does not touch the store.
  void clear() {
    _session = null;
    _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
    _refreshing = null;
  }

  /// Release the underlying HTTP client. Call when the manager is no longer used.
  void close() => _http.close();

  Future<void> _setSession(NativeSession session) async {
    _session = session;
    _expiresAt = _now().add(Duration(seconds: session.expiresInSeconds));
    await tokenStore.save(session.toSession());
  }

  bool _needsRefresh() {
    if (_session == null) return false;
    return !_expiresAt.subtract(_refreshLead).isAfter(_now());
  }
}
