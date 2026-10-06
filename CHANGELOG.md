# Changelog

## 0.4.0

- **Multi-step flow drivers.** `createSignIn()`, `createSignUp()` and
  `createPasswordReset()` return state machines over `/v1/client/sign_ins`,
  `/v1/client/sign_ups` and `/v1/client/password_resets`. Each exposes a
  `status` (`FlowStatus`) + a `nextStep` (`FlowStep`) and `advance`-style methods
  for password, email code, phone code, second factor (TOTP / SMS / backup /
  push), mid-sign-in MFA enrollment (with backup codes), and password reset. On
  `complete` the session is persisted through the `TokenStore`. The one-shot
  `signIn` / `signInWithPasskey` are unchanged.
- **Prebuilt Flutter widgets.** `AtlasSignIn` (aka `SignInView`) drives the
  sign-in flow end to end; `AtlasUserButton` (aka `UserButton`) renders the
  signed-in user with a sign-out menu; `AtlasAuthState` is a
  `ChangeNotifier` / `ValueListenable` the UI binds to (`user`, `loading`,
  `error`). Pure Flutter/Material — no extra native plugin.
- **Native id_token sign-in.** `signInWithIdToken({provider, idToken, nonce})`
  exchanges an Apple / Google / Facebook id_token for a session
  (`POST /v1/client/sign_ins/id_token`), with `mintIdTokenNonce(provider)` for
  the replay-binding nonce. Bring-your-own-token — obtain the id_token from the
  platform SDK; no heavy native dependency is bundled.
- **Organizations, session listing, and `/me` mutations.**
  `listOrganizationMemberships`, `createOrganization`, `getOrganization`,
  `updateOrganization`; `listSessions`, `revokeSession`, `revokeOtherSessions`;
  `updateProfile`, `addEmailAddress`, `verifyEmailAddress`,
  `setPrimaryEmailAddress`, `deleteEmailAddress`, `connectExternalAccount`,
  `disconnectExternalAccount`, `changePassword`, `setPassword`. New models:
  `Organization`, `OrganizationMembership`, `SessionDevice`,
  `ExternalAccountConnection`, `MfaEnrollment`, `SecondFactorPreparation`.

## 0.3.0

- Add native passkey support: `registerPasskey({name})` and `signInWithPasskey()`,
  driving the platform authenticator (iOS ASAuthorization / Android Credential
  Manager) via the `passkeys` plugin. The relying-party id and challenge come
  from the server's `begin` response, and sign-in reads the session directly
  from the finish response.
- Raise the SDK floor to Dart >=3.9 / Flutter >=3.35 (the passkeys plugin's
  requirement). Password and OAuth flows are unaffected.

## 0.2.0

- Client-facing auth core (FAPI): sign-in, sessions, OAuth, and the user model.
