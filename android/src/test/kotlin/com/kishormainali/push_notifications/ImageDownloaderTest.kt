package com.kishormainali.push_notifications

import java.io.File
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import kotlin.concurrent.thread
import java.net.URL
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ImageDownloaderTest {
    private lateinit var server: TestHttpServer
    private lateinit var cacheDir: File
    private lateinit var downloader: ImageDownloader
    private val image = ByteArray(1500) { (it % 251).toByte() }
    private var hits = 0

    private val base get() = "http://127.0.0.1:${server.port}"

    @BeforeTest
    fun setUp() {
        cacheDir = Files.createTempDirectory("img-cache").toFile()
        downloader = ImageDownloader(cacheDir)
        server = TestHttpServer { path, out ->
            when (path) {
                "/ok" -> {
                    hits++
                    out.respond(200, image)
                }
                "/missing" -> out.respond(404, ByteArray(0))
                "/slow" -> {
                    Thread.sleep(2_000)
                    out.respond(200, image)
                }
                "/big-declared" -> out.respond(200, ByteArray(5_000))
                // No Content-Length: body ends when the connection closes.
                "/big-chunked" -> out.respond(200, ByteArray(5_000), declareLength = false)
                "/redirect" -> out.respond(302, ByteArray(0), headers = mapOf("Location" to "/ok"))
                else -> out.respond(500, ByteArray(0))
            }
        }
    }

    @AfterTest
    fun tearDown() {
        server.close()
        cacheDir.deleteRecursively()
    }

    private fun get(path: String, maxBytes: Long = 1_000_000, timeoutMs: Long = 1_000) =
        downloader.download("$base$path", timeoutMs, maxBytes, httpsOnly = false)

    @Test
    fun `success writes the image to a cached file keyed by url`() {
        val f = assertNotNull(get("/ok"))
        assertTrue(f.exists())
        assertEquals(cacheDir.canonicalPath, f.parentFile.canonicalPath)
        assertContentEquals(image, f.readBytes())
        // Second call is a cache hit.
        assertEquals(f.canonicalPath, assertNotNull(get("/ok")).canonicalPath)
        assertEquals(1, hits)
    }

    @Test
    fun `http url rejected when httpsOnly`() {
        assertNull(downloader.download("$base/ok", 1_000, 1_000_000, httpsOnly = true))
        assertEquals(0, hits)
    }

    @Test
    fun `scheme policy only allows https when httpsOnly`() {
        val strict = ImageDownloader.schemePolicy(httpsOnly = true)
        assertFalse(strict(URL("http://x/y.png")))
        assertTrue(strict(URL("https://x/y.png")))
        val lax = ImageDownloader.schemePolicy(httpsOnly = false)
        assertTrue(lax(URL("http://x/y.png")))
        assertFalse(lax(URL("ftp://x/y.png")))
    }

    @Test
    fun `redirect to a disallowed url is rejected`() {
        // Simulates "https start, http redirect target" with a path policy:
        // the redirect target is checked against the same policy.
        val f = downloader.download("$base/redirect", 1_000, 1_000_000) { it.path == "/redirect" }
        assertNull(f)
        assertEquals(0, hits)
    }

    @Test
    fun `allowed redirect is followed`() {
        val f = assertNotNull(get("/redirect"))
        assertContentEquals(image, f.readBytes())
    }

    @Test
    fun `oversize body aborts and returns null`() {
        assertNull(get("/big-declared", maxBytes = 1_000))
        assertNull(get("/big-chunked", maxBytes = 1_000))
        assertTrue(cacheDir.listFiles().orEmpty().isEmpty(), "partial file left behind")
    }

    @Test
    fun `timeout returns null`() {
        val start = System.nanoTime()
        assertNull(get("/slow", timeoutMs = 300))
        assertTrue((System.nanoTime() - start) / 1_000_000 < 1_900)
    }

    @Test
    fun `404 returns null`() {
        assertNull(get("/missing"))
    }

    @Test
    fun `malformed url returns null`() {
        for (u in listOf("", "not a url", "://x", "https://", "file:///etc/passwd")) {
            assertNull(downloader.download(u, 1_000, 1_000_000, httpsOnly = false), u)
        }
    }
}

/** Minimal HTTP/1.0 server (com.sun.net.httpserver is not on the android.jar classpath). */
class TestHttpServer(private val handler: (path: String, out: OutputStream) -> Unit) : AutoCloseable {
    private val socket = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
    val port: Int get() = socket.localPort

    init {
        thread(isDaemon = true) {
            while (!socket.isClosed) {
                val client = try { socket.accept() } catch (e: Exception) { break }
                thread(isDaemon = true) {
                    client.use { c ->
                        try {
                            val reader = c.getInputStream().bufferedReader()
                            val path = reader.readLine()?.split(" ")?.getOrNull(1) ?: return@use
                            while (!reader.readLine().isNullOrEmpty()) Unit
                            handler(path, c.getOutputStream())
                        } catch (e: Exception) {
                            // client went away (e.g. timeout or abort)
                        }
                    }
                }
            }
        }
    }

    override fun close() = socket.close()
}

fun OutputStream.respond(
    code: Int,
    body: ByteArray,
    declareLength: Boolean = true,
    headers: Map<String, String> = emptyMap(),
) {
    val sb = StringBuilder("HTTP/1.0 $code X\r\nConnection: close\r\n")
    if (declareLength) sb.append("Content-Length: ${body.size}\r\n")
    for ((k, v) in headers) sb.append("$k: $v\r\n")
    sb.append("\r\n")
    write(sb.toString().toByteArray())
    write(body)
    flush()
}
