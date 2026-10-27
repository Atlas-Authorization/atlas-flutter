import Flutter
import Foundation
import LocalAuthentication
import Security

/// Device-bound sign-in key: an ES256 key in the Secure Enclave, unlocked by Face ID / Touch ID.
public class AtlasDeviceKeyPlugin: NSObject, FlutterPlugin {
    private let tag = Data("net.atlasauth.device-key".utf8)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "net.atlasauth.atlas/device_key", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(AtlasDeviceKeyPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "createKey": createKey(biometric: args["biometric"] as? Bool ?? true, result: result)
        case "sign": sign(message: args["message"] as? String ?? "", title: args["title"] as? String ?? "Sign in", result: result)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func createKey(biometric: Bool, result: FlutterResult) {
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
        var flags: SecAccessControlCreateFlags = biometric ? [.biometryCurrentSet] : []
        #if !targetEnvironment(simulator)
        flags.insert(.privateKeyUsage)
        #endif
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, flags, &err) else {
            return result(FlutterError(code: "device_key", message: "Could not create the key access control.", details: nil))
        }
        var attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessControl as String: access,
            ],
        ]
        #if !targetEnvironment(simulator)
        attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        #endif
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &err),
              let pub = SecKeyCopyPublicKey(priv),
              let point = SecKeyCopyExternalRepresentation(pub, &err) as Data?, point.count == 65 else {
            return result(FlutterError(code: "device_key", message: "Could not create the device key.", details: nil))
        }
        result(["x": b64(point.subdata(in: 1..<33)), "y": b64(point.subdata(in: 33..<65))])
    }

    private func sign(message: String, title: String, result: @escaping FlutterResult) {
        DispatchQueue.global().async {
            let ctx = LAContext()
            ctx.localizedReason = title
            var item: CFTypeRef?
            let q: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: self.tag,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecReturnRef as String: true,
                kSecUseAuthenticationContext as String: ctx,
            ]
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let item else {
                return DispatchQueue.main.async { result(FlutterError(code: "no_key", message: "No device key on this device.", details: nil)) }
            }
            var err: Unmanaged<CFError>?
            guard let der = SecKeyCreateSignature(item as! SecKey, .ecdsaSignatureMessageX962SHA256, Data(message.utf8) as CFData, &err) as Data?,
                  let raw = Self.p1363(der) else {
                return DispatchQueue.main.async { result(FlutterError(code: "cancelled", message: "The device key could not sign.", details: nil)) }
            }
            DispatchQueue.main.async { result(self.b64(raw)) }
        }
    }

    /// ASN.1 DER ECDSA -> fixed 64-byte r || s.
    static func p1363(_ der: Data) -> Data? {
        let b = [UInt8](der)
        var i = 0
        func len() -> Int? {
            guard i < b.count else { return nil }
            let f = Int(b[i]); i += 1
            if f < 0x80 { return f }
            let n = f & 0x7f
            guard n > 0, n <= 2, i + n <= b.count else { return nil }
            var l = 0
            for _ in 0..<n { l = (l << 8) | Int(b[i]); i += 1 }
            return l
        }
        func int() -> [UInt8]? {
            guard i < b.count, b[i] == 0x02 else { return nil }
            i += 1
            guard let l = len(), l > 0, i + l <= b.count else { return nil }
            var v = Array(b[i..<(i + l)]); i += l
            while v.count > 1, v.first == 0 { v.removeFirst() }
            guard v.count <= 32 else { return nil }
            return [UInt8](repeating: 0, count: 32 - v.count) + v
        }
        guard i < b.count, b[i] == 0x30 else { return nil }
        i += 1
        guard len() != nil, let r = int(), let s = int() else { return nil }
        return Data(r + s)
    }
}
