package com.nexus.nexus_assistant

import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode

/**
 * The assistant as a panel over the app you're in, as the phone's own
 * assistant shows: Dart's assistMain() draws it on a see-through window.
 * Everything the full app can reach (microphone, notifications, phone
 * actions) is here too, since it's the same activity underneath.
 */
class AssistActivity : MainActivity() {
    override fun getDartEntrypointFunctionName(): String = "assistMain"

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent
}
