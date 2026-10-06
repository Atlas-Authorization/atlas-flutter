import 'dart:convert';

import 'package:http/http.dart' as http;

import 'atlas_exception.dart';
import 'models.dart';
import 'passkeys.dart';
import 'secure_token_store.dart';
import 'token_store.dart';

/// Cookie names the server sets (mirrors the API's `COOKIE_NAMES`).
class _Cookie {
  static const String session = '__session';
  static const String refresh = '__atlas_rt';
}

/// The Atlas FAPI client — the client-facing auth core for a Flutter app.
///
/// It mirrors the vanilla JS (`@atlas/js`) FAPI contract exactly, and is a
/// faithful peer of the Swift (`Atlas`) and Kotlin (`com.atlas.sdk`) SDKs: every
/// request carries the `x-publishable-key` header, hits the [frontendApi]
/// origin, and speaks the §5 attempt / §9.1 error / §9.2 session shapes. The
/// session token (JWT) is persisted through a [TokenStore] (secure storage in
/// production); the HttpOnly `__atlas_rt` refresh cookie is captured and
/// re-presented so the SDK can call `me` and rotate the token without the app
/// ever handling it.
///
/// The client is intentionally thin. It does not drive multi-step MFA UI or own
/// a cookie jar — see the README's scope note. It does bundle native passkeys
/// ([registerPasskey] / [signInWithPasskey]), driving the platform WebAuthn
/// ceremony through the `passkeys` plugin. What it does, it does to the letter
/// of the server contract.
///
/// A client SDK authenticates with a **publishable key** (`pk_...`) and a
/// session token — never the secret key. Passing an `sk_...` key is a
/// programming error and throws [ArgumentError].
class AtlasClient {
  /// - [publishableKey]: the instance's `pk_...` publishable key. Sent as
  ///   `x-publishable-key` on every request.
  /// - [frontendApi]: the instance's FAPI host (`clerk.example.com`) or a full
  ///   origin. A bare host is upgraded to `https://`.
  /// - [tokenStore]: where the session is persisted. Defaults to a
  ///   [SecureTokenStore] namespaced by the publishable key.
  /// - [httpClient]: injectable for tests (a `package:http/testing.dart`
  ///   `MockClient`); defaults to a standard [http.Client].
  /// - [passkeyAuthenticator]: the platform WebAuthn ceremony driver used by
  ///   [registerPasskey] / [signInWithPasskey]. Defaults, lazily on first use,
  ///   to a [CorbadoPasskeyAuthenticator] backed by the `passkeys` plugin, so a
  ///   password-only app never touches the native authenticator. Inject a fake
  ///   in tests.
  AtlasClient({
    required this.publishableKey,
    required String frontendApi,
    TokenStore? tokenStore,
    http.Client? httpClient,
    AtlasPasskeyAuthenticator? passkeyAuthenticator,
  })  : assert(publishableKey.isNotEmpty, 'publishableKey must not be empty'),
        baseUrl = resolveBaseUrl(frontendApi),
        tokenStore = tokenStore ?? SecureTokenStore(account: publishableKey),
        _http = httpClient ?? http.Client(),
        _passkeyAuthenticator = passkeyAuthenticator {
    if (publishableKey.startsWith('sk_')) {
      // A client SDK must never hold the secret key. Fail loudly rather than
      // ship it to the frontend API.
      throw ArgumentError.value(
        publishableKey,
        'publishableKey',
        'Expected a publishable key (pk_...), not a secret key (sk_...). '
            'A client SDK never uses the secret key.',
      );
    }
  }

  final String publishableKey;

  /// The resolved base URL, e.g. `https://clerk.example.com`.
  final String baseUrl;
  final TokenStore tokenStore;
  final http.Client _http;

  /// The passkey ceremony driver. Null until first use, then the default
  /// plugin-backed authenticator is created lazily (unless one was injected).
  AtlasPasskeyAuthenticator? _passkeyAuthenticator;
  AtlasPasskeyAuthenticator get _passkeys =>
      _passkeyAuthenticator ??= CorbadoPasskeyAuthenticator();

  /// Normalize a FAPI host/origin into a base URL: a bare host is upgraded to
  /// `https://`, and a trailing slash is trimmed so it does not double up
  /// against the leading slash in each path.
  static String resolveBaseUrl(String frontendApi) {
    final trimmed = frontendApi.trim();
    final withScheme =
        trimmed.startsWith('http://') || trimmed.startsWith('https://')
            ? trimmed
            : 'https://$trimmed';
    return withScheme.endsWith('/')
        ? withScheme.substring(0, withScheme.length - 1)
        : withScheme;
  }

  // MARK: - Auth flows

  /// Password sign-in, end to end (§5 → §7.1 → §9.2):
  /// 1. `POST /v1/client/sign_ins` to create the attempt,
  /// 2. `POST …/attempt_first_factor` with `strategy: password`,
  /// 3. `POST /v1/client/tickets/exchange` to turn the completion ticket into a
  ///    session, persisting the JWT + refresh cookie.
  ///
  /// Returns the freshly signed-in user. Throws [AtlasException] on any bad step
  /// — a wrong password surfaces as `.api` with `form_password_incorrect`.
  Future<AtlasUser> signIn({
    required String email,
    required String password,
  }) async {
    final attempt = SignInAttempt.fromJson(
      await _postJson('/v1/client/sign_ins', {'identifier': email}),
    );

    final completed = SignInAttempt.fromJson(
      await _postJson(
        '/v1/client/sign_ins/${attempt.id}/attempt_first_factor',
        {'strategy': 'password', 'password': password},
      ),
    );

    if (!completed.isComplete || completed.ticket == null) {
      // A non-complete status (e.g. needs_second_factor) is a real flow the
      // foundation does not yet drive. Surfacing the status is honest.
      throw AtlasException.api(
        status: 200,
        errors: [
          AtlasErrorItem(
            code: 'sign_in_not_complete',
            message: 'Sign-in needs an additional step: ${completed.status}.',
          ),
        ],
      );
    }

    await exchangeTicket(attemptId: completed.id, ticket: completed.ticket!);
    return currentUser();
  }

  /// Exchange a one-time ticket for a session (`POST /v1/client/tickets/exchange`).
  /// Also the completion of an OAuth redirect: read `__atlas_attempt` +
  /// `__atlas_ticket` off the callback URL and pass them here.
  Future<void> exchangeTicket({
    required String attemptId,
    required String ticket,
  }) async {
    final response = await _send(
      'POST',
      '/v1/client/tickets/exchange',
      body: {'attempt_id': attemptId, 'ticket': ticket},
    );
    _throwIfError(response);

    final tokens = SessionTokens.fromJson(_decode(response));
    final refresh = _extractCookie(_Cookie.refresh, response);
    final sessionId = tokens.resolvedSessionId ?? attemptId;
    await tokenStore.save(AtlasSession(
      sessionId: sessionId,
      token: tokens.jwt,
      refreshToken: refresh,
    ));
  }

  /// Build the provider authorize URL for an OAuth sign-in
  /// (`POST /v1/client/sign_ins/oauth`). Hand the returned [Uri] to a browser /
  /// custom tab (e.g. `flutter_web_auth_2`); on the callback, pull the redirect
  /// params and call [exchangeTicket].
  ///
  /// - [provider]: the provider key (`google`, `github`, …).
  /// - [redirectUri]: your app's callback URL / custom scheme.
  Future<Uri> oauthAuthorizeUrl({
    required String provider,
    required String redirectUri,
  }) async {
    final attempt = SignInAttempt.fromJson(
      await _postJson(
        '/v1/client/sign_ins/oauth',
        {'provider': provider, 'redirect_url': redirectUri},
      ),
    );
    final raw = attempt.authorizationUrl;
    final uri = raw == null ? null : Uri.tryParse(raw);
    if (uri == null) {
      throw AtlasException.decoding(
          'The server returned no authorization_url.');
    }
    return uri;
  }

  // MARK: - Passkeys (WebAuthn)

  /// Register a passkey for the signed-in user, end to end:
  /// 1. `POST /v1/client/me/passkeys/begin` to get the WebAuthn creation
  ///    options (`rpId`, `challenge`, `user`, …),
  /// 2. run the platform ceremony with those options — the device creates the
  ///    credential (Face ID / Touch ID / screen lock),
  /// 3. `POST /v1/client/me/passkeys/finish` with the attestation to store it.
  ///
  /// This is an authenticated (`/me/*`) call: it presents the stored session
  /// and throws [AtlasException] of kind [AtlasErrorKind.notSignedIn] when there
  /// is no session. [name] is an optional human label shown in the user's
  /// device list. Returns the newly registered [Passkey].
  ///
  /// The `rpId` and `challenge` are taken from the `begin` response — never
  /// hardcoded. Server failures surface as [AtlasException]; a ceremony the user
  /// cancels or that finds no authenticator surfaces as the plugin's own typed
  /// exception (e.g. `PasskeyAuthCancelledException`).
  Future<Passkey> registerPasskey({String? name}) async {
    final stored = await tokenStore.load();
    if (stored == null) throw AtlasException.notSignedIn();

    final beginResponse = await _send(
      'POST',
      '/v1/client/me/passkeys/begin',
      body: const <String, String>{},
      cookie: _cookieHeader(stored),
    );
    _throwIfError(beginResponse);
    final begin = _decode(beginResponse);

    final credential =
        await _passkeys.register(RegisterRequestType.fromJson(begin));
    final body = passkeyRegistrationFinishBody(begin, credential, name: name);

    final finishResponse = await _send(
      'POST',
      '/v1/client/me/passkeys/finish',
      body: body,
      cookie: _cookieHeader(stored),
    );
    _throwIfError(finishResponse);
    return Passkey.fromJson(_decode(finishResponse));
  }

  /// Sign in with a passkey, end to end:
  /// 1. `POST /v1/client/sign_ins/passkey/begin` (publishable key only) to get
  ///    the WebAuthn request options (`rpId`, `challenge`, `allowCredentials`),
  /// 2. run the platform ceremony — the device asserts an existing credential,
  /// 3. `POST /v1/client/sign_ins/passkey/finish` with the assertion, which
  ///    mints the session DIRECTLY and returns the signed-in user.
  ///
  /// Unlike password [signIn], passkey finish does NOT go through a ticket
  /// exchange — a verified passkey is two factors in one gesture, so the finish
  /// response carries the completed attempt with its `jwt` + `created_session_id`
  /// and a refresh token in a `Set-Cookie`. A non-complete status (e.g. a further
  /// factor is owed) surfaces as an [AtlasException] carrying the status. The
  /// `rpId` and `challenge` are taken from the `begin` response. A ceremony the
  /// user cancels or with no credential available surfaces as the plugin's own
  /// typed exception.
  Future<AtlasUser> signInWithPasskey() async {
    final begin = await _postJson(
      '/v1/client/sign_ins/passkey/begin',
      const <String, String>{},
    );

    final assertion =
        await _passkeys.authenticate(AuthenticateRequestType.fromJson(begin));
    final body = passkeyAssertionFinishBody(begin, assertion);

    final response =
        await _send('POST', '/v1/client/sign_ins/passkey/finish', body: body);
    _throwIfError(response);
    final decoded = _decode(response);

    final attempt = SignInAttempt.fromJson(decoded);
    if (!attempt.isComplete) {
      throw AtlasException.api(
        status: 200,
        errors: [
          AtlasErrorItem(
            code: 'sign_in_not_complete',
            message: 'Sign-in needs an additional step: ${attempt.status}.',
          ),
        ],
      );
    }

    // Persist the session straight from the finish response: the completed
    // attempt carries `jwt` + `created_session_id`, and the refresh token comes
    // as a Set-Cookie (no ticket exchange for passkeys).
    final tokens = SessionTokens.fromJson(decoded);
    final refresh = _extractCookie(_Cookie.refresh, response);
    await tokenStore.save(AtlasSession(
      sessionId: attempt.createdSessionId ?? tokens.resolvedSessionId ?? '',
      token: tokens.jwt,
      refreshToken: refresh,
    ));
    return currentUser();
  }

  /// The signed-in user (`GET /v1/client/me`). Presents the stored refresh
  /// cookie for authentication; throws an [AtlasException] of kind
  /// [AtlasErrorKind.notSignedIn] when there is no session.
  Future<AtlasUser> currentUser() async {
    final stored = await tokenStore.load();
    if (stored == null) throw AtlasException.notSignedIn();
    final response = await _send(
      'GET',
      '/v1/client/me',
      cookie: _cookieHeader(stored),
    );
    _throwIfError(response);
    return AtlasUser.fromJson(_decode(response));
  }

  /// Rotate the refresh token and mint a fresh JWT
  /// (`POST /v1/client/sessions/:id/tokens`). Updates the stored session with
  /// the new token and rotated cookie, and returns it.
  Future<AtlasSession> refresh() async {
    final stored = await tokenStore.load();
    if (stored == null) throw AtlasException.notSignedIn();
    final response = await _send(
      'POST',
      '/v1/client/sessions/${stored.sessionId}/tokens',
      cookie: _cookieHeader(stored),
    );
    _throwIfError(response);

    final tokens = SessionTokens.fromJson(_decode(response));
    final rotated =
        _extractCookie(_Cookie.refresh, response) ?? stored.refreshToken;
    final updated = AtlasSession(
      sessionId: tokens.resolvedSessionId ?? stored.sessionId,
      token: tokens.jwt,
      refreshToken: rotated,
    );
    await tokenStore.save(updated);
    return updated;
  }

  /// Sign out: revoke the session server-side
  /// (`POST /v1/client/sessions/:id/revoke`) and clear local storage. Local
  /// state is cleared even if the network call fails — a client that keeps a
  /// token after the user tapped "sign out" is the worse failure.
  Future<void> signOut() async {
    final stored = await tokenStore.load();
    try {
      if (stored != null) {
        try {
          await _send(
            'POST',
            '/v1/client/sessions/${stored.sessionId}/revoke',
            cookie: _cookieHeader(stored),
          );
        } catch (_) {
          // Best-effort revoke; local clear below is what matters.
        }
      }
    } finally {
      await tokenStore.clear();
    }
  }

  /// Whether a session is currently persisted. A cheap, offline check — it does
  /// not validate the token against the server.
  Future<bool> hasSession() async => (await tokenStore.load()) != null;

  /// Release the underlying HTTP client. Call when the client is no longer used.
  void close() => _http.close();

  // MARK: - HTTP core

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, String> body,
  ) async {
    final response = await _send('POST', path, body: body);
    _throwIfError(response);
    return _decode(response);
  }

  /// The single place a request is built and sent. Every call flows through here
  /// so the auth header, base URL, and JSON content type are set in exactly one
  /// place — the class of bug where one endpoint forgets the key.
  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? body,
    String? cookie,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{'x-publishable-key': publishableKey};
    if (cookie != null) headers['Cookie'] = cookie;
    String? encoded;
    if (body != null) {
      headers['content-type'] = 'application/json';
      encoded = jsonEncode(body);
    }

    try {
      switch (method) {
        case 'GET':
          return await _http.get(uri, headers: headers);
        case 'POST':
          return await _http.post(uri, headers: headers, body: encoded);
        default:
          throw AtlasException.transport('Unsupported HTTP method: $method');
      }
    } on AtlasException {
      rethrow;
    } catch (error) {
      throw AtlasException.transport('We could not reach the server: $error');
    }
  }

  void _throwIfError(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AtlasException.fromResponse(response.statusCode, response.body);
    }
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
      throw const FormatException('Expected a JSON object.');
    } catch (error) {
      throw AtlasException.decoding('Could not decode response: $error');
    }
  }

  /// Build the `Cookie` header from the stored session — both the session JWT
  /// and the refresh token, exactly as a browser would present them.
  String _cookieHeader(AtlasSession stored) {
    final parts = <String>['${_Cookie.session}=${stored.token}'];
    final refresh = stored.refreshToken;
    if (refresh != null) parts.add('${_Cookie.refresh}=$refresh');
    return parts.join('; ');
  }

  /// Pull one cookie value out of a response's `Set-Cookie` header(s). Dart's
  /// http layer collapses repeated `Set-Cookie` headers into one comma-joined
  /// string, so this matches the cookie at any cookie boundary and stops at the
  /// first attribute (`;`) or the next cookie (`,`).
  String? _extractCookie(String name, http.Response response) {
    final header = response.headers['set-cookie'];
    if (header == null) return null;
    final pattern = RegExp(
      '(?:^|[,;]\\s*)${RegExp.escape(name)}=([^;,]*)',
    );
    final match = pattern.firstMatch(header);
    return match?.group(1);
  }
}
