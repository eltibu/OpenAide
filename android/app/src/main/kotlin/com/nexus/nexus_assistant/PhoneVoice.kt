package com.nexus.nexus_assistant

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.UUID

/**
 * The phone's own voices (Android text to speech), for servers whose
 * Text-to-Speech engine is the browser's: the web then speaks with the
 * browser's voices, the app with the phone's. [voices] lists them (and
 * which need the internet), [speak] says one piece and answers when it is
 * done, [stop] stops.
 */
class PhoneVoice(private val context: Context) : MethodChannel.MethodCallHandler {
    private var tts: TextToSpeech? = null
    private var ready = false
    private val waiting = ArrayList<() -> Unit>()
    private val pending = HashMap<String, MethodChannel.Result>()

    private fun withTts(then: () -> Unit, failed: (String) -> Unit) {
        if (ready) return then()
        waiting.add(then)
        if (tts != null) return
        tts = TextToSpeech(context) { status ->
            if (status == TextToSpeech.SUCCESS) {
                ready = true
                tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(id: String?) {}
                    override fun onDone(id: String?) = finish(id, null)
                    @Deprecated("Deprecated in Java")
                    override fun onError(id: String?) = finish(id, "error")
                    override fun onError(id: String?, code: Int) = finish(id, "error $code")
                    override fun onStop(id: String?, interrupted: Boolean) = finish(id, null)
                })
                val run = ArrayList(waiting)
                waiting.clear()
                run.forEach { it() }
            } else {
                waiting.clear()
                tts = null
                failed("This phone has no text to speech.")
            }
        }
    }

    private fun finish(id: String?, error: String?) {
        val result = synchronized(pending) { pending.remove(id) } ?: return
        android.os.Handler(context.mainLooper).post {
            if (error == null) result.success(null) else result.error("speak", error, null)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "voices" -> withTts({
                val list = (tts?.voices ?: emptySet()).map {
                    mapOf(
                        "name" to it.name,
                        "locale" to it.locale.toLanguageTag(),
                        "network" to it.isNetworkConnectionRequired,
                    )
                }.sortedBy { "${it["locale"]} ${it["name"]}" }
                result.success(list)
            }) { result.error("voices", it, null) }
            "speak" -> withTts({
                val engine = tts!!
                val name = call.argument<String>("voice")
                val voice = engine.voices?.firstOrNull { it.name == name }
                if (voice != null) {
                    engine.voice = voice
                } else {
                    engine.language = Locale.getDefault()
                }
                engine.setSpeechRate((call.argument<Double>("rate") ?: 1.0).toFloat())
                val id = UUID.randomUUID().toString()
                synchronized(pending) { pending[id] = result }
                val ok = engine.speak(
                    call.argument<String>("text") ?: "",
                    TextToSpeech.QUEUE_ADD,
                    Bundle(),
                    id,
                )
                if (ok != TextToSpeech.SUCCESS) finish(id, "Couldn't speak")
            }) { result.error("speak", it, null) }
            "stop" -> {
                tts?.stop()
                val all = synchronized(pending) { pending.keys.toList() }
                all.forEach { finish(it, null) }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun close() {
        tts?.shutdown()
        tts = null
        ready = false
    }
}
