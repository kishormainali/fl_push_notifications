package com.kishormainali.push_notifications

import android.util.Log
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.MessageDigest

/**
 * Downloads notification images into [cacheDir] (a temp/cache directory),
 * keyed by a hash of the URL. Every failure yields `null` so callers can
 * fall back to a text-only notification.
 */
class ImageDownloader(private val cacheDir: File) {

    fun download(url: String, timeoutMs: Long, maxBytes: Long, httpsOnly: Boolean): File? =
        download(url, timeoutMs, maxBytes, schemePolicy(httpsOnly))

    /** [isAllowed] is applied to the initial URL and to every redirect target. */
    internal fun download(
        url: String,
        timeoutMs: Long,
        maxBytes: Long,
        isAllowed: (URL) -> Boolean,
    ): File? {
        val part = arrayOfNulls<File>(1)
        return try {
            fetch(url, timeoutMs, maxBytes, isAllowed, part)
        } catch (e: Exception) {
            fail("download failed: ${e.javaClass.simpleName}")
        } finally {
            part[0]?.delete()
        }
    }

    /** Partial downloads are tracked in [part] so the caller can delete them. */
    private fun fetch(
        url: String,
        timeoutMs: Long,
        maxBytes: Long,
        isAllowed: (URL) -> Boolean,
        part: Array<File?>,
    ): File? {
        var current = parse(url) ?: return fail("malformed url")
        if (!isAllowed(current)) return fail("url not allowed")
        val target = File(cacheDir, "push_notifications_img_${sha256(url)}")
        if (target.isFile && target.length() > 0) return target

        // One budget for the whole download, redirects included: every hop
        // only gets what is left of it.
        val deadline = System.nanoTime() + timeoutMs * 1_000_000
        var redirects = 0
        while (true) {
            val remainingMs = (deadline - System.nanoTime()) / 1_000_000
            if (remainingMs <= 0) return fail("timeout")
            val timeout = remainingMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            val conn = current.openConnection() as HttpURLConnection
            try {
                conn.instanceFollowRedirects = false
                conn.connectTimeout = timeout
                conn.readTimeout = timeout
                val code = conn.responseCode
                if (code in 300..399) {
                    val location = conn.getHeaderField("Location")
                        ?: return fail("redirect without location")
                    if (++redirects > MAX_REDIRECTS) return fail("too many redirects")
                    current = URL(current, location)
                    if (!isAllowed(current)) return fail("redirect not allowed")
                    continue
                }
                if (code !in 200..299) return fail("http $code")
                if (conn.contentLengthLong > maxBytes) return fail("content-length over cap")

                cacheDir.mkdirs()
                val tmp = File.createTempFile("push_notifications_img_", ".part", cacheDir)
                part[0] = tmp
                var total = 0L
                conn.inputStream.use { input ->
                    tmp.outputStream().use { out ->
                        val buf = ByteArray(8 * 1024)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            total += n
                            if (total > maxBytes) return fail("body over cap")
                            if (System.nanoTime() > deadline) return fail("timeout")
                            out.write(buf, 0, n)
                        }
                    }
                }
                if (total == 0L) return fail("empty body")
                if (!tmp.renameTo(target)) return fail("rename failed")
                part[0] = null
                return target
            } finally {
                conn.disconnect()
            }
        }
    }

    private fun fail(reason: String): File? {
        Log.d(TAG, "image download skipped: $reason")
        return null
    }

    companion object {
        private const val TAG = "push_notifications"
        private const val MAX_REDIRECTS = 5

        /** https always; http only when [httpsOnly] is false; nothing else. */
        fun schemePolicy(httpsOnly: Boolean): (URL) -> Boolean = { u ->
            val scheme = u.protocol.lowercase()
            scheme == "https" || (!httpsOnly && scheme == "http")
        }

        private fun parse(url: String): URL? = try {
            val uri = URI(url)
            if (uri.host.isNullOrEmpty()) null else uri.toURL()
        } catch (e: Exception) {
            null
        }

        private fun sha256(s: String): String =
            MessageDigest.getInstance("SHA-256").digest(s.toByteArray())
                .joinToString("") { "%02x".format(it) }
    }
}
