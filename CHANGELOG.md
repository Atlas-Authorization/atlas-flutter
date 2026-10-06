# Changelog

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
