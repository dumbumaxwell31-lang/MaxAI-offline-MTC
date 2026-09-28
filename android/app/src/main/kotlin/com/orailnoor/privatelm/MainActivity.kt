package com.orailnoor.privatelm

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val downloadChannelName = "com.maxai/model_download"
    private val mainHandler = Handler(Looper.getMainLooper())
    private val monitoredDownloads = ConcurrentHashMap.newKeySet<Long>()
    private var downloadChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        downloadChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            downloadChannelName,
        )
        downloadChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "downloadModelInApp" -> startModelDownload(call, result)
                "cancelDownloadInApp" -> cancelModelDownload(call, result)
                "getActiveDownloads" -> queryActiveDownloads(result)
                "getAvailableStorageBytes" -> queryAvailableStorage(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun startModelDownload(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val filename = call.argument<String>("filename")
        val modelsDir = call.argument<String>("modelsDir")
        val expectedBytes = (call.argument<Any>("expectedBytes") as? Number)?.toLong() ?: 0L
        if (url.isNullOrBlank() || filename.isNullOrBlank() || modelsDir.isNullOrBlank()) {
            result.error("INVALID_DOWNLOAD", "Model download details are incomplete.", null)
            return
        }

        try {
            val safeName = sanitizeFilename(filename)
            val downloadId = existingDownloadFor(safeName) ?: enqueueModelDownload(
                url = url,
                filename = safeName,
                modelsDir = modelsDir,
                expectedBytes = expectedBytes,
            )
            result.success(mapOf("downloadId" to downloadId, "filename" to safeName))
        } catch (error: Exception) {
            result.error("DOWNLOAD_FAILED", error.message ?: error.toString(), null)
        }
    }

    private fun cancelModelDownload(call: MethodCall, result: MethodChannel.Result) {
        val downloadId = (call.argument<Any>("downloadId") as? Number)?.toLong()
        if (downloadId == null) {
            result.error("INVALID_DOWNLOAD_ID", "Download ID is missing.", null)
            return
        }

        try {
            val filename = call.argument<String>("filename")
            val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            manager.remove(downloadId)
            removeDownload(downloadId)
            if (!filename.isNullOrBlank()) {
                temporaryDownloadFile(sanitizeFilename(filename)).delete()
            }
            emitProgress(filename ?: "model.gguf", 0, 0, "Download cancelled")
            result.success(true)
        } catch (error: Exception) {
            result.error("CANCEL_FAILED", error.message ?: error.toString(), null)
        }
    }

    private fun queryActiveDownloads(result: MethodChannel.Result) {
        thread(name = "maxai-download-reconcile") {
            try {
                val active = reconcileDownloads()
                mainHandler.post { result.success(active) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("QUERY_FAILED", error.message ?: error.toString(), null)
                }
            }
        }
    }

    private fun queryAvailableStorage(call: MethodCall, result: MethodChannel.Result) {
        val modelsDir = call.argument<String>("modelsDir")
        if (modelsDir.isNullOrBlank()) {
            result.error("INVALID_DIR", "Models directory is missing.", null)
            return
        }
        try {
            result.success(StatFs(modelsDir).availableBytes)
        } catch (error: Exception) {
            result.error("STORAGE_QUERY_FAILED", error.message ?: error.toString(), null)
        }
    }

    private fun enqueueModelDownload(
        url: String,
        filename: String,
        modelsDir: String,
        expectedBytes: Long,
    ): Long {
        val temporaryFile = temporaryDownloadFile(filename)
        temporaryFile.parentFile?.mkdirs()
        if (temporaryFile.exists()) temporaryFile.delete()

        val request = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle(filename)
            setDescription("Downloading local AI model")
            setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
            setAllowedOverMetered(true)
            setAllowedOverRoaming(true)
            setDestinationUri(Uri.fromFile(temporaryFile))
            addRequestHeader("Accept", "*/*")
        }
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val downloadId = manager.enqueue(request)
        persistDownload(downloadId, filename, modelsDir, expectedBytes)
        monitorDownload(downloadId, filename, modelsDir, expectedBytes)
        return downloadId
    }

    private fun monitorDownload(
        downloadId: Long,
        filename: String,
        modelsDir: String,
        expectedBytes: Long,
    ) {
        if (!monitoredDownloads.add(downloadId)) return
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        thread(name = "maxai-download-$downloadId") {
            var finished = false
            while (!finished) {
                Thread.sleep(1000)
                manager.query(DownloadManager.Query().setFilterById(downloadId))?.use { cursor ->
                    if (!cursor.moveToFirst()) {
                        finished = true
                        removeDownload(downloadId)
                        emitProgress(filename, 0, 0, "Download cancelled")
                        return@use
                    }

                    val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                    val downloaded = cursor.getLong(
                        cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
                    )
                    val total = cursor.getLong(
                        cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
                    )
                    when (status) {
                        DownloadManager.STATUS_SUCCESSFUL -> {
                            finished = true
                            finalizeDownload(downloadId, filename, modelsDir, downloaded, total, expectedBytes)
                        }
                        DownloadManager.STATUS_FAILED -> {
                            finished = true
                            removeDownload(downloadId)
                            emitProgress(filename, downloaded, total, "Download failed")
                        }
                        DownloadManager.STATUS_PAUSED ->
                            emitProgress(filename, downloaded, total, "Paused")
                        else -> emitProgress(filename, downloaded, total, "Downloading")
                    }
                } ?: run {
                    finished = true
                    removeDownload(downloadId)
                }
            }
            monitoredDownloads.remove(downloadId)
        }
    }

    private fun finalizeDownload(
        downloadId: Long,
        filename: String,
        modelsDir: String,
        downloaded: Long,
        total: Long,
        expectedBytes: Long,
    ) {
        val target = File(modelsDir, filename)
        val part = File(target.parentFile, "${target.name}.part")
        val backup = File(target.parentFile, "${target.name}.previous")
        try {
            val source = temporaryDownloadFile(filename)
            if (!source.exists()) throw IllegalStateException("Downloaded temporary file is missing.")
            if (expectedBytes > 0 && source.length() < expectedBytes * 0.85) {
                throw IllegalStateException("Downloaded model file is incomplete.")
            }

            target.parentFile?.mkdirs()
            if (part.exists()) part.delete()
            if (backup.exists()) backup.delete()

            source.inputStream().use { input ->
                part.outputStream().use { output -> input.copyTo(output, 1024 * 1024) }
            }
            if (expectedBytes > 0 && part.length() < expectedBytes * 0.85) {
                throw IllegalStateException("Temporary model file failed validation.")
            }

            if (target.exists() && !target.renameTo(backup)) {
                throw IllegalStateException("Unable to preserve the existing model file.")
            }
            if (!part.renameTo(target)) {
                if (backup.exists()) backup.renameTo(target)
                throw IllegalStateException("Unable to finalize downloaded model.")
            }
            if (backup.exists()) backup.delete()
            source.delete()
            removeDownload(downloadId)
            emitProgress(filename, downloaded, total, "Download complete")
        } catch (error: Exception) {
            if (!target.exists() && backup.exists()) backup.renameTo(target)
            if (part.exists()) part.delete()
            removeDownload(downloadId)
            emitProgress(filename, downloaded, total, "Download failed")
        }
    }

    private fun reconcileDownloads(): List<Map<String, Any>> {
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val active = mutableListOf<Map<String, Any>>()
        for ((idText, rawRecord) in downloadPreferences().all) {
            val downloadId = idText.toLongOrNull() ?: continue
            val record = runCatching { JSONObject(rawRecord as String) }.getOrNull() ?: continue
            val filename = record.optString("filename")
            val modelsDir = record.optString("modelsDir")
            val expectedBytes = record.optLong("expectedBytes", 0)
            if (filename.isBlank() || modelsDir.isBlank()) {
                removeDownload(downloadId)
                continue
            }
            manager.query(DownloadManager.Query().setFilterById(downloadId))?.use { cursor ->
                if (!cursor.moveToFirst()) {
                    removeDownload(downloadId)
                    return@use
                }
                val status = cursor.getInt(cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                val downloaded = cursor.getLong(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
                )
                val total = cursor.getLong(
                    cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
                )
                when (status) {
                    DownloadManager.STATUS_SUCCESSFUL ->
                        finalizeDownload(downloadId, filename, modelsDir, downloaded, total, expectedBytes)
                    DownloadManager.STATUS_FAILED -> {
                        removeDownload(downloadId)
                        emitProgress(filename, downloaded, total, "Download failed")
                    }
                    else -> {
                        active.add(
                            mapOf(
                                "downloadId" to downloadId,
                                "filename" to filename,
                                "downloaded" to downloaded,
                                "total" to total,
                                "status" to if (status == DownloadManager.STATUS_PAUSED) "Paused" else "Downloading",
                            ),
                        )
                        monitorDownload(downloadId, filename, modelsDir, expectedBytes)
                    }
                }
            }
        }
        return active
    }

    private fun temporaryDownloadFile(filename: String): File {
        val base = getExternalFilesDir(null) ?: filesDir
        return File(File(base, "model_downloads"), filename)
    }

    private fun downloadPreferences() =
        getSharedPreferences("maxai_model_downloads", Context.MODE_PRIVATE)

    private fun persistDownload(downloadId: Long, filename: String, modelsDir: String, expectedBytes: Long) {
        val record = JSONObject()
            .put("filename", filename)
            .put("modelsDir", modelsDir)
            .put("expectedBytes", expectedBytes)
        downloadPreferences().edit().putString(downloadId.toString(), record.toString()).apply()
    }

    private fun removeDownload(downloadId: Long) {
        downloadPreferences().edit().remove(downloadId.toString()).apply()
    }

    private fun existingDownloadFor(filename: String): Long? {
        for ((idText, rawRecord) in downloadPreferences().all) {
            val record = runCatching { JSONObject(rawRecord as String) }.getOrNull() ?: continue
            if (record.optString("filename") == filename) return idText.toLongOrNull()
        }
        return null
    }

    private fun emitProgress(filename: String, downloaded: Long, total: Long, status: String) {
        mainHandler.post {
            downloadChannel?.invokeMethod(
                "downloadProgress",
                mapOf(
                    "filename" to filename,
                    "copiedBytes" to downloaded,
                    "totalBytes" to total,
                    "bytesPerSecond" to 0.0,
                    "status" to status,
                ),
            )
        }
    }

    private fun sanitizeFilename(filename: String): String =
        filename.replace(Regex("""[\\/:*?\"<>|]"""), "_")
}
