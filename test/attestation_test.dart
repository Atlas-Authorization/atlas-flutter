import 'dart:convert';

import 'package:atlas_auth/atlas_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('guards only the sign-up, sign-in and SMS-send posts', () {
    expect(isAttestationGuarded('POST', '/v1/client/sign_ups'), isTrue);
    expect(isAttestationGuarded('POST', '/v1/client/sign_ins?x=1'), isTrue);
    expect(isAttestationGuarded('POST', '/v1/client/me/phone_numbers/pn_1/prepare_verification'), isTrue);
    expect(isAttestationGuarded('GET', '/v1/client/sign_ins'), isFalse);
    expect(isAttestationGuarded('POST', '/v1/client/me'), isFalse);
  });

  test('header is base64url JSON for both platforms', () {
    Map<String, dynamic> decode(String h) =>
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(h)))) as Map<String, dynamic>;
    expect(decode(const AtlasAttestationProof.playIntegrity('tok').toHeader('n1')), {'n': 'n1', 'p': 'android', 't': 'tok'});
    expect(
      decode(const AtlasAttestationProof.appAttest(assertion: 'a', receipt: 'r').toHeader('n1')),
      {'n': 'n1', 'p': 'ios', 'a': 'a', 'r': 'r'},
    );
  });
}
