# atlas_auth

The official **Flutter / Dart** client SDK for [Atlas](https://atlasauth.net) — a
Clerk/Auth0-class authentication platform. It is the cross-platform mobile peer
of the Atlas **Swift** and **Kotlin** SDKs and mirrors their surface
method-for-method, so an app that knows one knows all three.

This is a **client** SDK. It talks to the Atlas **Frontend API (FAPI)** with a
**publishable key** (`pk_...`) and a session token — it never uses, accepts, or
stores your secret key (`sk_...`). Passing an `sk_...` key throws.

## Install

```sh
flutter pub add atlas_auth
```

or add it to `pubspec.yaml`:

```yaml
dependencies:
  atlas_auth: ^0.1.0
```

## Quickstart

```dart
import 'package:atlas_auth/atlas_auth.dart';

final client = AtlasClient(
  publishableKey: 'pk_live_…',
  frontendApi: 'clerk.example.com', // a bare host is upgraded to https://
);

// Password sign-in — creates the attempt, submits the first factor, exchanges
// the completion ticket for a session, and persists it in secure storage.
try {
  final user = await client.signIn(email: 'ada@example.com', password: 'hunter2');
  print('Signed in as ${user.firstName} (${user.id})');
} on AtlasException catch (e) {
  if (e.code == 'form_password_incorrect') {
    print('Wrong password: ${e.message}');
  } else {
    rethrow;
  }
}

// A cheap, offline check — is a session persisted?
if (await client.hasSession()) {
  final user = await client.currentUser(); // GET /v1/client/me
  print('Welcome back, ${user.username ?? user.id}');
}

// Rotate the session token (mint a fresh JWT + rotated refresh cookie).
final rotated = await client.refresh();

// End the session server-side and clear local storage.
await client.signOut();
```

### OAuth / social sign-in

The SDK builds the provider authorize URL; opening it and catching the deep-link
callback is your app's job (e.g. with
[`flutter_web_auth_2`](https://pub.dev/packages/flutter_web_auth_2)). On the
callback, hand the `__atlas_attempt` and `__atlas_ticket` params back to
`exchangeTicket`:

```dart
final authorizeUrl = await client.oauthAuthorizeUrl(
  provider: 'google',
  redirectUri: 'myapp://oauth-callback',
);

// Open `authorizeUrl` in a browser / custom tab, then on the callback:
await client.exchangeTicket(attemptId: attemptId, ticket: ticket);
final user = await client.currentUser();
```

## API surface

`AtlasClient` (all methods return `Future`s):

| Method | FAPI call | Purpose |
| --- | --- | --- |
| `signIn({email, password})` | `POST /v1/client/sign_ins` → `…/attempt_first_factor` → `…/tickets/exchange` | Full password sign-in; returns the `AtlasUser`. |
| `exchangeTicket({attemptId, ticket})` | `POST /v1/client/tickets/exchange` | Turn a one-time ticket (or OAuth callback) into a session. |
| `oauthAuthorizeUrl({provider, redirectUri})` | `POST /v1/client/sign_ins/oauth` | Build the provider authorize `Uri`. |
| `currentUser()` | `GET /v1/client/me` | The signed-in user. |
| `refresh()` | `POST /v1/client/sessions/:id/tokens` | Rotate the token; returns the updated `AtlasSession`. |
| `signOut()` | `POST /v1/client/sessions/:id/revoke` | Revoke server-side and clear local storage. |
| `hasSession()` | — | Offline check for a persisted session. |

Models (immutable, with `fromJson` / `toJson`): `SignInAttempt`,
`SessionTokens`, `AtlasUser`, `EmailAddress`, `ExternalAccount`, `Passkey`,
`AtlasSession`. Customer metadata (`public_metadata`, `unsafe_metadata`) is a
plain `Map<String, dynamic>`.

Errors: every failure is an `AtlasException` — `kind` (`api` / `transport` /
`decoding` / `notSignedIn`), `status` (HTTP status for API errors), `code` (the
first server error code), `message`, and the raw `errors` list of
`AtlasErrorItem { code, message, param }`.

## Token storage

The session is persisted through a `TokenStore`:

- **`SecureTokenStore`** (default) — OS-backed secure storage via
  [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage):
  the **Keychain** on iOS/macOS and the **EncryptedSharedPreferences**-backed
  Keystore on Android. One entry per publishable key, so two Atlas instances in
  one app never collide. The session JWT is stored, and the HttpOnly
  `__atlas_rt` refresh cookie alongside it — the SDK re-presents and rotates it
  for you; your app never handles it.
- **`InMemoryTokenStore`** — process-lifetime only. The default in tests and a
  fallback where secure storage is unavailable; never ship it as your store.

Provide your own by implementing the `TokenStore` interface (`save` / `load` /
`clear`, each `FutureOr`) and passing it to the constructor.

### Platform notes

- **iOS / macOS**: the Keychain item uses
  `KeychainAccessibility.first_unlock_this_device` — readable in the background
  (a refresh while the phone is locked) but never included in an iCloud backup.
  No extra setup is required; for Keychain sharing across an app + its
  extensions, configure a keychain access group in Xcode.
- **Android**: `flutter_secure_storage` uses EncryptedSharedPreferences and
  requires `minSdkVersion 18` (23+ recommended). If you enable Auto Backup,
  exclude the secure-storage file so encrypted blobs are not restored onto a
  different device.

## Scope

The client is intentionally thin, matching the Swift/Kotlin peers. It does not
drive multi-step MFA UI, own a cookie jar, or bundle passkeys — a non-complete
sign-in surfaces its `status` as an `AtlasException` so your UI can take over.
What it does, it does to the letter of the server contract.

## Testing

```sh
flutter test
```

The suite ports the Swift `AtlasClientTests`, driving the full
sign-in → exchange → refresh → currentUser → signOut flow against
`package:http/testing.dart`'s `MockClient` (the seam the injectable
`http.Client` constructor argument exists for). It asserts exact endpoints and
request bodies, that the publishable key rides on every request, refresh-cookie
capture/replay, and error decoding.

## License

MIT — see [LICENSE](LICENSE).
