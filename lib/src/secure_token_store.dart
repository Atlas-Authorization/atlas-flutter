import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'models.dart';
import 'token_store.dart';

/// The production [TokenStore]: the session lives in OS-backed secure storage —
/// the Keychain on iOS/macOS and the EncryptedSharedPreferences-backed Keystore
/// on Android — encrypted at rest and outside the app's own sandboxed files.
///
/// One entry per [account] (usually the publishable key, so two Atlas instances
/// in one app do not collide), holding the JSON-encoded [AtlasSession].
///
/// The iOS accessibility is set to `first_unlock_this_device` deliberately: the
/// token is readable in the background (a refresh that fires while the phone is
/// locked) but never leaves the device in an iCloud backup, which a session
/// token has no business doing.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({
    required this.account,
    FlutterSecureStorage? storage,
    String service = 'com.atlas.sdk.session',
  })  : _service = service,
        _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  /// The account key — usually the publishable key.
  final String account;
  final String _service;
  final FlutterSecureStorage _storage;

  /// The storage key: service + account, so instances never collide.
  String get _key => '$_service.$account';

  @override
  Future<void> save(AtlasSession session) =>
      _storage.write(key: _key, value: jsonEncode(session.toJson()));

  @override
  Future<AtlasSession?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return AtlasSession.fromJson(decoded.cast<String, dynamic>());
      }
    } catch (_) {
      // A corrupt entry is treated as no session; the next sign-in overwrites it.
    }
    return null;
  }

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
