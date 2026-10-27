package net.atlasauth.atlas_auth

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/** Device-bound sign-in key: an ES256 key in the Android Keystore behind BiometricPrompt. */
class AtlasDeviceKeyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var channel: MethodChannel? = null
    private var activity: FragmentActivity? = null
    private var biometricBound = true

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "net.atlasauth.atlas/device_key").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity as? FragmentActivity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity as? FragmentActivity }
    override fun onDetachedFromActivity() { activity = null }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "createKey" -> result.success(createKey(call.argument<Boolean>("biometric") ?: true))
                "sign" -> sign(call.argument<String>("message") ?: "", call.argument<String>("title") ?: "Sign in", result)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("device_key", e.message, null)
        }
    }

    private fun b64(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

    private fun fixed32(v: BigInteger): ByteArray {
        val raw = v.toByteArray()
        val u = if (raw.size > 1 && raw[0] == 0.toByte()) raw.copyOfRange(1, raw.size) else raw
        require(u.size <= 32)
        return ByteArray(32 - u.size) + u
    }

    private fun createKey(biometric: Boolean): Map<String, String> {
        biometricBound = biometric
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        store.deleteEntry(ALIAS)
        fun spec(strongBox: Boolean): KeyGenParameterSpec {
            val b = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
            if (biometric) {
                b.setUserAuthenticationRequired(true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) b.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
                b.setInvalidatedByBiometricEnrollment(true)
            }
            if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) b.setIsStrongBoxBacked(true)
            return b.build()
        }
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        val pair = try {
            gen.initialize(spec(true)); gen.generateKeyPair()
        } catch (e: Exception) {
            gen.initialize(spec(false)); gen.generateKeyPair()
        }
        val w = (pair.public as ECPublicKey).w
        return mapOf("x" to b64(fixed32(w.affineX)), "y" to b64(fixed32(w.affineY)))
    }

    private fun p1363(der: ByteArray): ByteArray {
        var i = 1
        fun len(): Int {
            val f = der[i++].toInt() and 0xff
            if (f < 0x80) return f
            var l = 0
            repeat(f and 0x7f) { l = (l shl 8) or (der[i++].toInt() and 0xff) }
            return l
        }
        fun int(): ByteArray {
            require(der[i++] == 0x02.toByte())
            val l = len()
            val v = BigInteger(1, der.copyOfRange(i, i + l)); i += l
            return fixed32(v)
        }
        require(der.isNotEmpty() && der[0] == 0x30.toByte())
        len()
        val r = int(); val s = int()
        return r + s
    }

    private fun sign(message: String, title: String, result: MethodChannel.Result) {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val key = store.getKey(ALIAS, null) as? PrivateKey ?: return result.error("no_key", "No device key on this device.", null)
        val signature = Signature.getInstance("SHA256withECDSA").apply { initSign(key) }
        fun finish(sig: Signature) {
            try {
                sig.update(message.toByteArray(Charsets.UTF_8))
                result.success(b64(p1363(sig.sign())))
            } catch (e: Exception) {
                result.error("sign_failed", e.message, null)
            }
        }
        if (!biometricBound) return finish(signature)
        val host = activity ?: return result.error("no_activity", "A FragmentActivity (FlutterFragmentActivity) is required for the biometric prompt.", null)
        val prompt = BiometricPrompt(host, ContextCompat.getMainExecutor(host), object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(r: BiometricPrompt.AuthenticationResult) {
                r.cryptoObject?.signature?.let(::finish) ?: result.error("no_key", "The biometric prompt returned no key.", null)
            }

            override fun onAuthenticationError(code: Int, msg: CharSequence) { result.error("cancelled", msg.toString(), null) }
        })
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
            .build()
        host.runOnUiThread { prompt.authenticate(info, BiometricPrompt.CryptoObject(signature)) }
    }

    private companion object { const val ALIAS = "net.atlasauth.device-key" }
}
