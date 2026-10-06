import 'package:flutter/material.dart';

import '../atlas_client.dart';
import '../atlas_exception.dart';
import '../models.dart';
import 'auth_state.dart';

/// A prebuilt, self-driving sign-in widget.
///
/// It owns a [SignInFlow] and renders whatever step the server asks for —
/// identifier → first factor (password / email code) → second factor (TOTP /
/// SMS / backup code) → MFA enrollment → done — advancing the flow as the user
/// submits. On completion it fetches the user, updates the optional [session],
/// and calls [onComplete].
///
/// Pure Flutter/Material: no extra native plugin beyond what the SDK already
/// needs. Styling follows the ambient [Theme]; wrap it in your own `Theme` to
/// brand it. `AtlasSignIn` is the canonical name; [SignInView] is an alias.
class AtlasSignIn extends StatefulWidget {
  const AtlasSignIn({
    super.key,
    required this.client,
    this.session,
    this.onComplete,
    this.title = 'Sign in',
  });

  /// The client whose FAPI the flow drives and whose [TokenStore] the completed
  /// session is persisted to.
  final AtlasClient client;

  /// Optional session state to update on completion so the rest of the app sees
  /// the signed-in user immediately.
  final AtlasAuthState? session;

  /// Called once the sign-in completes, with the freshly signed-in user.
  final void Function(AtlasUser user)? onComplete;

  /// Heading shown above the form.
  final String title;

  @override
  State<AtlasSignIn> createState() => _AtlasSignInState();
}

/// Alias matching the Swift/Kotlin peers' `SignInView`.
typedef SignInView = AtlasSignIn;

class _AtlasSignInState extends State<AtlasSignIn> {
  late final SignInFlow _flow = widget.client.createSignIn();

  final _identifier = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  final _mfaCode = TextEditingController();

  FlowStep _step = const CollectIdentifier();
  MfaEnrollment? _enrollment;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    _code.dispose();
    _mfaCode.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<FlowStep> Function() op) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final step = await op();
      if (!mounted) return;
      setState(() => _step = step);
      if (step is FlowDone) await _finish();
    } on AtlasException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish() async {
    final user = await widget.client.currentUser();
    widget.session?.setUser(user);
    widget.onComplete?.call(user);
  }

  Future<void> _submitIdentifier() =>
      _guard(() => _flow.start(_identifier.text.trim()));

  Future<void> _submitPassword() =>
      _guard(() => _flow.attemptPassword(_password.text));

  Future<void> _submitEmailCode() =>
      _guard(() => _flow.attemptEmailCode(_code.text.trim()));

  Future<void> _submitSecondFactor() =>
      _guard(() => _flow.attemptTotp(_code.text.trim()));

  Future<void> _beginEnrollment() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final enrollment = await _flow.prepareMfaEnrollment();
      if (mounted) setState(() => _enrollment = enrollment);
    } on AtlasException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitEnrollment() {
    final enrollment = _enrollment;
    if (enrollment == null) return Future.value();
    return _guard(() => _flow.attemptMfaEnrollment(
          factorId: enrollment.factorId,
          codes: [_mfaCode.text.trim()],
        ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 16),
        if (_error != null) ...[
          _ErrorBanner(_error!),
          const SizedBox(height: 12),
        ],
        ..._bodyForStep(),
      ],
    );
  }

  List<Widget> _bodyForStep() {
    final step = _step;
    if (step is CollectIdentifier) {
      return [
        TextField(
          key: const Key('atlas.identifier'),
          controller: _identifier,
          decoration: const InputDecoration(labelText: 'Email or username'),
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.username],
          enabled: !_busy,
          onSubmitted: (_) => _submitIdentifier(),
        ),
        const SizedBox(height: 16),
        _primary('Continue', _submitIdentifier),
      ];
    }
    if (step is CollectFirstFactor) {
      final strategies = step.strategies;
      if (strategies.contains('password')) {
        return [
          TextField(
            key: const Key('atlas.password'),
            controller: _password,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            enabled: !_busy,
            onSubmitted: (_) => _submitPassword(),
          ),
          const SizedBox(height: 16),
          _primary('Sign in', _submitPassword),
        ];
      }
      // Passwordless: send and collect an email code.
      return [
        Text('We’ll email you a sign-in code.',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 16),
        _primary('Email me a code', () async {
          await _guard(() => _flow.prepareFirstFactor(strategy: 'email_code'));
        }),
      ];
    }
    if (step is CollectEmailCode) {
      return [
        TextField(
          key: const Key('atlas.email_code'),
          controller: _code,
          decoration: const InputDecoration(labelText: 'Verification code'),
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          enabled: !_busy,
          onSubmitted: (_) => _submitEmailCode(),
        ),
        const SizedBox(height: 16),
        _primary('Verify', _submitEmailCode),
      ];
    }
    if (step is CollectSecondFactor) {
      return [
        Text('Enter the code from your authenticator, SMS, or a backup code.',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 12),
        TextField(
          key: const Key('atlas.second_factor'),
          controller: _code,
          decoration: const InputDecoration(labelText: 'Two-factor code'),
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          enabled: !_busy,
          onSubmitted: (_) => _submitSecondFactor(),
        ),
        const SizedBox(height: 16),
        _primary('Verify', _submitSecondFactor),
      ];
    }
    if (step is EnrollSecondFactor) {
      final enrollment = _enrollment;
      if (enrollment == null) {
        return [
          Text('Your account must set up two-factor authentication.',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          _primary('Set up authenticator', _beginEnrollment),
        ];
      }
      return [
        Text('Scan this in your authenticator app, or enter the key:',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        SelectableText(
          enrollment.secret,
          key: const Key('atlas.totp_secret'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('atlas.enrollment_code'),
          controller: _mfaCode,
          decoration: const InputDecoration(labelText: 'Code from the app'),
          keyboardType: TextInputType.number,
          enabled: !_busy,
          onSubmitted: (_) => _submitEnrollment(),
        ),
        const SizedBox(height: 16),
        _primary('Confirm', _submitEnrollment),
      ];
    }
    if (step is CollectCaptcha) {
      return [
        Text('A challenge is required to continue. Complete it in your app’s '
            'captcha widget, then retry.',
            style: Theme.of(context).textTheme.bodyMedium),
      ];
    }
    if (step is AwaitOauth) {
      return [
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 12),
        Text('Finishing sign-in…',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium),
      ];
    }
    if (step is FlowDone) {
      return [
        Text('You’re signed in.',
            style: Theme.of(context).textTheme.bodyLarge),
      ];
    }
    if (step is FlowRestart) {
      return [
        Text('That attempt expired. Please start again.',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 16),
        _primary('Start over', () async {
          setState(() => _step = const CollectIdentifier());
        }),
      ];
    }
    // FlowUnknown / CollectNewPassword (not expected in sign-in) — be honest.
    return [
      Text('This sign-in needs a newer version of the app.',
          style: Theme.of(context).textTheme.bodyMedium),
    ];
  }

  Widget _primary(String label, Future<void> Function() onPressed) {
    return FilledButton(
      onPressed: _busy ? null : () => onPressed(),
      child: _busy
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(label),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: const Key('atlas.error'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(color: scheme.onErrorContainer),
      ),
    );
  }
}
