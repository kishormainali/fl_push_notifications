package com.kishormainali.push_notifications

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class FakePayloadSource(var value: String?) : PayloadSource {
    var removed = 0
    override fun get() = value
    override fun remove() {
        removed++
        value = null
    }
}

class TapPayloadHolderTest {
    @Test
    fun `launch payload is captured once and stripped from the intent`() {
        val h = TapPayloadHolder()
        val src = FakePayloadSource("a")
        h.captureLaunch(src)
        h.captureLaunch(src)
        assertNull(src.value)
        assertEquals(1, src.removed)
        val rest = mutableListOf<String>()
        assertEquals("a", h.consumeLaunchPayload(rest::add))
        assertNull(h.consumeLaunchPayload(rest::add))
        assertEquals(emptyList(), rest)
    }

    @Test
    fun `two undelivered taps both survive in order`() {
        val h = TapPayloadHolder()
        h.captureLaunch(FakePayloadSource("launch"))
        // Second tap via onNewIntent before Dart registered PushFlutterApi.
        h.keep("second")
        val rest = mutableListOf<String>()
        assertEquals("launch", h.consumeLaunchPayload(rest::add))
        assertEquals(listOf("second"), rest)
        // Consumed exactly once.
        assertNull(h.consumeLaunchPayload(rest::add))
        assertEquals(listOf("second"), rest)
    }

    @Test
    fun `kept taps are delivered in fifo order`() {
        val h = TapPayloadHolder()
        h.keep("a")
        h.keep("b")
        h.keep("c")
        val rest = mutableListOf<String>()
        assertEquals("a", h.consumeLaunchPayload(rest::add))
        assertEquals(listOf("b", "c"), rest)
    }

    @Test
    fun `a payload re-queued after a failed live delivery is consumed later`() {
        val h = TapPayloadHolder()
        val rest = mutableListOf<String>()
        h.keep("x")
        assertEquals("x", h.consumeLaunchPayload(rest::add))
        assertNull(h.consumeLaunchPayload(rest::add))
        // A live delivery that failed after consume is queued again and
        // returned by the next consume (no tap dropped).
        h.keep("y")
        assertEquals("y", h.consumeLaunchPayload(rest::add))
        assertEquals(emptyList(), rest)
    }

    @Test
    fun `take strips the extra and returns null when absent`() {
        val src = FakePayloadSource(null)
        assertNull(TapPayloadHolder.take(src))
        assertEquals(0, src.removed)
        val with = FakePayloadSource("p")
        assertEquals("p", TapPayloadHolder.take(with))
        assertNull(TapPayloadHolder.take(with))
    }
}
