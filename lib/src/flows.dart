part of 'atlas_client.dart';

/// §5: the status of a sign-in / sign-up / password-reset attempt.
///
/// The client never decides what step comes next — it reads [AtlasClient]'s
/// attempt `status` and renders whatever the server demands. This enum mirrors
/// the server's attempt-machine statuses; a status this SDK version does not
/// recognise maps to [unknown] rather than silently falling through to a blank
/// screen.
enum FlowStatus {
  needsIdentifier,
  needsFirstFactor,
  needsSecondFactor,

  /// §11.1 MFA policy `required`, for a user who has no second factor yet.
  needsMfaEnrollment,

  /// Email-code verification — the sign-up email step, or an email_code first
  /// factor the server asks to be verified.
  needsEmailVerification,
  needsOauthCallback,
  needsNewPassword,
  needsCaptcha,
  complete,
  abandoned,

  /// A status this SDK version does not know — render "please update" rather
  /// than nothing.
  unknown,
}

/// Map a server status string to a [FlowStatus].
FlowStatus flowStatusFromString(String status) {
  switch (status) {
    case 'needs_identifier':
      return FlowStatus.needsIdentifier;
    case 'needs_first_factor':
      return FlowStatus.needsFirstFactor;
    case 'needs_second_factor':
      return FlowStatus.needsSecondFactor;
    case 'needs_mfa_enrollment':
      return FlowStatus.needsMfaEnrollment;
    case 'needs_email_verification':
    case 'missing_requirements': // sign-up alias for the verification step
      return FlowStatus.needsEmailVerification;
    case 'needs_oauth_callback':
      return FlowStatus.needsOauthCallback;
    case 'needs_new_password':
      return FlowStatus.needsNewPassword;
    case 'needs_captcha':
      return FlowStatus.needsCaptcha;
    case 'complete':
      return FlowStatus.complete;
    case 'abandoned':
      return FlowStatus.abandoned;
    default:
      return FlowStatus.unknown;
  }
}

/// What the UI should render next for an attempt (§5). An exhaustive, sealed
/// mapping so an unhandled status is a compile-time concern, never a blank box.
sealed class FlowStep {
  const FlowStep();
}

/// Collect an identifier (email / username / phone) to start the attempt.
class CollectIdentifier extends FlowStep {
  const CollectIdentifier();
}

/// Collect a first factor. [strategies] is the server's list — never narrowed
/// client-side, which would reintroduce the §13.2 enumeration leak.
class CollectFirstFactor extends FlowStep {
  const CollectFirstFactor(this.strategies);
  final List<String> strategies;
}

/// Collect a second factor (TOTP, SMS, backup code, push, or passkey).
class CollectSecondFactor extends FlowStep {
  const CollectSecondFactor(this.strategies);
  final List<String> strategies;
}

/// §11.1: this user must enrol a second factor before they can finish.
class EnrollSecondFactor extends FlowStep {
  const EnrollSecondFactor();
}

/// Collect an emailed verification code (sign-up, or an email_code factor).
class CollectEmailCode extends FlowStep {
  const CollectEmailCode();
}

/// Collect a new password (the end of a password-reset flow).
class CollectNewPassword extends FlowStep {
  const CollectNewPassword();
}

/// A CAPTCHA challenge must be solved before the attempt can proceed.
class CollectCaptcha extends FlowStep {
  const CollectCaptcha();
}

/// Waiting on an OAuth redirect to return.
class AwaitOauth extends FlowStep {
  const AwaitOauth();
}

/// The attempt is complete and the session is persisted. [sessionId] is the new
/// session's id when the server reported one.
class FlowDone extends FlowStep {
  const FlowDone(this.sessionId);
  final String? sessionId;
}

/// The attempt expired or was abandoned — start over.
class FlowRestart extends FlowStep {
  const FlowRestart(this.reason);
  final String reason;
}

/// A status this SDK version does not model.
class FlowUnknown extends FlowStep {
  const FlowUnknown(this.status);
  final String status;
}

/// Derive the [FlowStep] for a status + attempt.
FlowStep _stepFor(FlowStatus status, SignInAttempt? attempt) {
  switch (status) {
    case FlowStatus.needsIdentifier:
      return const CollectIdentifier();
    case FlowStatus.needsFirstFactor:
      return CollectFirstFactor(attempt?.supportedFirstFactors ?? const []);
    case FlowStatus.needsSecondFactor:
      return CollectSecondFactor(attempt?.supportedSecondFactors ?? const []);
    case FlowStatus.needsMfaEnrollment:
      return const EnrollSecondFactor();
    case FlowStatus.needsEmailVerification:
      return const CollectEmailCode();
    case FlowStatus.needsNewPassword:
      return const CollectNewPassword();
    case FlowStatus.needsCaptcha:
      return const CollectCaptcha();
    case FlowStatus.needsOauthCallback:
      return const AwaitOauth();
    case FlowStatus.complete:
      return FlowDone(attempt?.createdSessionId);
    case FlowStatus.abandoned:
      return const FlowRestart('abandoned');
    case FlowStatus.unknown:
      return FlowUnknown(attempt?.status ?? '');
  }
}

/// A multi-step **sign-in** state machine over `/v1/client/sign_ins`.
///
/// Create one with [AtlasClient.createSignIn]. After each step read [status] /
/// [nextStep] and call the matching method; the flow stores the latest attempt
/// and, on `complete`, persists the session through the client's [TokenStore]
/// (the same handling as [AtlasClient.signInWithPasskey]). The one-shot
/// [AtlasClient.signIn] is unchanged and remains the quick path for plain
/// password sign-in.
class SignInFlow {
  SignInFlow(this._client);

  final AtlasClient _client;

  SignInAttempt? _attempt;
  List<String> _backupCodes = const [];

  /// The latest attempt, or `null` before [start].
  SignInAttempt? get attempt => _attempt;

  /// The attempt id, or `null` before [start].
  String? get attemptId => _attempt?.id;

  /// The current status; [FlowStatus.needsIdentifier] before [start].
  FlowStatus get status => _attempt == null
      ? FlowStatus.needsIdentifier
      : flowStatusFromString(_attempt!.status);

  /// What the UI should render next.
  FlowStep get nextStep => _stepFor(status, _attempt);

  /// Whether the attempt has completed (and the session is persisted).
  bool get isComplete => status == FlowStatus.complete;

  /// Backup codes handed back once, when an MFA enrollment produced them.
  List<String> get backupCodes => _backupCodes;

  /// Create the attempt with an [identifier] (`POST /v1/client/sign_ins`).
  Future<FlowStep> start(String identifier) =>
      _advance('POST', '/v1/client/sign_ins', {'identifier': identifier});

  /// §5.3 send a first-factor code or magic link
  /// (`POST …/:id/prepare_first_factor`). [strategy] is `email_code`,
  /// `email_link` or `phone_code`; [channel] (sms/whatsapp/voice) is optional
  /// for `phone_code`.
  Future<FlowStep> prepareFirstFactor({
    required String strategy,
    String? channel,
  }) =>
      _advance(
        'POST',
        '/v1/client/sign_ins/$_id/prepare_first_factor',
        {'strategy': strategy, if (channel != null) 'channel': channel},
      );

  /// Submit the first factor (`POST …/:id/attempt_first_factor`). Pass a
  /// [password], or a [code] for an `email_code` / `phone_code` strategy.
  Future<FlowStep> attemptFirstFactor({
    required String strategy,
    String? password,
    String? code,
  }) =>
      _advance(
        'POST',
        '/v1/client/sign_ins/$_id/attempt_first_factor',
        {
          'strategy': strategy,
          if (password != null) 'password': password,
          if (code != null) 'code': code,
        },
      );

  /// Convenience: submit a password first factor.
  Future<FlowStep> attemptPassword(String password) =>
      attemptFirstFactor(strategy: 'password', password: password);

  /// Convenience: submit an emailed-code first factor.
  Future<FlowStep> attemptEmailCode(String code) =>
      attemptFirstFactor(strategy: 'email_code', code: code);

  /// Convenience: submit a texted-code first factor.
  Future<FlowStep> attemptPhoneCode(String code) =>
      attemptFirstFactor(strategy: 'phone_code', code: code);

  /// §5.3 prepare a second factor (`POST …/:id/prepare_second_factor`) — text
  /// an SMS code, push an approval, or get passkey options. Does NOT change the
  /// attempt status; it returns the challenge to show. [strategy] is `sms`,
  /// `push`, or omitted for a passkey challenge.
  Future<SecondFactorPreparation> prepareSecondFactor({String? strategy}) async {
    final response = await _client._send(
      'POST',
      '/v1/client/sign_ins/$_id/prepare_second_factor',
      body: strategy != null ? {'strategy': strategy} : const <String, String>{},
    );
    _client._throwIfError(response);
    return SecondFactorPreparation.fromJson(_client._decode(response));
  }

  /// Submit a second factor (`POST …/:id/attempt_second_factor`). Pass a [code]
  /// for TOTP, an SMS OTP, or a backup/recovery code; pass `strategy: 'push'`
  /// to poll an in-progress push approval.
  Future<FlowStep> attemptSecondFactor({
    String? code,
    String? strategy,
    bool? rememberDevice,
  }) =>
      _advance(
        'POST',
        '/v1/client/sign_ins/$_id/attempt_second_factor',
        {
          if (code != null) 'code': code,
          if (strategy != null) 'strategy': strategy,
          if (rememberDevice != null) 'remember_device': rememberDevice,
        },
      );

  /// Convenience: submit a TOTP / backup / SMS code second factor.
  Future<FlowStep> attemptTotp(String code, {bool? rememberDevice}) =>
      attemptSecondFactor(code: code, rememberDevice: rememberDevice);

  /// §11.1 start enrolling a TOTP second factor mid-sign-in
  /// (`POST …/:id/prepare_mfa_enrollment`). The returned [MfaEnrollment.secret]
  /// / `uri` are shown once; confirm with [attemptMfaEnrollment].
  Future<MfaEnrollment> prepareMfaEnrollment() async {
    final response = await _client._send(
      'POST',
      '/v1/client/sign_ins/$_id/prepare_mfa_enrollment',
      body: const <String, String>{},
    );
    _client._throwIfError(response);
    return MfaEnrollment.fromJson(_client._decode(response));
  }

  /// §11.1 confirm the TOTP enrollment with one or two consecutive [codes]
  /// (`POST …/:id/attempt_mfa_enrollment`). On success the generated backup
  /// codes are surfaced on [backupCodes], and the attempt advances (often to
  /// `complete`).
  Future<FlowStep> attemptMfaEnrollment({
    required String factorId,
    required List<String> codes,
  }) =>
      _advance(
        'POST',
        '/v1/client/sign_ins/$_id/attempt_mfa_enrollment',
        {'factor_id': factorId, 'codes': codes},
      );

  String get _id {
    final id = _attempt?.id;
    if (id == null) {
      throw AtlasException.transport('Call start() before advancing the flow.');
    }
    return Uri.encodeComponent(id);
  }

  Future<FlowStep> _advance(
    String method,
    String path,
    Object body,
  ) async {
    final response = await _client._send(method, path, body: body);
    _client._throwIfError(response);
    final decoded = _client._decode(response);
    final backup = decoded['backup_codes'];
    if (backup is List) {
      _backupCodes = backup.whereType<String>().toList(growable: false);
    }
    final attempt = SignInAttempt.fromJson(decoded);
    _attempt = attempt;
    if (attempt.isComplete) {
      await _client._persistAttemptCompletion(attempt, response, decoded);
    }
    return nextStep;
  }
}

/// A multi-step **sign-up** state machine over `/v1/client/sign_ups`.
///
/// Create one with [AtlasClient.createSignUp]. Completion persists the session
/// through the client's [TokenStore], like [SignInFlow].
class SignUpFlow {
  SignUpFlow(this._client);

  final AtlasClient _client;
  SignInAttempt? _attempt;

  SignInAttempt? get attempt => _attempt;
  String? get attemptId => _attempt?.id;
  FlowStatus get status => _attempt == null
      ? FlowStatus.needsIdentifier
      : flowStatusFromString(_attempt!.status);
  FlowStep get nextStep => _stepFor(status, _attempt);
  bool get isComplete => status == FlowStatus.complete;

  /// Create the sign-up attempt (`POST /v1/client/sign_ups`). [fields] are the
  /// tenant's configured extra fields; [consent] satisfies a required legal
  /// agreement; [organizationId] seats a reader-pool sign-up.
  Future<FlowStep> create({
    required String email,
    required String password,
    Map<String, String>? fields,
    bool? consent,
    String? organizationId,
    String? captchaToken,
  }) =>
      _advance('POST', '/v1/client/sign_ups', {
        'email': email,
        'password': password,
        if (fields != null) 'fields': fields,
        if (consent != null) 'consent': consent,
        if (organizationId != null) 'organization_id': organizationId,
        if (captchaToken != null) 'captcha_token': captchaToken,
      });

  /// (Re)send the verification email (`POST …/:id/prepare_verification`).
  Future<FlowStep> prepareVerification() =>
      _advance('POST', '/v1/client/sign_ups/$_id/prepare_verification',
          const <String, String>{});

  /// Submit the emailed verification [code] (`POST …/:id/attempt_verification`).
  Future<FlowStep> attemptVerification(String code) => _advance(
        'POST',
        '/v1/client/sign_ups/$_id/attempt_verification',
        {'code': code},
      );

  String get _id {
    final id = _attempt?.id;
    if (id == null) {
      throw AtlasException.transport('Call create() before advancing the flow.');
    }
    return Uri.encodeComponent(id);
  }

  Future<FlowStep> _advance(String method, String path, Object body) async {
    final response = await _client._send(method, path, body: body);
    _client._throwIfError(response);
    final decoded = _client._decode(response);
    final attempt = SignInAttempt.fromJson(decoded);
    _attempt = attempt;
    if (attempt.isComplete) {
      await _client._persistAttemptCompletion(attempt, response, decoded);
    }
    return nextStep;
  }
}

/// A **password-reset** state machine over `/v1/client/password_resets`
/// (§5.4): request a code → verify it → pass a second factor if the account has
/// MFA → set a new password.
///
/// Create one with [AtlasClient.createPasswordReset]. When the instance allows
/// sign-in after reset, completing [setNewPassword] persists the session; when
/// it does not, the flow completes without a session and the user signs in
/// afresh.
class PasswordResetFlow {
  PasswordResetFlow(this._client);

  final AtlasClient _client;
  SignInAttempt? _attempt;

  SignInAttempt? get attempt => _attempt;
  String? get attemptId => _attempt?.id;
  FlowStatus get status => _attempt == null
      ? FlowStatus.needsIdentifier
      : flowStatusFromString(_attempt!.status);
  FlowStep get nextStep => _stepFor(status, _attempt);
  bool get isComplete => status == FlowStatus.complete;

  /// Request a reset code for [email] (`POST /v1/client/password_resets`). The
  /// response is identical whether or not the address exists (anti-enumeration).
  Future<FlowStep> request(String email, {String? captchaToken}) =>
      _advance('POST', '/v1/client/password_resets', {
        'email_address': email,
        if (captchaToken != null) 'captcha_token': captchaToken,
      });

  /// Submit the emailed [code] (`POST …/:id/attempt_verification`).
  Future<FlowStep> attemptVerification(String code) => _advance(
        'POST',
        '/v1/client/password_resets/$_id/attempt_verification',
        {'code': code},
      );

  /// Pass the account's second factor when the reset requires one
  /// (`POST …/:id/attempt_second_factor`) — a reset never bypasses MFA.
  Future<FlowStep> attemptSecondFactor(String code) => _advance(
        'POST',
        '/v1/client/password_resets/$_id/attempt_second_factor',
        {'code': code},
      );

  /// Set the new [password] (`POST …/:id/set_new_password`). Every other session
  /// is revoked server-side; when sign-in-after-reset is on, the returned ticket
  /// is exchanged and the session persisted.
  Future<FlowStep> setNewPassword(String password) => _advance(
        'POST',
        '/v1/client/password_resets/$_id/set_new_password',
        {'password': password},
      );

  String get _id {
    final id = _attempt?.id;
    if (id == null) {
      throw AtlasException.transport(
          'Call request() before advancing the flow.');
    }
    return Uri.encodeComponent(id);
  }

  Future<FlowStep> _advance(String method, String path, Object body) async {
    final response = await _client._send(method, path, body: body);
    _client._throwIfError(response);
    final decoded = _client._decode(response);
    final attempt = SignInAttempt.fromJson(decoded);
    _attempt = attempt;
    // set_new_password hands back a ticket only when sign-in-after-reset is on;
    // persist a session when one is materialisable, otherwise leave the user to
    // sign in afresh.
    if (attempt.isComplete && attempt.ticket != null) {
      await _client._persistAttemptCompletion(attempt, response, decoded);
    }
    return nextStep;
  }
}
