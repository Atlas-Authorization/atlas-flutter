/// What a step-up factor needs from the person. A factor the SDK does not know
/// yet (the server adds them in minor releases) maps to [StepUpInputKind.otp].
enum StepUpInputKind { password, otp, none, redirect, push, webauthn }

/// How to render a step-up factor. [factor] is the raw wire string.
class StepUpFactorInfo {
  const StepUpFactorInfo(this.factor, this.label, this.needsInput, this.inputKind);
  final String factor;
  final String label;
  final bool needsInput;
  final StepUpInputKind inputKind;
}

const _known = <String, StepUpFactorInfo>{
  'password': StepUpFactorInfo('password', 'Password', true, StepUpInputKind.password),
  'passkey': StepUpFactorInfo('passkey', 'Passkey', false, StepUpInputKind.webauthn),
  'totp': StepUpFactorInfo('totp', 'Authenticator app code', true, StepUpInputKind.otp),
  'backup_code': StepUpFactorInfo('backup_code', 'Backup code', true, StepUpInputKind.otp),
  'email_code': StepUpFactorInfo('email_code', 'Code sent by email', true, StepUpInputKind.otp),
  'phone_code': StepUpFactorInfo('phone_code', 'Code sent by text message', true, StepUpInputKind.otp),
  'push': StepUpFactorInfo('push', 'Approve on your device', false, StepUpInputKind.push),
  'duo': StepUpFactorInfo('duo', 'Duo', false, StepUpInputKind.redirect),
  'yubikey': StepUpFactorInfo('yubikey', 'Security key code', true, StepUpInputKind.otp),
};

/// Every factor this SDK version knows; a newer server may offer more.
final List<String> stepUpFactors = List.unmodifiable(_known.keys);

/// Render info for any factor string; an unknown one gets a readable label and a typed-code input.
StepUpFactorInfo stepUpFactorInfo(String factor) {
  final k = _known[factor];
  if (k != null) return k;
  final words = factor.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  final label = words.isEmpty ? 'Verification' : words[0].toUpperCase() + words.substring(1);
  return StepUpFactorInfo(factor, label, true, StepUpInputKind.otp);
}
