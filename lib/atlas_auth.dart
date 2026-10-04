/// Official Flutter/Dart client SDK for Atlas.
///
/// A thin, faithful port of the Swift (`Atlas`) and Kotlin (`com.atlas.sdk`)
/// client SDKs. It talks to the Atlas **Frontend API (FAPI)** with a publishable
/// key (`pk_...`) and a session token — never a secret key — and mirrors those
/// SDKs' surface method-for-method:
///
/// ```dart
/// final client = AtlasClient(
///   publishableKey: 'pk_live_…',
///   frontendApi: 'clerk.example.com',
/// );
/// final user = await client.signIn(email: 'a@b.com', password: 'hunter2');
/// ```
///
/// See [AtlasClient] for the flow, [TokenStore] for persistence, and
/// [AtlasException] for the error contract.
library atlas_auth;

export 'src/atlas_client.dart';
export 'src/atlas_exception.dart';
export 'src/models.dart';
export 'src/native_session.dart';
export 'src/token_store.dart';
export 'src/secure_token_store.dart';
