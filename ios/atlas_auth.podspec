Pod::Spec.new do |s|
  s.name             = 'atlas_auth'
  s.version          = '0.11.0'
  s.summary          = 'Atlas auth: device-bound biometric sign-in key (Secure Enclave).'
  s.homepage         = 'https://atlasauth.net'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Atlas' => 'support@atlasauth.net' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency       'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
end
