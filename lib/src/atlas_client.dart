import 'dart:convert';

import 'package:http/http.dart' as http;

import 'atlas_exception.dart';
import 'models.dart';
import 'passkeys.dart';
import 'secure_token_store.dart';
import 'token_store.dart';

part 'flows.dart';

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
/// It is a complete client: the one-shot [signIn] / [signInWithPasskey] /
/// [signInWithIdToken] for the common paths, the multi-step flow drivers
/// ([createSignIn] / [createSignUp] / [createPasswordReset]) for anything with a
/// code, a second factor, or an MFA enrollment, native passkeys, and the
/// organization / session / `me`-mutation surfaces. Prebuilt widgets
/// (`AtlasSignIn`, `AtlasUserButton`, `AtlasAuthState`) render and advance the
/// flows. What it does, it does to the letter of the server contract.
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
      // The one-shot path only handles a straight password completion. A
      // non-complete status (e.g. needs_second_factor) means a further step is
      // owed — use [createSignIn] to drive it. Surfacing the status is honest.
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

  // MARK: - Multi-step flows

  /// Start a multi-step sign-in. Returns a [SignInFlow] state machine that
  /// drives `/v1/client/sign_ins` (identifier → first factor → second factor /
  /// MFA enrollment → done). Read [SignInFlow.status] / [SignInFlow.nextStep]
  /// after each step; on `complete` the flow persists the session through this
  /// client's [TokenStore], exactly like [signIn] and [signInWithPasskey].
  SignInFlow createSignIn() => SignInFlow(this);

  /// Start a multi-step sign-up over `/v1/client/sign_ups` (create → verify
  /// email → done). Completion persists the session like [createSignIn].
  SignUpFlow createSignUp() => SignUpFlow(this);

  /// Start a password-reset flow over `/v1/client/password_resets` (request →
  /// verify code → second factor if owed → set new password). When the instance
  /// allows sign-in after reset, completion persists the session.
  PasswordResetFlow createPasswordReset() => PasswordResetFlow(this);

  // MARK: - Native id_token sign-in

  /// Mint a single-use, replay-binding nonce for a native id_token sign-in
  /// (`POST /v1/client/sign_ins/id_token/nonce`). Call this FIRST, hand the
  /// nonce to the provider SDK (e.g. Google GSI `initialize({ nonce })` or
  /// Apple's request), then pass the SAME nonce to [signInWithIdToken]. Returns
  /// `null` when the provider does not support native sign-in.
  Future<String?> mintIdTokenNonce(String provider) async {
    final json = await _postJson(
      '/v1/client/sign_ins/id_token/nonce',
      {'provider': provider},
    );
    final nonce = json['nonce'];
    return nonce is String ? nonce : null;
  }

  /// Native / One-Tap sign-in: exchange a provider **id_token** (Google GSI /
  /// Apple / Facebook Limited Login) for a session
  /// (`POST /v1/client/sign_ins/id_token`).
  ///
  /// This is bring-your-own-token: your app obtains the [idToken] from the
  /// platform SDK (`google_sign_in`, `sign_in_with_apple`, …) and, for a
  /// nonce-bound flow, passes the [nonce] from [mintIdTokenNonce] that was
  /// embedded in that token. The SDK keeps no heavy native dependency of its
  /// own. On `complete` the one-time ticket is exchanged and the session
  /// persisted; a non-complete status (e.g. a further factor is owed) surfaces
  /// as an [AtlasException] carrying the status — use [createSignIn] for the UI
  /// that resolves it.
  Future<AtlasUser> signInWithIdToken({
    required String provider,
    required String idToken,
    String? nonce,
  }) async {
    final response = await _send(
      'POST',
      '/v1/client/sign_ins/id_token',
      body: {
        'provider': provider,
        'id_token': idToken,
        if (nonce != null) 'nonce': nonce,
      },
    );
    _throwIfError(response);
    final decoded = _decode(response);
    final attempt = SignInAttempt.fromJson(decoded);
    if (!attempt.isComplete) {
      throw AtlasException.api(
        status: response.statusCode,
        errors: [
          AtlasErrorItem(
            code: 'sign_in_not_complete',
            message: 'Sign-in needs an additional step: ${attempt.status}.',
          ),
        ],
      );
    }
    await _persistAttemptCompletion(attempt, response, decoded);
    return currentUser();
  }

  /// Persist the session from a completed attempt. Handles both shapes: a
  /// DIRECT session (`jwt` + `created_session_id` + a `Set-Cookie` refresh, as
  /// passkey finish returns) and the ordinary one-time `ticket` (password /
  /// email-code / id_token completions), which is exchanged for cookies. Throws
  /// [AtlasException] of kind [AtlasErrorKind.decoding] when a completed attempt
  /// carries neither.
  Future<void> _persistAttemptCompletion(
    SignInAttempt attempt,
    http.Response response,
    Map<String, dynamic> decoded,
  ) async {
    final tokens = SessionTokens.fromJson(decoded);
    if (tokens.jwt.isNotEmpty) {
      final refresh = _extractCookie(_Cookie.refresh, response);
      await tokenStore.save(AtlasSession(
        sessionId: attempt.createdSessionId ?? tokens.resolvedSessionId ?? '',
        token: tokens.jwt,
        refreshToken: refresh,
      ));
      return;
    }
    if (attempt.ticket != null) {
      await exchangeTicket(attemptId: attempt.id, ticket: attempt.ticket!);
      return;
    }
    throw AtlasException.decoding(
      'A completed attempt returned neither a session token nor a ticket.',
    );
  }

  // MARK: - Organizations

  /// The signed-in user's organization memberships
  /// (`GET /v1/client/me/organizations`).
  Future<List<OrganizationMembership>> listOrganizationMemberships() async {
    final json = await _authedJson('GET', '/v1/client/me/organizations');
    return _listOf(json, OrganizationMembership.fromJson);
  }

  /// Create an organization the signed-in user administers
  /// (`POST /v1/client/organizations`). Only succeeds when the instance allows
  /// user-created organizations.
  Future<Organization> createOrganization({
    required String name,
    required String slug,
  }) async {
    final json = await _authedJson(
      'POST',
      '/v1/client/organizations',
      body: {'name': name, 'slug': slug},
    );
    return Organization.fromJson(json);
  }

  /// One organization the signed-in user belongs to
  /// (`GET /v1/client/organizations/:id`).
  Future<Organization> getOrganization(String id) async {
    final json = await _authedJson(
      'GET',
      '/v1/client/organizations/${Uri.encodeComponent(id)}',
    );
    return Organization.fromJson(json);
  }

  /// Update an organization the signed-in user administers
  /// (`PATCH /v1/client/organizations/:id`). `public_metadata` is admin-writable
  /// here; `private_metadata` is backend-only and rejected by the server.
  Future<Organization> updateOrganization(
    String id, {
    String? name,
    String? imageUrl,
    Map<String, dynamic>? publicMetadata,
  }) async {
    final json = await _authedJson(
      'PATCH',
      '/v1/client/organizations/${Uri.encodeComponent(id)}',
      body: {
        if (name != null) 'name': name,
        if (imageUrl != null) 'image_url': imageUrl,
        if (publicMetadata != null) 'public_metadata': publicMetadata,
      },
    );
    return Organization.fromJson(json);
  }

  // MARK: - Sessions / devices

  /// The signed-in user's active sessions / devices
  /// (`GET /v1/client/sessions`). The caller's own session is flagged
  /// [SessionDevice.current].
  Future<List<SessionDevice>> listSessions() async {
    final json = await _authedJson('GET', '/v1/client/sessions');
    return _listOf(json, SessionDevice.fromJson);
  }

  /// Revoke one session / device by id
  /// (`POST /v1/client/sessions/:id/revoke`). Signing out the CURRENT session
  /// clears local storage too; revoking another device leaves this one signed
  /// in.
  Future<void> revokeSession(String id) async {
    final stored = await tokenStore.load();
    await _authedJson(
      'POST',
      '/v1/client/sessions/${Uri.encodeComponent(id)}/revoke',
    );
    // If the caller revoked their own session, drop local state to match.
    if (stored != null && stored.sessionId == id) {
      await tokenStore.clear();
    }
  }

  /// Sign out of every OTHER device, sparing this one
  /// (`POST /v1/client/sessions/revoke_all`). Returns how many were revoked.
  Future<int> revokeOtherSessions() async {
    final json = await _authedJson('POST', '/v1/client/sessions/revoke_all');
    final n = json['sessions_revoked'];
    return n is int ? n : 0;
  }

  // MARK: - /me mutations

  /// Update the signed-in user's profile (`PATCH /v1/client/me`). Only
  /// `unsafe_metadata` is writable from a client — `public_metadata` /
  /// `private_metadata` are rejected by the server.
  Future<AtlasUser> updateProfile({
    String? firstName,
    String? lastName,
    String? username,
    String? locale,
    Map<String, dynamic>? unsafeMetadata,
  }) async {
    final json = await _authedJson(
      'PATCH',
      '/v1/client/me',
      body: {
        if (firstName != null) 'first_name': firstName,
        if (lastName != null) 'last_name': lastName,
        if (username != null) 'username': username,
        if (locale != null) 'locale': locale,
        if (unsafeMetadata != null) 'unsafe_metadata': unsafeMetadata,
      },
    );
    return AtlasUser.fromJson(json);
  }

  /// Add an email address to the signed-in user
  /// (`POST /v1/client/me/email_addresses`). It starts unverified; confirm it
  /// with [verifyEmailAddress].
  Future<EmailAddress> addEmailAddress(String email) async {
    final json = await _authedJson(
      'POST',
      '/v1/client/me/email_addresses',
      body: {'email_address': email},
    );
    return EmailAddress.fromJson(json);
  }

  /// Verify an email address with the emailed code
  /// (`POST /v1/client/me/email_addresses/:id/attempt_verification`).
  Future<EmailAddress> verifyEmailAddress({
    required String id,
    required String code,
  }) async {
    final json = await _authedJson(
      'POST',
      '/v1/client/me/email_addresses/${Uri.encodeComponent(id)}/attempt_verification',
      body: {'code': code},
    );
    return EmailAddress.fromJson(json);
  }

  /// Make a VERIFIED email address the primary one
  /// (`POST /v1/client/me/email_addresses/:id/primary`).
  Future<void> setPrimaryEmailAddress(String id) async {
    await _authedJson(
      'POST',
      '/v1/client/me/email_addresses/${Uri.encodeComponent(id)}/primary',
    );
  }

  /// Remove an email address (`DELETE /v1/client/me/email_addresses/:id`). The
  /// server refuses to remove the last verified address.
  Future<void> deleteEmailAddress(String id) async {
    await _authedJson(
      'DELETE',
      '/v1/client/me/email_addresses/${Uri.encodeComponent(id)}',
    );
  }

  /// Start an OAuth flow to connect a NEW provider to the signed-in user
  /// (`POST /v1/client/me/external_accounts/connect`). Navigate the browser to
  /// the returned [ExternalAccountConnection.authorizationUrl]; the callback
  /// returns to [redirectUrl] with `__atlas_status=connected`.
  Future<ExternalAccountConnection> connectExternalAccount({
    required String provider,
    required String redirectUrl,
    List<String>? additionalScopes,
  }) async {
    final json = await _authedJson(
      'POST',
      '/v1/client/me/external_accounts/connect',
      body: {
        'provider': provider,
        'redirect_url': redirectUrl,
        if (additionalScopes != null) 'additional_scopes': additionalScopes,
      },
    );
    return ExternalAccountConnection.fromJson(json);
  }

  /// Unlink a connected provider (`DELETE /v1/client/me/external_accounts/:id`).
  /// The server refuses to remove the user's only remaining way to sign in.
  Future<void> disconnectExternalAccount(String id) async {
    await _authedJson(
      'DELETE',
      '/v1/client/me/external_accounts/${Uri.encodeComponent(id)}',
    );
  }

  /// Change the signed-in user's password, proving the current one
  /// (`POST /v1/client/me/change_password`). Every OTHER session is revoked
  /// server-side unless the instance opts out.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _authedJson(
      'POST',
      '/v1/client/me/change_password',
      body: {
        'current_password': currentPassword,
        'new_password': newPassword,
      },
    );
  }

  /// Set a FIRST password on an account that has none — an OAuth-only user or an
  /// anonymous guest (`POST /v1/client/me/set_password`). Use [changePassword]
  /// when a password already exists.
  Future<void> setPassword(String password) async {
    await _authedJson(
      'POST',
      '/v1/client/me/set_password',
      body: {'password': password},
    );
  }

  /// Decode a `{ object: 'list', data: [...] }` envelope into a typed list.
  List<T> _listOf<T>(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) decode,
  ) {
    final data = json['data'];
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((e) => decode(e.cast<String, dynamic>()))
        .toList(growable: false);
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
    Object body,
  ) async {
    final response = await _send('POST', path, body: body);
    _throwIfError(response);
    return _decode(response);
  }

  /// An authenticated request + JSON decode: load the stored session, present
  /// its cookie, and decode the body. Throws [AtlasException] of kind
  /// [AtlasErrorKind.notSignedIn] when there is no session. The single place the
  /// orgs / sessions / `me`-mutation methods flow through.
  Future<Map<String, dynamic>> _authedJson(
    String method,
    String path, {
    Object? body,
  }) async {
    final stored = await tokenStore.load();
    if (stored == null) throw AtlasException.notSignedIn();
    final response = await _send(
      method,
      path,
      body: body,
      cookie: _cookieHeader(stored),
    );
    _throwIfError(response);
    return _decode(response);
  }

  /// The single place a request is built and sent. Every call flows through here
  /// so the auth header, base URL, and JSON content type are set in exactly one
  /// place — the class of bug where one endpoint forgets the key.
  Future<http.Response> _send(
    String method,
    String path, {
    Object? body,
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
        case 'PATCH':
          return await _http.patch(uri, headers: headers, body: encoded);
        case 'DELETE':
          return await _http.delete(uri, headers: headers, body: encoded);
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
