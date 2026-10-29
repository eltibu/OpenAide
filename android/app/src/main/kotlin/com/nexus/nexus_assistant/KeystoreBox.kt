package com.nexus.nexus_assistant

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Seals the sign-in the closed-app check keeps (see [BackgroundCheck]) with
 * a key that never leaves the phone's Keystore, so the app's preference
 * file holds no readable token or cookie.
 */
object KeystoreBox {
    private const val ALIAS = "openaide_background"
    private const val PREFIX = "v1:"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    private fun b64(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)

    /** Sealed text; on a phone whose Keystore fails, the text as it is. */
    fun seal(text: String): String {
        if (text.isEmpty()) return ""
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, key())
            PREFIX + b64(cipher.iv) + ":" + b64(cipher.doFinal(text.toByteArray()))
        } catch (_: Exception) {
            text
        }
    }

    /** The text again; a value saved before sealing comes back as it is. */
    fun open(stored: String): String? {
        if (!stored.startsWith(PREFIX)) return stored
        return try {
            val (iv, data) = stored.removePrefix(PREFIX).split(":", limit = 2)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                key(),
                GCMParameterSpec(128, Base64.decode(iv, Base64.NO_WRAP)),
            )
            String(cipher.doFinal(Base64.decode(data, Base64.NO_WRAP)))
        } catch (_: Exception) {
            null
        }
    }
}
