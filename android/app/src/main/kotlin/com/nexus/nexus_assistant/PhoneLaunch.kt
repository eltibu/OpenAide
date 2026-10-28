package com.nexus.nexus_assistant

import android.app.Activity
import android.app.KeyguardManager
import android.app.StatusBarManager
import android.app.role.RoleManager
import android.content.ComponentName
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Ways the phone opens Nexus besides its icon: as the phone's assistant
 * (long-press power or home, or a headset button), Share from another app,
 * "Ask Nexus" on selected text, the app's shortcuts and its quick settings
 * tile. Each becomes a map Dart acts on ("launch", or "initial" after a cold
 * start). Also the app lock: the phone's own fingerprint or screen lock.
 */
class PhoneLaunch(private val activity: Activity) : MethodChannel.MethodCallHandler {
    var channel: MethodChannel? = null
    private var initial: Map<String, Any?>? = null
    private var unlockResult: MethodChannel.Result? = null

    companion object {
        const val EXTRA = "nexus.launch"
        const val UNLOCK_REQUEST = 4713
        private const val MAX_FILES = 10
    }

    /** What [intent] asks for, or null for a plain launch. */
    private fun parse(intent: Intent): Map<String, Any?>? {
        intent.getStringExtra(EXTRA)?.let {
            intent.removeExtra(EXTRA)
            return mapOf("kind" to it)
        }
        return when (intent.action) {
            Intent.ACTION_ASSIST, Intent.ACTION_VOICE_COMMAND,
            "android.intent.action.SEARCH_LONG_PRESS",
            -> mapOf("kind" to "assist")
            Intent.ACTION_PROCESS_TEXT -> mapOf(
                "kind" to "share",
                "text" to intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString(),
            )
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> share(intent)
            else -> null
        }.also {
            // Handled once, not again when the activity is recreated.
            if (it != null) intent.action = Intent.ACTION_MAIN
        }
    }

    private fun share(intent: Intent): Map<String, Any?> {
        val uris = mutableListOf<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        } else {
            @Suppress("DEPRECATION")
            (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
        }
        val dir = File(activity.cacheDir, "shared").apply {
            deleteRecursively()
            mkdirs()
        }
        val files = mutableListOf<String>()
        for ((i, uri) in uris.take(MAX_FILES).withIndex()) {
            try {
                val name = displayName(uri) ?: "shared-$i"
                val out = File(File(dir, "$i").apply { mkdirs() }, name.replace('/', '_'))
                activity.contentResolver.openInputStream(uri)?.use { input ->
                    out.outputStream().use { input.copyTo(it) }
                }
                files.add(out.absolutePath)
            } catch (_: Exception) {
                // Skipped: the other app didn't let us read it.
            }
        }
        val text = listOfNotNull(
            intent.getStringExtra(Intent.EXTRA_SUBJECT),
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString(),
        ).filter { it.isNotBlank() }.distinct().joinToString("\n\n")
        return mapOf("kind" to "share", "text" to text, "files" to files)
    }

    private fun displayName(uri: Uri): String? {
        val name = try {
            activity.contentResolver
                .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { if (it.moveToFirst()) it.getString(0) else null }
        } catch (_: Exception) {
            null
        }
        return name ?: uri.lastPathSegment
    }

    /** A cold start: kept until Dart asks. */
    fun rememberInitial(intent: Intent?) {
        initial = parse(intent ?: return) ?: initial
    }

    fun handleIntent(intent: Intent?) {
        val launch = parse(intent ?: return) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("launch", launch) else initial = launch
    }

    fun onUnlockResult(ok: Boolean) {
        unlockResult?.success(ok)
        unlockResult = null
    }

    private val keyguard get() = activity.getSystemService(KeyguardManager::class.java)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initial" -> {
                result.success(initial)
                initial = null
            }
            "isAssistant" -> result.success(
                if (Build.VERSION.SDK_INT >= 29) {
                    activity.getSystemService(RoleManager::class.java)
                        ?.isRoleHeld(RoleManager.ROLE_ASSISTANT) == true
                } else {
                    null
                },
            )
            "openAssistantSettings" -> {
                val tries = listOf(
                    Intent(Settings.ACTION_VOICE_INPUT_SETTINGS),
                    Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS),
                    Intent(Settings.ACTION_SETTINGS),
                )
                result.success(
                    tries.any {
                        try {
                            activity.startActivity(it)
                            true
                        } catch (_: Exception) {
                            false
                        }
                    },
                )
            }
            "canAddTile" -> result.success(Build.VERSION.SDK_INT >= 33)
            "addTile" -> if (Build.VERSION.SDK_INT >= 33) {
                activity.getSystemService(StatusBarManager::class.java).requestAddTileService(
                    ComponentName(activity, NexusTileService::class.java),
                    "Nexus",
                    Icon.createWithResource(activity, R.drawable.ic_tile),
                    activity.mainExecutor,
                ) { code -> result.success("$code") }
            } else {
                result.success("unsupported")
            }
            "canLock" -> result.success(keyguard?.isDeviceSecure == true)
            "unlock" -> {
                @Suppress("DEPRECATION")
                val ask = keyguard?.createConfirmDeviceCredentialIntent(
                    "Unlock Nexus",
                    call.argument<String>("reason"),
                )
                if (ask == null) {
                    // No screen lock set: nothing to check against.
                    result.success(true)
                    return
                }
                unlockResult?.success(false)
                unlockResult = result
                @Suppress("DEPRECATION")
                activity.startActivityForResult(ask, UNLOCK_REQUEST)
            }
            else -> result.notImplemented()
        }
    }
}
