package com.nexus.nexus_assistant

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt

/**
 * Microphone and speaker for voice calls, the Android side of Open WebUI's
 * `realtime-audio` worklet: 24 kHz mono PCM16 both ways, the mic in 40 ms
 * frames, replies queued and played as they stream in, and on an
 * interruption the queue is dropped and how much of each item was heard is
 * reported, so the server can cut its transcript there.
 *
 * Uses the phone's call audio path, so Android cancels the echo of the
 * speaker in the microphone.
 */
class VoiceAudio(private val activity: Activity) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val PERMISSION_REQUEST = 4711
        private const val RATE = 24000
        private const val FRAME = 960 // samples per mic frame (40 ms)
        private const val SLICE = 480 // samples per playback write (20 ms)
        private const val START_AFTER = 1920 // samples queued before playing (80 ms)
    }

    private class Chunk(
        val samples: ShortArray,
        val responseId: String,
        val itemId: String,
        val contentIndex: Int,
    ) {
        var offset = 0
    }

    private val main = Handler(Looper.getMainLooper())
    private val audioManager =
        activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var sink: EventChannel.EventSink? = null
    private var pendingStart: MethodChannel.Result? = null

    private var recorder: AudioRecord? = null
    private var track: AudioTrack? = null
    private var echo: AcousticEchoCanceler? = null
    private var noise: NoiseSuppressor? = null
    private var captureThread: Thread? = null
    private var playThread: Thread? = null
    private var previousMode = AudioManager.MODE_NORMAL
    private var modeChanged = false

    /** Recording only (notes, dictation): no speaker, no call mode, and the
     *  microphone tuned for speech recognition rather than for a call. */
    private var recordOnly = false
    @Volatile private var running = false
    @Volatile private var capturing = false
    @Volatile private var flushTrack = false

    // Guarded by [lock]: what the play thread reads.
    private val lock = Object()
    private val queue = ArrayDeque<Chunk>()
    private var queued = 0
    private var received = 0L
    private var playing = false
    private var paused = false
    private val rendered = LinkedHashMap<String, MutableMap<String, Any>>()
    private val ended = HashSet<String>()
    private var clearId = 0
    private var inputEnergy = 0.0
    private var inputSamples = 0

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun emit(event: Map<String, Any?>) = main.post { sink?.success(event) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                if (!running) recordOnly = call.argument<Boolean>("record") == true
                val granted = ContextCompat.checkSelfPermission(
                    activity, Manifest.permission.RECORD_AUDIO,
                ) == PackageManager.PERMISSION_GRANTED
                if (granted) {
                    result.success(startOrError())
                } else {
                    pendingStart?.success("denied")
                    pendingStart = result
                    ActivityCompat.requestPermissions(
                        activity, arrayOf(Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST,
                    )
                }
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            "capture" -> {
                capturing = call.argument<Boolean>("enabled") == true
                result.success(null)
            }
            "pause" -> {
                synchronized(lock) { paused = call.argument<Boolean>("paused") == true }
                result.success(null)
            }
            "audio" -> {
                val bytes = call.argument<ByteArray>("pcm")!!
                val samples = ShortArray(bytes.size / 2)
                ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)
                synchronized(lock) {
                    received += samples.size
                    queued += samples.size
                    queue.addLast(
                        Chunk(
                            samples,
                            call.argument<String>("response_id")!!,
                            call.argument<String>("item_id")!!,
                            call.argument<Int>("content_index") ?: 0,
                        ),
                    )
                }
                result.success(null)
            }
            "done" -> {
                synchronized(lock) { ended.add(call.argument<String>("response_id")!!) }
                result.success(null)
            }
            "clear" -> {
                val id = call.argument<Int>("id") ?: 0
                val heard: List<Map<String, Any>>
                synchronized(lock) {
                    clearId = id
                    heard = rendered.values.map { HashMap(it) }
                    queue.clear()
                    queued = 0
                    playing = false
                    rendered.clear()
                    ended.clear()
                }
                flushTrack = true
                result.success(
                    mapOf(
                        "id" to id,
                        "rendered" to heard,
                        // Written but still in the speaker's buffer, so not yet heard.
                        "latency_ms" to latencyMs(),
                    ),
                )
            }
            else -> result.notImplemented()
        }
    }

    /** From MainActivity.onRequestPermissionsResult. */
    fun onPermission(granted: Boolean) {
        val result = pendingStart ?: return
        pendingStart = null
        result.success(if (granted) startOrError() else "denied")
    }

    private fun latencyMs(): Int {
        val t = track ?: return 0
        return t.bufferSizeInFrames * 1000 / RATE
    }

    private fun startOrError(): String = try {
        start()
        // Keeps listening with the screen locked or another app in front.
        MicService.onButton = { emit(mapOf("type" to "button")) }
        MicService.start(activity, !recordOnly)
        "started"
    } catch (e: Exception) {
        stop()
        e.message ?: e.javaClass.simpleName
    }

    @Suppress("DEPRECATION")
    private fun start() {
        if (running) return
        synchronized(lock) {
            queue.clear(); queued = 0; received = 0; playing = false; paused = false
            rendered.clear(); ended.clear(); clearId = 0
        }
        if (!recordOnly) {
            previousMode = audioManager.mode
            audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
            modeChanged = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audioManager.availableCommunicationDevices
                    .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                    ?.let { audioManager.setCommunicationDevice(it) }
            } else {
                audioManager.isSpeakerphoneOn = true
            }
        }

        val recordMin = AudioRecord.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        val rec = AudioRecord(
            if (recordOnly) MediaRecorder.AudioSource.VOICE_RECOGNITION
            else MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            maxOf(recordMin, FRAME * 2 * 4),
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("The microphone could not be opened.")
        }
        recorder = rec
        if (recordOnly) {
            running = true
            rec.startRecording()
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            captureThread = Thread(::captureLoop, "voice-capture").apply { start() }
            return
        }
        if (AcousticEchoCanceler.isAvailable()) {
            echo = AcousticEchoCanceler.create(rec.audioSessionId)?.apply { enabled = true }
        }
        if (NoiseSuppressor.isAvailable()) {
            noise = NoiseSuppressor.create(rec.audioSessionId)?.apply { enabled = true }
        }

        val playMin = AudioTrack.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        val out = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(RATE)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(maxOf(playMin, SLICE * 2 * 4))
            .build()
        track = out

        running = true
        rec.startRecording()
        out.play()
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        captureThread = Thread(::captureLoop, "voice-capture").apply { start() }
        playThread = Thread(::playLoop, "voice-play").apply { start() }
    }

    private fun captureLoop() {
        val frame = ShortArray(FRAME)
        val rec = recorder ?: return
        while (running) {
            var filled = 0
            while (filled < FRAME && running) {
                val n = rec.read(frame, filled, FRAME - filled)
                if (n < 0) {
                    emit(mapOf("type" to "error", "message" to "The microphone stopped ($n)."))
                    return
                }
                filled += n
            }
            if (!running) return
            if (!capturing) continue
            var energy = 0.0
            val bytes = ByteBuffer.allocate(FRAME * 2).order(ByteOrder.LITTLE_ENDIAN)
            for (s in frame) {
                bytes.putShort(s)
                val v = s / 32768.0
                energy += v * v
            }
            synchronized(lock) {
                inputEnergy += energy
                inputSamples += FRAME
            }
            emit(mapOf("type" to "input", "pcm" to bytes.array()))
        }
    }

    private fun playLoop() {
        val slice = ShortArray(SLICE)
        var ticks = 0
        var outputEnergy = 0.0
        var levelSamples = 0
        var playbackSamples = 0
        val out = track ?: return
        while (running) {
            if (flushTrack) {
                flushTrack = false
                out.pause()
                out.flush()
                out.play()
                outputEnergy = 0.0
                playbackSamples = 0
            }
            slice.fill(0)
            synchronized(lock) {
                if (!playing &&
                    (queued >= START_AFTER || (queue.isNotEmpty() && queue.first().responseId in ended))
                ) {
                    playing = true
                }
                if (playing && !paused) {
                    var offset = 0
                    while (offset < SLICE && queue.isNotEmpty()) {
                        val chunk = queue.first()
                        val count = minOf(SLICE - offset, chunk.samples.size - chunk.offset)
                        System.arraycopy(chunk.samples, chunk.offset, slice, offset, count)
                        offset += count
                        chunk.offset += count
                        queued -= count
                        playbackSamples += count
                        val key = "${chunk.itemId}:${chunk.contentIndex}"
                        val position = rendered.getOrPut(key) {
                            mutableMapOf(
                                "response_id" to chunk.responseId,
                                "item_id" to chunk.itemId,
                                "content_index" to chunk.contentIndex,
                                "samples" to 0,
                            )
                        }
                        position["samples"] = (position["samples"] as Int) + count
                        if (chunk.offset == chunk.samples.size) queue.removeFirst()
                    }
                    if (queued == 0) playing = false
                }
            }
            for (s in slice) {
                val v = s / 32768.0
                outputEnergy += v * v
            }
            levelSamples += SLICE
            // Blocks until there is room, which paces this loop in real time.
            out.write(slice, 0, SLICE)
            if (++ticks % 4 == 0) {
                val event: Map<String, Any?>
                synchronized(lock) {
                    val inputLevel =
                        if (inputSamples > 0) sqrt(inputEnergy / inputSamples) else 0.0
                    event = mapOf(
                        "type" to "playback",
                        "clearId" to clearId,
                        "playbackActive" to (playbackSamples > 0),
                        "queued" to queued,
                        "received" to received,
                        "inputLevel" to inputLevel,
                        "outputLevel" to sqrt(outputEnergy / levelSamples),
                    )
                    inputEnergy = 0.0
                    inputSamples = 0
                }
                emit(event)
                outputEnergy = 0.0
                levelSamples = 0
                playbackSamples = 0
            }
        }
    }

    @Suppress("DEPRECATION")
    fun stop() {
        val wasRunning = running
        if (wasRunning) {
            MicService.onButton = null
            MicService.stop(activity)
        }
        running = false
        capturing = false
        captureThread?.join(500)
        playThread?.join(500)
        captureThread = null
        playThread = null
        try { recorder?.stop() } catch (e: Exception) {}
        recorder?.release()
        recorder = null
        try { track?.stop() } catch (e: Exception) {}
        track?.release()
        track = null
        echo?.release()
        echo = null
        noise?.release()
        noise = null
        if (wasRunning && modeChanged) {
            modeChanged = false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                audioManager.clearCommunicationDevice()
            } else {
                audioManager.isSpeakerphoneOn = false
            }
            audioManager.mode = previousMode
        }
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
}
