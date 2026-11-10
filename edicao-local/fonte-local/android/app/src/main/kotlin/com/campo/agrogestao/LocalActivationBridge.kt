package com.campo.agrogestao

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec

/** All private-key operations stay in AndroidKeyStore; the app exports only SPKI and signatures. */
class LocalActivationBridge(private val context: Context) {
    private val alias = "agrogestor_local_installation_v1"
    private val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val licenseFile = AtomicFile(File(context.filesDir, "agro_local_activation/license-v1.json"))
    private fun encode(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    private fun decode(text: String): ByteArray {
        require(text.matches(Regex("[A-Za-z0-9_-]{1,12000}")))
        return Base64.decode(text, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }
    private fun sha(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun publicBytes() = store.getCertificate(alias)?.publicKey?.encoded ?: error("Missing installation key")
    private fun privateKey() = store.getKey(alias, null) as PrivateKey
    private fun ensureKey() {
        if (store.containsAlias(alias)) return
        // A key loss never silently replaces the authorized installation identity.
        require(!licenseFile.baseFile.exists()) { "Installation key lost" }
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        generator.initialize(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256).setUserAuthenticationRequired(false).build())
        generator.generateKeyPair()
    }
    fun identity(): Map<String, Any> {
        ensureKey()
        require(privateKey().encoded == null) { "Exportable installation key rejected" }
        return mapOf("publicKey" to encode(publicBytes()), "fingerprint" to sha(publicBytes()),
            "appId" to context.packageName, "nonExportable" to true)
    }
    fun sign(message: String): String {
        require(message.length in 1..4096)
        ensureKey()
        return encode(Signature.getInstance("SHA256withECDSA").run {
            initSign(privateKey()); update(message.toByteArray(StandardCharsets.UTF_8)); sign()
        })
    }
    fun verify(document: String): Map<String, Any> = try {
        require(document.length in 1..16384)
        require(context.packageName == "com.campo.agrogestao.localpilot")
        require(BuildConfig.ACTIVATION_ISSUER_SPKI.isNotEmpty())
        require(store.containsAlias(alias))
        val envelope = JSONObject(document)
        require(envelope.length() == 3)
        val payloadBytes = decode(envelope.getString("payload"))
        val issuerBytes = decode(BuildConfig.ACTIVATION_ISSUER_SPKI)
        val issuer = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(issuerBytes))
        require(envelope.getString("keyId") == sha(issuerBytes).take(16))
        require(Signature.getInstance("SHA256withECDSA").run {
            initVerify(issuer); update(payloadBytes); verify(decode(envelope.getString("signature")))
        })
        val payload = JSONObject(String(payloadBytes, StandardCharsets.UTF_8))
        require(payload.getString("format") == "agrogestor-local-license")
        require(payload.getInt("schemaVersion") == 1)
        require(payload.getString("appId") == context.packageName)
        require(payload.getString("kind") == "free_perpetual")
        require(payload.has("expiresAt") && payload.isNull("expiresAt"))
        require(payload.getString("installationKeySha256") == sha(publicBytes()))
        require(payload.getString("licenseId").matches(Regex("[0-9a-f-]{36}")))
        // Prove the corresponding private key is still usable, rather than trusting a copied public key.
        val nonce = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val signature = Signature.getInstance("SHA256withECDSA").run { initSign(privateKey()); update(nonce); sign() }
        require(Signature.getInstance("SHA256withECDSA").run { initVerify(store.getCertificate(alias).publicKey); update(nonce); verify(signature) })
        mapOf("valid" to true, "licenseId" to payload.getString("licenseId"),
            "fingerprint" to sha(publicBytes()), "issuedAt" to payload.getString("issuedAt"), "kind" to "free_perpetual")
    } catch (error: Exception) { mapOf("valid" to false, "reason" to "invalid_license") }

    fun status(): Map<String, Any> {
        if (BuildConfig.ACTIVATION_ISSUER_SPKI.isEmpty()) return mapOf("valid" to false, "reason" to "issuer_not_configured")
        if (!licenseFile.baseFile.exists()) return mapOf("valid" to false, "reason" to "not_activated")
        return try {
            if (licenseFile.baseFile.length() > 16384) mapOf("valid" to false, "reason" to "invalid_license")
            else verify(String(licenseFile.readFully(), StandardCharsets.UTF_8))
        } catch (error: Exception) { mapOf("valid" to false, "reason" to "storage_error") }
    }
    fun accept(document: String): Map<String, Any> {
        val checked = verify(document)
        require(checked["valid"] == true) { "Invalid installation license" }
        licenseFile.baseFile.parentFile!!.mkdirs()
        val stream = licenseFile.startWrite()
        try {
            stream.write(document.toByteArray(StandardCharsets.UTF_8))
            licenseFile.finishWrite(stream)
        } catch (error: Exception) { licenseFile.failWrite(stream); throw error }
        return status().also { require(it["valid"] == true) }
    }
}
