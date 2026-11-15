import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('known factors', () {
    expect(stepUpFactors.length, 9);
    expect(stepUpFactorInfo('password').inputKind, StepUpInputKind.password);
    expect(stepUpFactorInfo('passkey').inputKind, StepUpInputKind.webauthn);
    expect(stepUpFactorInfo('duo').inputKind, StepUpInputKind.redirect);
    expect(stepUpFactorInfo('push').needsInput, false);
  });

  test('unknown factor falls back', () {
    final i = stepUpFactorInfo('smart_card');
    expect(i.label, 'Smart card');
    expect(i.needsInput, true);
    expect(i.inputKind, StepUpInputKind.otp);
  });
}
