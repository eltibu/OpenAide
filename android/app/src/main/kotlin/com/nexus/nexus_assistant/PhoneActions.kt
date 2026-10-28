package com.nexus.nexus_assistant

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.net.Uri
import android.provider.AlarmClock
import android.provider.ContactsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * What Nexus can do on the phone itself when you ask it to: timers, alarms,
 * calling and texting (the phone's own apps open, ready, and you press
 * send or call), opening an app, directions and the flashlight. Each answers
 * "done", or why not.
 */
class PhoneActions(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private var contactsResult: (() -> Unit)? = null
    private var torch = false

    companion object {
        const val CONTACTS_REQUEST = 4714
    }

    fun onContactsPermission() {
        contactsResult?.invoke()
        contactsResult = null
    }

    private fun start(intent: Intent): String = try {
        activity.startActivity(intent)
        "done"
    } catch (e: Exception) {
        "No app on this phone can do that."
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "timer" -> result.success(
                start(
                    Intent(AlarmClock.ACTION_SET_TIMER)
                        .putExtra(AlarmClock.EXTRA_LENGTH, call.argument<Int>("seconds") ?: 60)
                        .putExtra(AlarmClock.EXTRA_MESSAGE, call.argument<String>("label") ?: "Nexus")
                        .putExtra(AlarmClock.EXTRA_SKIP_UI, true),
                ),
            )
            "alarm" -> result.success(
                start(
                    Intent(AlarmClock.ACTION_SET_ALARM)
                        .putExtra(AlarmClock.EXTRA_HOUR, call.argument<Int>("hour") ?: 7)
                        .putExtra(AlarmClock.EXTRA_MINUTES, call.argument<Int>("minute") ?: 0)
                        .putExtra(AlarmClock.EXTRA_MESSAGE, call.argument<String>("label") ?: "Nexus")
                        .putExtra(AlarmClock.EXTRA_SKIP_UI, true),
                ),
            )
            "dial" -> result.success(
                start(Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(call.argument<String>("number") ?: "")))),
            )
            "sms" -> result.success(
                start(
                    Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + Uri.encode(call.argument<String>("number") ?: "")))
                        .putExtra("sms_body", call.argument<String>("body") ?: ""),
                ),
            )
            "contacts" -> {
                val name = call.argument<String>("name") ?: ""
                if (activity.checkSelfPermission(Manifest.permission.READ_CONTACTS) ==
                    PackageManager.PERMISSION_GRANTED
                ) {
                    result.success(contacts(name))
                } else {
                    contactsResult = {
                        result.success(
                            if (activity.checkSelfPermission(Manifest.permission.READ_CONTACTS) ==
                                PackageManager.PERMISSION_GRANTED
                            ) contacts(name) else null,
                        )
                    }
                    activity.requestPermissions(arrayOf(Manifest.permission.READ_CONTACTS), CONTACTS_REQUEST)
                }
            }
            "openApp" -> result.success(openApp(call.argument<String>("name") ?: ""))
            "navigate" -> {
                val place = Uri.encode(call.argument<String>("place") ?: "")
                val maps = Intent(Intent.ACTION_VIEW, Uri.parse("google.navigation:q=$place"))
                result.success(
                    if (maps.resolveActivity(activity.packageManager) != null) start(maps)
                    else start(Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=$place"))),
                )
            }
            "torch" -> result.success(setTorch(call.argument<Boolean>("on")))
            else -> result.notImplemented()
        }
    }

    /** People whose name has [name] in it, with a number: [{name, number}]. */
    private fun contacts(name: String): List<Map<String, String>> {
        val out = mutableListOf<Map<String, String>>()
        val seen = mutableSetOf<String>()
        activity.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            ),
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?",
            arrayOf("%$name%"),
            "${ContactsContract.CommonDataKinds.Phone.IS_SUPER_PRIMARY} DESC",
        )?.use { c ->
            while (c.moveToNext() && out.size < 10) {
                val who = c.getString(0) ?: continue
                val number = c.getString(1) ?: continue
                if (seen.add(who + number.filter { it.isDigit() })) {
                    out.add(mapOf("name" to who, "number" to number))
                }
            }
        }
        return out
    }

    private fun openApp(name: String): String {
        val pm = activity.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val wanted = name.trim().lowercase()
        val apps = pm.queryIntentActivities(launcher, 0)
            .map { it to it.loadLabel(pm).toString() }
        val match = apps.firstOrNull { it.second.lowercase() == wanted }
            ?: apps.firstOrNull { it.second.lowercase().startsWith(wanted) }
            ?: apps.firstOrNull { it.second.lowercase().contains(wanted) }
            ?: return "No app called $name on this phone."
        val info = match.first.activityInfo
        return start(
            Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
                .setClassName(info.packageName, info.name)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    private fun setTorch(on: Boolean?): String {
        val cameras = activity.getSystemService(CameraManager::class.java)
            ?: return "This phone has no flashlight."
        val id = cameras.cameraIdList.firstOrNull {
            cameras.getCameraCharacteristics(it)
                .get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
        } ?: return "This phone has no flashlight."
        return try {
            torch = on ?: !torch
            cameras.setTorchMode(id, torch)
            if (torch) "on" else "off"
        } catch (e: Exception) {
            "The flashlight is busy."
        }
    }
}
