import 'dart:async';

import 'models.dart';

/// Where the SDK keeps the signed-in session between launches.
///
/// An interface, not a concrete type, so the persistence policy is the app's to
/// choose — secure storage in production ([SecureTokenStore]), an in-memory
/// store in tests ([InMemoryTokenStore]), or a customer's own vault.
/// [AtlasClient] never assumes anything beyond these three operations.
///
/// The operations are asynchronous because the production backend
/// (`flutter_secure_storage`) is a platform channel; the Swift/Kotlin peers use
/// synchronous Keychain/SharedPreferences, but on Flutter async is the correct,
/// idiomatic shape.
abstract class TokenStore {
  /// Persist the session, replacing any existing one.
  FutureOr<void> save(AtlasSession session);

  /// The stored session, or null when signed out.
  FutureOr<AtlasSession?> load();

  /// Remove the stored session (sign-out).
  FutureOr<void> clear();
}

/// A process-lifetime store. The default for tests, and a sane fallback where
/// secure storage is unavailable — but it does not survive a relaunch, so it is
/// never the right choice for a shipping app.
class InMemoryTokenStore implements TokenStore {
  InMemoryTokenStore([AtlasSession? initial]) : _session = initial;

  AtlasSession? _session;

  @override
  void save(AtlasSession session) => _session = session;

  @override
  AtlasSession? load() => _session;

  @override
  void clear() => _session = null;
}
