package com.iflytek.lanmediacast.receiver.security

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.Calendar
import java.util.Date
import java.util.UUID
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.security.auth.x500.X500Principal

class ReceiverIdentity(private val context: Context) {
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }

    val deviceId: String = preferences.getString(KEY_DEVICE_ID, null) ?: UUID.randomUUID().toString().also {
        preferences.edit().putString(KEY_DEVICE_ID, it).apply()
    }

    val deviceName: String
        get() {
            val savedName = preferences.getString(KEY_DEVICE_NAME, null)
                ?.takeUnless { it.startsWith(LEGACY_DEFAULT_PREFIX) }
            val systemName = Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            return savedName ?: resolveDeviceName(systemName, Build.MANUFACTURER, Build.MODEL)
        }

    val certificate: X509Certificate
        get() = keyStore.getCertificate(TLS_ALIAS) as X509Certificate

    val certificateSha256: ByteArray
        get() = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)

    val certificateSha256Base64Url: String
        get() = Base64.encodeToString(certificateSha256, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    init {
        ensureTlsKey()
    }

    fun createServerSslContext(): SSLContext {
        val keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply {
            init(keyStore, null)
        }.keyManagers
        return SSLContext.getInstance("TLS").apply {
            init(keyManagers, null, SecureRandom())
        }
    }

    fun verifyTrustedToken(senderId: String, token: String?): Boolean {
        if (token.isNullOrBlank()) return false
        val expected = preferences.getString("$KEY_TRUSTED_PREFIX$senderId", null) ?: return false
        val actual = hashToken(token)
        return MessageDigest.isEqual(expected.toByteArray(Charsets.US_ASCII), actual.toByteArray(Charsets.US_ASCII))
    }

    fun rotateTrustedToken(senderId: String): String {
        val random = ByteArray(32).also(SecureRandom()::nextBytes)
        val token = Base64.encodeToString(random, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        preferences.edit().putString("$KEY_TRUSTED_PREFIX$senderId", hashToken(token)).apply()
        return token
    }

    private fun hashToken(token: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.US_ASCII))
        return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    }

    private fun ensureTlsKey() {
        if (keyStore.containsAlias(TLS_ALIAS)) return
        val now = Calendar.getInstance()
        val expiry = Calendar.getInstance().apply { add(Calendar.YEAR, 20) }
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, ANDROID_KEY_STORE)
        generator.initialize(
            KeyGenParameterSpec.Builder(
                TLS_ALIAS,
                KeyProperties.PURPOSE_SIGN or
                    KeyProperties.PURPOSE_VERIFY or
                    KeyProperties.PURPOSE_DECRYPT,
            )
                .setKeySize(2048)
                .setDigests(
                    KeyProperties.DIGEST_NONE,
                    KeyProperties.DIGEST_SHA256,
                    KeyProperties.DIGEST_SHA384,
                    KeyProperties.DIGEST_SHA512,
                )
                .setSignaturePaddings(
                    KeyProperties.SIGNATURE_PADDING_RSA_PKCS1,
                    KeyProperties.SIGNATURE_PADDING_RSA_PSS,
                )
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setCertificateSubject(X500Principal("CN=LAN Media Cast Receiver"))
                .setCertificateSerialNumber(BigInteger(128, SecureRandom()).abs())
                .setCertificateNotBefore(Date(now.timeInMillis - DAY_MILLIS))
                .setCertificateNotAfter(Date(expiry.timeInMillis))
                .build(),
        )
        generator.generateKeyPair()
    }

    private companion object {
        const val ANDROID_KEY_STORE = "AndroidKeyStore"
        const val TLS_ALIAS = "lan_media_cast_receiver_tls_v3"
        const val PREFERENCES = "receiver_identity"
        const val KEY_DEVICE_ID = "device_id"
        const val KEY_DEVICE_NAME = "device_name"
        const val KEY_TRUSTED_PREFIX = "trusted_hash_"
        const val LEGACY_DEFAULT_PREFIX = "Projector-"
        const val DAY_MILLIS = 24L * 60L * 60L * 1_000L
    }
}

internal fun resolveDeviceName(systemName: String?, manufacturer: String?, model: String?): String {
    val normalizedSystemName = systemName?.trim()?.takeUnless {
        it.isEmpty() || it.equals("null", ignoreCase = true)
    }
    if (normalizedSystemName != null) return normalizedSystemName.take(MAX_DEVICE_NAME_CHARS)

    val normalizedManufacturer = manufacturer?.trim().orEmpty()
    val normalizedModel = model?.trim().orEmpty()
    val fallback = when {
        normalizedManufacturer.isNotEmpty() &&
            normalizedModel.startsWith(normalizedManufacturer, ignoreCase = true) -> normalizedModel
        normalizedManufacturer.isNotEmpty() && normalizedModel.isNotEmpty() ->
            "$normalizedManufacturer $normalizedModel"
        normalizedModel.isNotEmpty() -> normalizedModel
        normalizedManufacturer.isNotEmpty() -> normalizedManufacturer
        else -> "Android 设备"
    }
    return fallback.take(MAX_DEVICE_NAME_CHARS)
}

private const val MAX_DEVICE_NAME_CHARS = 64
