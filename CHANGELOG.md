# Changelog

## 0.6.0 — 2026-10-23

- **Device id on account-creating starts.** Email sign-up and the social / SSO / id_token sign-in starts carry a random `device_id` for the instance's accounts-per-device abuse limit, like the JS SDK (`AtlasClient.deviceIdRoutes`). `AtlasClient.deviceIdProvider` defaults to an id stable for the process; point it at your own persistent storage to keep it across launches.
- **Passkey sign-in captcha.** `signInWithPasskey(captchaToken:)` forwards the sign-in captcha token; an instance that challenges sign-ins answers `CAPTCHA_REQUIRED` without one (`AtlasException.isCaptchaRequired`, `AtlasErrorCode.captchaRequired` / `captchaFailed` / `challengeUnavailable`).
- **Passkey-only sign-up.** `createPasskeySignUp()` → `PasskeySignUpFlow` (`start`, `attemptVerification`, `awaitingPasskey`) and `createSignUpPasskey(flow)` (begin → platform ceremony → finish). The account exists only once the passkey is registered.
- **SMS MFA enrolment mid-sign-in.** `SignInFlow.prepareSmsMfaEnrollment(phone)` and `attemptSmsMfaEnrollment(factorId:, code:)`. `MfaEnrollment` carries `strategy`, `phone`, and for TOTP the QR image `qrCode` with `qrImageBytes`.
- **Organization audit log.** `organizationAuditLog(organizationId, limit:, startingAfter:, action:)` (`GET /v1/client/organizations/:id/audit_logs`, organization admins).

## 0.5.0

- **Dashboard design in `AtlasSignIn`.** The widget reads `GET /v1/appearance`
  (also public as `client.appearance()`, cached per client) and, when the app
  owner saved a design, renders it: light/dark palettes (platform brightness or
  forced `colorScheme`), card + control radii (999 = pill), border width, card
  style (glass uses a backdrop blur) / shadow / width, density spacing, button
  style (solid / outline / soft / gradient), input style (outline / filled /
  underline), social-button layout (list / grid / icons), font size / weights /
  type scale / uppercase buttons, and the light/dark logo. Catalog fonts render
  when the app bundles that family (or maps it via `fonts:`), else the platform
  font. With `design: null` the widget is unchanged from 0.4.0.
- **`appearance` overrides.** `AtlasSignIn(appearance: AtlasAppearance(…))`
  overrides any design token in code (code wins over the dashboard;
  `applyDashboardDesign: false` ignores the dashboard). `appearanceInfo:` takes a
  pre-fetched appearance.
- **Social buttons.** `onSocialSignIn` shows the enabled providers in the
  design's layout; `AtlasSocialButtons` is exported for custom screens.
- **Design model.** `AtlasDesign` (tolerant decoder of `design.resolved`:
  unknown keys ignored, missing/invalid values default), `AtlasAppearanceInfo`,
  `AtlasDesignStyle` (design → `ThemeData`) and the token enums.
- **Typed error codes.** `AtlasException.knownCode` → `AtlasErrorCode`;
  `isEmailDeliveryNotConfigured` for the new 422
  `EMAIL_DELIVERY_NOT_CONFIGURED`. `AtlasSignIn` shows the server's message and
  stops offering the email code after that refusal.

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
