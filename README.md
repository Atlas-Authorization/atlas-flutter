# atlas_auth

[![pub package](https://img.shields.io/pub/v/atlas_auth.svg)](https://pub.dev/packages/atlas_auth)

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
  atlas_auth: ^0.4.0
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

### Passkeys (native WebAuthn) — new in **0.3.0**

The SDK bundles native passkeys. It drives the platform authenticator — Face ID
/ Touch ID on iOS, the biometric / screen-lock prompt via Credential Manager on
Android — through the [`passkeys`](https://pub.dev/packages/passkeys) plugin,
and owns the two FAPI calls and the body mapping between them. The ceremony's
`rpId` and `challenge` always come from the server's `begin` response; nothing
is hardcoded.

```dart
// Register a passkey for the already-signed-in user. `name` is the human label
// shown in the device's passkey list. Returns the new Passkey.
final passkey = await client.registerPasskey(name: 'My iPhone');

// Sign in with a passkey — no password. Runs the ceremony, exchanges the
// completion ticket for a session, persists it, and returns the user.
final user = await client.signInWithPasskey();
```

Server failures surface as `AtlasException`, exactly like the other flows. The
ceremony layer surfaces the plugin's own typed exceptions, so your UI can tell a
deliberate cancel from a missing credential:

```dart
try {
  await client.signInWithPasskey();
} on PasskeyAuthCancelledException {
  // The user dismissed the system sheet — not an error to shout about.
} on NoCredentialsAvailableException {
  // No passkey on this device; offer password / OAuth instead.
} on AtlasException catch (e) {
  showError(e.message); // a begin/finish/exchange failure
}
```

Inject your own authenticator (e.g. a fake in tests) via the
`passkeyAuthenticator` constructor argument; by default one backed by the
`passkeys` plugin is created lazily on first use, so a password-only app never
touches the native authenticator.

#### Setup the app project must do

Passkeys are bound to your instance's Frontend API host, so the OS needs to see
that your app is allowed to use credentials for that host. You configure the app
side; **Atlas serves the matching well-known files on the Frontend API host for
you, per instance — you do not self-host them.**

- **iOS / macOS**: add an **Associated Domains** entitlement with
  `webcredentials:<frontend-api-host>` (e.g.
  `webcredentials:fapi.acme.atlasauth.net`). Atlas serves the matching
  `/.well-known/apple-app-site-association` on that host automatically.
- **Android**: register your app's **Digital Asset Links** — your package name
  and your signing-certificate SHA-256 fingerprint(s) (both your upload/debug
  and Play App Signing certs). Atlas serves the matching
  `/.well-known/assetlinks.json` on the Frontend API host automatically; you
  only declare the association on the app side.

The `passkeys` plugin requires Android `minSdkVersion 28`, a device signed in to
a Google account, and iOS 15+. See its
[setup guide](https://pub.dev/packages/passkeys) for the per-platform details.

## Multi-step sign-in / sign-up — new in **0.4.0**

For anything past a plain password — a verification code, a second factor, an
MFA enrollment the policy now requires — drive the flow with a state machine
instead of the one-shot `signIn`. The server decides each step; you read
`status` / `nextStep` and submit what it asks for (§5). On `complete` the flow
persists the session through the same `TokenStore`, so the rest of the app (and
`currentUser()`) sees the signed-in user immediately.

```dart
final flow = client.createSignIn();

await flow.start('ada@example.com');

switch (flow.nextStep) {
  case CollectFirstFactor(strategies: final s) when s.contains('password'):
    await flow.attemptPassword('hunter2');
  case CollectFirstFactor():
    await flow.prepareFirstFactor(strategy: 'email_code'); // then attemptEmailCode(...)
  default:
    break;
}

// A second factor owed? TOTP, an SMS OTP, or a backup code all go here:
if (flow.status == FlowStatus.needsSecondFactor) {
  // optional: text an SMS code / start a push / fetch passkey options first
  await flow.prepareSecondFactor(strategy: 'sms');
  await flow.attemptTotp('123456', rememberDevice: true);
}

// Policy requires enrollment (needs_mfa_enrollment)?
if (flow.status == FlowStatus.needsMfaEnrollment) {
  final enrollment = await flow.prepareMfaEnrollment(); // show enrollment.uri / .secret
  await flow.attemptMfaEnrollment(factorId: enrollment.factorId, codes: ['111222']);
  print(flow.backupCodes); // shown once
}

if (flow.isComplete) {
  final user = await client.currentUser(); // session already persisted
}
```

`nextStep` is an exhaustive, sealed `FlowStep` (`CollectIdentifier`,
`CollectFirstFactor`, `CollectSecondFactor`, `EnrollSecondFactor`,
`CollectEmailCode`, `CollectNewPassword`, `CollectCaptcha`, `AwaitOauth`,
`FlowDone`, `FlowRestart`, `FlowUnknown`) — a status this SDK version does not
know maps to `FlowUnknown`, never a blank screen. Any bad step throws
`AtlasException`, exactly like the one-shot methods.

**Sign-up** (`createSignUp()`) and **password reset** (`createPasswordReset()`)
are the same shape:

```dart
final signUp = client.createSignUp();
await signUp.create(email: 'new@example.com', password: 'hunter2longer');
await signUp.attemptVerification('424242'); // emailed code → complete → session persisted

final reset = client.createPasswordReset();
await reset.request('ada@example.com');
await reset.attemptVerification('000111');
// await reset.attemptSecondFactor('123456'); // only if the account has MFA
await reset.setNewPassword('brandnewpass9'); // persists a session when sign-in-after-reset is on
```

## Prebuilt widgets — new in **0.4.0**

Pure Flutter/Material widgets that drive the flow and bind to observable auth
state — no extra native plugin beyond what the SDK already needs.

- **`AtlasSignIn`** (alias `SignInView`) — a self-driving sign-in form:
  identifier → first factor (password / email code) → second factor (TOTP / SMS
  / backup code) → MFA enrollment → done, advancing a `SignInFlow` as the user
  submits.
- **`AtlasUserButton`** (alias `UserButton`) — the signed-in user's avatar/name
  with a sign-out (and optional "Manage account") menu.
- **`AtlasAuthState`** — a `ChangeNotifier` (and `ValueListenable` via
  `userListenable`) exposing `user`, `loading`, `error`, `isSignedIn`. Bind any
  widget to it with `ListenableBuilder` / `AnimatedBuilder` / `provider`.

```dart
final auth = AtlasAuthState(client)..load(); // rehydrate any persisted session

// In a build method:
AtlasSignIn(
  client: client,
  session: auth, // updated on completion
  onComplete: (user) => Navigator.pop(context),
);

AtlasUserButton(session: auth, onSignedOut: () => print('bye'));
```

Styling follows the ambient `Theme`; wrap the widget in your own `Theme` to
brand it.

## Native id_token sign-in — new in **0.4.0**

Exchange a provider **id_token** (Google GSI / One-Tap, Apple, Facebook Limited
Login) for a session, no redirect:

```dart
// Optional but recommended: a replay-binding nonce the provider embeds.
final nonce = await client.mintIdTokenNonce('google');

// Obtain the id_token from the platform SDK — this is bring-your-own-token, so
// the Atlas SDK pulls in no heavy native dependency of its own:
//   • Google: `google_sign_in` → GoogleSignInAuthentication.idToken
//             (configure the GSI client with `nonce`)
//   • Apple:  `sign_in_with_apple` → credential.identityToken (pass `nonce`)
final user = await client.signInWithIdToken(
  provider: 'google',
  idToken: theIdTokenFromTheProviderSdk,
  nonce: nonce,
);
```

On `complete` the one-time ticket is exchanged and the session persisted. A
non-complete response (e.g. a second factor is still owed) throws
`AtlasException` with the status — hand off to `createSignIn()` to resolve it.

## Organizations, sessions & profile — new in **0.4.0**

Authenticated `/me`, organization, and session surfaces, each a typed method +
model. All present the stored session automatically and throw
`AtlasException(kind: notSignedIn)` when there is none.

```dart
// Organizations (§8 / §9.2)
final memberships = await client.listOrganizationMemberships();   // List<OrganizationMembership>
final org = await client.createOrganization(name: 'Acme', slug: 'acme');
await client.updateOrganization(org.id, name: 'Acme Inc', publicMetadata: {'tier': 'pro'});

// Sessions / devices (§10.2)
final devices = await client.listSessions();                      // List<SessionDevice>, .current flags this one
await client.revokeSession(otherDevice.id);                       // revoking THIS session clears local storage
final n = await client.revokeOtherSessions();                     // "sign out of every other device"

// /me mutations
await client.updateProfile(firstName: 'Ada', unsafeMetadata: {'theme': 'dark'});
final email = await client.addEmailAddress('ada+new@example.com');
await client.verifyEmailAddress(id: email.id, code: '112233');
await client.setPrimaryEmailAddress(email.id);
await client.deleteEmailAddress(oldEmailId);
final connect = await client.connectExternalAccount(provider: 'github', redirectUrl: 'myapp://cb');
// open connect.authorizationUrl in a browser; the callback returns __atlas_status=connected
await client.disconnectExternalAccount(externalAccountId);
await client.changePassword(currentPassword: 'old', newPassword: 'new-one-9'); // revokes other sessions
await client.setPassword('first-pass-9');                         // OAuth-only / guest: set a first password
```

Only `unsafe_metadata` is client-writable on a user; `public_metadata` /
`private_metadata` are rejected by the server (an organization's
`public_metadata` is admin-writable via `updateOrganization`).

## API surface

`AtlasClient` (all methods return `Future`s):

| Method | FAPI call | Purpose |
| --- | --- | --- |
| `signIn({email, password})` | `POST /v1/client/sign_ins` → `…/attempt_first_factor` → `…/tickets/exchange` | Full password sign-in; returns the `AtlasUser`. |
| `exchangeTicket({attemptId, ticket})` | `POST /v1/client/tickets/exchange` | Turn a one-time ticket (or OAuth callback) into a session. |
| `oauthAuthorizeUrl({provider, redirectUri})` | `POST /v1/client/sign_ins/oauth` | Build the provider authorize `Uri`. |
| `registerPasskey({name})` | `POST /v1/client/me/passkeys/begin` → `…/finish` | Register a passkey for the signed-in user; returns the new `Passkey`. |
| `signInWithPasskey()` | `POST /v1/client/sign_ins/passkey/begin` → `…/finish` → `…/tickets/exchange` | Sign in with a passkey; returns the `AtlasUser`. |
| `currentUser()` | `GET /v1/client/me` | The signed-in user. |
| `refresh()` | `POST /v1/client/sessions/:id/tokens` | Rotate the token; returns the updated `AtlasSession`. |
| `signOut()` | `POST /v1/client/sessions/:id/revoke` | Revoke server-side and clear local storage. |
| `hasSession()` | — | Offline check for a persisted session. |

Beyond the one-shot methods above, `AtlasClient` also exposes the multi-step
flow factories (`createSignIn` / `createSignUp` / `createPasswordReset`), native
id_token sign-in (`signInWithIdToken` / `mintIdTokenNonce`), and the
organization / session / `me`-mutation methods documented in the sections above.

Models (immutable, with `fromJson` / `toJson`): `SignInAttempt`,
`SessionTokens`, `AtlasUser`, `EmailAddress`, `ExternalAccount`, `Passkey`,
`AtlasSession`, `Organization`, `OrganizationMembership`, `SessionDevice`,
`ExternalAccountConnection`, `MfaEnrollment`, `SecondFactorPreparation`.
Customer metadata (`public_metadata`, `unsafe_metadata`) is a plain
`Map<String, dynamic>`.

**Native session (first-party OAuth, cookie-free)** — new in **0.2.0**
(`native_session.dart`). A first-party app trades an OAuth access token it holds
for a real Atlas session and carries it as a bearer: `exchangeForSession(...)`
(RFC 8693 token-exchange on `POST /oauth2/token`), `refreshNativeSession(...)`
(cookie-free rotate on `POST /v1/client/sessions/:id/tokens`), and
`NativeSessionManager`, which hands out a fresh bearer via `token()` /
`authHeaders()` (lazy, single-flight refresh ~10s before expiry) and persists
each rotated refresh token to the `TokenStore`. Both helpers **fail soft**,
returning `null` on any error — the caller's cue to re-run OAuth.

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

The SDK is a complete client for the Atlas Frontend API. It drives the full
multi-step sign-in / sign-up / password-reset flows — password, email and phone
codes, second factors (TOTP / SMS / backup / push), and mid-sign-in MFA
enrollment — through a server-authoritative state machine, and ships prebuilt
Flutter widgets (`AtlasSignIn`, `AtlasUserButton`, `AtlasAuthState`) that render
and advance those flows for you. It also covers native id_token (One-Tap /
Apple) sign-in, native passkeys, organizations, session/device management, and
the `/me` profile, email, external-account and password mutations. The session
(cookie-based and native bearer) is managed for you. What it does, it does to
the letter of the server contract; a status this SDK version does not yet model
surfaces as `FlowUnknown` rather than a blank screen.

What it deliberately leaves to the app: opening the system browser for an OAuth
redirect and catching the deep-link callback (hand the params to
`exchangeTicket`), obtaining a provider id_token from the platform SDK for
`signInWithIdToken` (bring-your-own-token, so no heavy native dependency is
bundled), and solving a CAPTCHA challenge in your own captcha widget.

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
