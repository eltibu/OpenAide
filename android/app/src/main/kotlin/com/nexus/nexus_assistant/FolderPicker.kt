package com.nexus.nexus_assistant

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Upload Folder: Android's own folder picker, which can open any folder the
 * person chooses (Download, Documents, a USB stick or a cloud drive), not
 * just the ones an app may read by path. [pick] answers with the folder's
 * name and every file in it (hidden ones left out), [read] with one file.
 */
class FolderPicker(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val PICK_REQUEST = 4711
        private const val MAX_FILES = 5000
    }

    private var waiting: MethodChannel.Result? = null
    private val work = Executors.newSingleThreadExecutor()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> {
                waiting?.success(null)
                waiting = result
                activity.startActivityForResult(
                    Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
                    PICK_REQUEST,
                )
            }
            "read" -> {
                val uri = Uri.parse(call.argument<String>("uri"))
                work.execute {
                    try {
                        val bytes = activity.contentResolver.openInputStream(uri)
                            ?.use { it.readBytes() }
                        activity.runOnUiThread { result.success(bytes) }
                    } catch (e: Exception) {
                        activity.runOnUiThread {
                            result.error("read", e.message ?: e.javaClass.simpleName, null)
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun onPicked(resultCode: Int, data: Intent?) {
        val result = waiting ?: return
        waiting = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            result.success(null)
            return
        }
        work.execute {
            try {
                val root = DocumentsContract.getTreeDocumentId(tree)
                val name = nameOf(tree, root) ?: root.substringAfterLast(':').substringAfterLast('/')
                val files = ArrayList<Map<String, Any>>()
                walk(tree, root, "", files)
                activity.runOnUiThread {
                    result.success(mapOf("name" to name, "files" to files))
                }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    result.error("pick", e.message ?: e.javaClass.simpleName, null)
                }
            }
        }
    }

    private fun nameOf(tree: Uri, id: String): String? {
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        activity.contentResolver.query(
            uri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { if (it.moveToFirst()) return it.getString(0) }
        return null
    }

    private fun walk(tree: Uri, parent: String, path: String, out: MutableList<Map<String, Any>>) {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent)
        activity.contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
            ),
            null,
            null,
            null,
        )?.use { c ->
            while (c.moveToNext() && out.size < MAX_FILES) {
                val id = c.getString(0)
                val name = c.getString(1) ?: continue
                if (name.startsWith(".")) continue
                val rel = if (path.isEmpty()) name else "$path/$name"
                if (c.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walk(tree, id, rel, out)
                } else {
                    out.add(
                        mapOf(
                            "path" to rel,
                            "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                            "size" to (if (c.isNull(3)) 0L else c.getLong(3)),
                        ),
                    )
                }
            }
        }
    }
}
