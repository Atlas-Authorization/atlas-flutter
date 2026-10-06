import 'package:flutter/foundation.dart';

import '../atlas_client.dart';
import '../atlas_exception.dart';
import '../models.dart';

/// Observable auth state a Flutter UI binds to.
///
/// A [ChangeNotifier] (and thus a [Listenable]) wrapping an [AtlasClient]: it
/// holds the signed-in [user], a [loading] flag, and the last [error], and
/// notifies listeners on every change so `AnimatedBuilder` / `ListenableBuilder`
/// / `provider` rebuild automatically. [userListenable] exposes the user as a
/// plain [ValueListenable] for code that prefers that shape.
///
/// It owns no UI. [AtlasUserButton] and [AtlasSignIn] bind to it, but so can
/// your own widgets.
class AtlasAuthState extends ChangeNotifier {
  AtlasAuthState(this.client);

  final AtlasClient client;

  AtlasUser? _user;
  bool _loading = false;
  AtlasException? _error;

  final ValueNotifier<AtlasUser?> _userNotifier = ValueNotifier<AtlasUser?>(null);

  /// The signed-in user, or `null` when signed out / not yet loaded.
  AtlasUser? get user => _user;

  /// Whether an auth operation is in flight.
  bool get loading => _loading;

  /// The last error, cleared at the start of each operation.
  AtlasException? get error => _error;

  /// Whether a user is currently signed in.
  bool get isSignedIn => _user != null;

  /// The user as a [ValueListenable], for `ValueListenableBuilder`.
  ValueListenable<AtlasUser?> get userListenable => _userNotifier;

  /// Load the persisted session, if any, and fetch the current user. Safe to
  /// call on app start; a no-op (user stays `null`) when signed out.
  Future<void> load() async {
    if (!await client.hasSession()) return;
    await _run(() => client.currentUser());
  }

  /// Re-fetch the current user (e.g. after a profile edit).
  Future<void> refreshUser() => _run(() => client.currentUser());

  /// Password sign-in via the one-shot [AtlasClient.signIn]. Returns true on
  /// success; on failure [error] is set and listeners are notified.
  Future<bool> signInWithPassword({
    required String email,
    required String password,
  }) async {
    final ok = await _run(() => client.signIn(email: email, password: password));
    return ok != null;
  }

  /// Adopt a user produced elsewhere (e.g. by a completed [SignInFlow] or a
  /// passkey / id_token sign-in) as the current session user.
  void setUser(AtlasUser user) {
    _user = user;
    _userNotifier.value = user;
    _error = null;
    _loading = false;
    notifyListeners();
  }

  /// Sign out server-side and clear local state.
  Future<void> signOut() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await client.signOut();
    } on AtlasException catch (e) {
      _error = e;
    } finally {
      _user = null;
      _userNotifier.value = null;
      _loading = false;
      notifyListeners();
    }
  }

  /// Run an operation that yields a user, tracking loading + error and
  /// notifying listeners. Returns the user on success, or `null` on an
  /// [AtlasException].
  Future<AtlasUser?> _run(Future<AtlasUser> Function() op) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final user = await op();
      _user = user;
      _userNotifier.value = user;
      return user;
    } on AtlasException catch (e) {
      _error = e;
      return null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _userNotifier.dispose();
    super.dispose();
  }
}
