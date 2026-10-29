package com.nexus.nexus_assistant

import android.app.ActivityManager
import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Models on the phone: downloads GGUF files (Android's download manager, so
 * a big download keeps going with the app closed), loads one with llama.cpp
 * (openaide_llm.cpp) and streams its replies to Dart.
 *
 * Replies stream on "nexus/local_llm/reply": listening with the chat as the
 * argument starts one; cancelling stops it.
 */
class LocalLlm(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    /** Feeds the reply to Dart as the model writes it. */
    fun interface Sink {
        fun onBytes(bytes: ByteArray)
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var loadedPath: String? = null
    private var loadedContext = 0
    @Volatile private var replyCancelled: AtomicBoolean? = null

    private val downloads =
        context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    private val modelsDir: File
        get() = File(context.getExternalFilesDir(null) ?: context.filesDir, "models")
            .apply { mkdirs() }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceInfo" -> result.success(deviceInfo())
            "modelsDir" -> result.success(modelsDir.absolutePath)
            "load" -> {
                val path = call.argument<String>("path")!!
                val ctx = call.argument<Int>("context") ?: 4096
                worker.execute {
                    val answer = load(path, ctx)
                    main.post { result.success(answer) }
                }
            }
            "unload" -> worker.execute {
                if (ready) nativeUnload()
                loadedPath = null
                main.post { result.success(null) }
            }
            // Straight away, not on the worker: the worker is busy replying.
            "stop" -> {
                replyCancelled?.set(true)
                if (ready) nativeStop()
                result.success(null)
            }
            "download" -> result.success(
                download(call.argument<String>("url")!!, call.argument<String>("file")!!,
                    call.argument<String>("title") ?: "Model"),
            )
            "downloads" -> result.success(
                downloadStatus(call.argument<List<Number>>("ids")!!.map { it.toLong() }),
            )
            "cancelDownload" -> {
                downloads.remove(call.argument<Number>("id")!!.toLong())
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun deviceInfo(): Map<String, Any> {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val stat = StatFs(modelsDir.absolutePath)
        return mapOf(
            "totalRam" to mem.totalMem,
            "availableRam" to mem.availMem,
            "freeStorage" to stat.availableBytes,
            "cores" to Runtime.getRuntime().availableProcessors(),
            "supported" to ready,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "loaded" to (loadedPath ?: ""),
        )
    }

    private fun load(path: String, ctx: Int): String {
        if (!ready) return """{"error":"Models on the phone need a 64-bit ARM phone."}"""
        if (path == loadedPath && ctx == loadedContext) return """{"already":true}"""
        loadedPath = null
        val answer = nativeLoad(path, ctx, threads())
        if (!JSONObject(answer).has("error")) {
            loadedPath = path
            loadedContext = ctx
        }
        return answer
    }

    /** The fast cores: phones pair a few big cores with slow small ones. */
    private fun threads(): Int {
        val cores = Runtime.getRuntime().availableProcessors()
        return if (cores >= 8) 4 else maxOf(2, cores / 2)
    }

    // Replies.

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val args = arguments as Map<*, *>
        val roles = (args["roles"] as List<*>).map { "$it" }.toTypedArray()
        val contents = (args["contents"] as List<*>).map { "$it".toByteArray() }.toTypedArray()
        val temp = (args["temperature"] as Number?)?.toFloat() ?: 0.7f
        val topP = (args["topP"] as Number?)?.toFloat() ?: 0.95f
        val maxTokens = (args["maxTokens"] as Number?)?.toInt() ?: 2048
        val think = args["think"] as Boolean? ?: true
        val path = args["path"] as String
        val ctx = (args["context"] as Number?)?.toInt() ?: 4096
        // The native stop flag is cleared when a reply starts, so a stop that
        // comes while the model loads would be lost: this one is kept.
        val cancelled = AtomicBoolean(false).also { replyCancelled = it }
        worker.execute {
            val loaded = load(path, ctx)
            if (JSONObject(loaded).has("error")) {
                main.post {
                    events.error("load", JSONObject(loaded).getString("error"), null)
                    events.endOfStream()
                }
                return@execute
            }
            if (cancelled.get()) {
                main.post { events.endOfStream() }
                return@execute
            }
            main.post { events.success(mapOf("loaded" to true)) }
            val stats = nativeGenerate(roles, contents, temp, topP, maxTokens, think) { bytes ->
                if (cancelled.get()) nativeStop()
                val text = String(bytes, Charsets.UTF_8)
                main.post { events.success(mapOf("text" to text)) }
            }
            main.post {
                val json = JSONObject(stats)
                if (json.has("error")) {
                    events.error("reply", json.getString("error"), null)
                } else {
                    events.success(mapOf("done" to stats))
                }
                events.endOfStream()
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        replyCancelled?.set(true)
        if (ready) nativeStop()
    }

    // Downloads.

    private fun download(url: String, file: String, title: String): Long {
        // A failed try may have left part of the file behind.
        File(modelsDir, "$file.part").delete()
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(title)
            .setDescription("Model for OpenAide")
            .setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
            )
            .setAllowedOverMetered(true)
            .setDestinationUri(Uri.fromFile(File(modelsDir, "$file.part")))
        return downloads.enqueue(request)
    }

    /** Each download's state. A finished one is renamed to its real name. */
    private fun downloadStatus(ids: List<Long>): List<Map<String, Any?>> {
        if (ids.isEmpty()) return emptyList()
        val out = mutableListOf<Map<String, Any?>>()
        val found = mutableSetOf<Long>()
        downloads.query(DownloadManager.Query().setFilterById(*ids.toLongArray())).use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_ID))
                found += id
                val status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                val done = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                val total = c.getLong(c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                val reason = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                val local = c.getString(c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))
                var state = when (status) {
                    DownloadManager.STATUS_SUCCESSFUL -> "done"
                    DownloadManager.STATUS_FAILED -> "failed"
                    DownloadManager.STATUS_PAUSED -> "paused"
                    DownloadManager.STATUS_PENDING -> "waiting"
                    else -> "running"
                }
                if (state == "done" && local != null) {
                    val part = File(Uri.parse(local).path ?: "")
                    val final = File(part.parentFile, part.name.removeSuffix(".part"))
                    if (part.exists() && part.name.endsWith(".part") && !part.renameTo(final)) {
                        state = "failed"
                    } else {
                        // Forget it in the download manager; the file stays,
                        // since it's no longer where the manager put it.
                        downloads.remove(id)
                    }
                }
                out += mapOf(
                    "id" to id,
                    "state" to state,
                    "done" to done,
                    "total" to total,
                    "reason" to if (state == "failed" || state == "paused") reasonText(reason) else null,
                )
            }
        }
        for (id in ids) if (id !in found) out += mapOf("id" to id, "state" to "gone")
        return out
    }

    private fun reasonText(reason: Int): String = when (reason) {
        DownloadManager.PAUSED_WAITING_FOR_NETWORK -> "Waiting for internet"
        DownloadManager.PAUSED_WAITING_TO_RETRY -> "Retrying soon"
        DownloadManager.PAUSED_QUEUED_FOR_WIFI -> "Waiting for Wi-Fi"
        DownloadManager.ERROR_INSUFFICIENT_SPACE -> "Not enough storage"
        DownloadManager.ERROR_CANNOT_RESUME -> "Couldn't resume"
        401, 403 -> "This model needs a Hugging Face sign-in (gated)"
        404 -> "File not found"
        else -> if (reason in 400..599) "The server answered $reason" else "Download failed"
    }

    private external fun nativeInit(libDir: String)
    private external fun nativeLoad(path: String, ctx: Int, threads: Int): String
    private external fun nativeUnload()
    private external fun nativeStop()
    private external fun nativeGenerate(
        roles: Array<String>,
        contents: Array<ByteArray>,
        temp: Float,
        topP: Float,
        maxTokens: Int,
        think: Boolean,
        sink: Sink,
    ): String

    /** Whether llama.cpp loaded: it's built for 64-bit ARM only. */
    private val ready: Boolean by lazy {
        try {
            System.loadLibrary("openaide_llm")
            nativeInit(context.applicationInfo.nativeLibraryDir)
            true
        } catch (e: Throwable) {
            android.util.Log.w("OpenAideLlm", "not available: $e")
            false
        }
    }
}
