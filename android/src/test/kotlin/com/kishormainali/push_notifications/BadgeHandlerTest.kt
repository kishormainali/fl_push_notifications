package com.kishormainali.push_notifications

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class InMemoryStore : KeyValueStore {
    val map = mutableMapOf<String, Any>()
    override fun getString(key: String) = map[key] as String?
    override fun getLong(key: String) = map[key] as Long?
    override fun getBoolean(key: String) = map[key] as Boolean?
    override fun putAll(values: Map<String, Any?>) {
        for ((k, v) in values) if (v == null) map.remove(k) else map[k] = v
    }
}

class BadgeHandlerTest {
    private val sent = mutableListOf<Pair<BadgeVendor, Int>>()
    private val recordingSender = BadgeSender { v, c -> sent += v to c }

    private fun handler(store: KeyValueStore, launcher: String?, sender: BadgeSender = recordingSender) =
        BadgeHandler(store, { launcher }, sender)

    @Test
    fun `unrecognized launcher reports unsupported and set does not throw`() {
        val store = InMemoryStore()
        val throwing = BadgeSender { _, _ -> error("must not be called") }
        val h = handler(store, "com.example.unknown.launcher", throwing)
        assertFalse(h.isBadgeSupported())
        h.setBadgeCount(5)
        assertEquals(5L, h.storedCount())
        h.clearBadge()
        assertEquals(0L, h.storedCount())
    }

    @Test
    fun `no launcher resolved reports unsupported`() {
        assertFalse(handler(InMemoryStore(), null).isBadgeSupported())
    }

    @Test
    fun `recognized launcher is supported and receives the count`() {
        val h = handler(InMemoryStore(), "com.sec.android.app.launcher")
        assertTrue(h.isBadgeSupported())
        h.setBadgeCount(3)
        assertEquals(listOf(BadgeVendor.DEFAULT to 3), sent)
    }

    @Test
    fun `sender failure is swallowed and counter still stored`() {
        val store = InMemoryStore()
        val h = handler(store, "com.huawei.android.launcher", BadgeSender { _, _ -> throw SecurityException("x") })
        h.setBadgeCount(2)
        assertEquals(2L, h.storedCount())
    }

    @Test
    fun `counter persists across handler instances via the store`() {
        val store = InMemoryStore()
        handler(store, null).setBadgeCount(4)
        assertEquals(4L, handler(store, null).storedCount())
        assertEquals(4L, store.getLong(BadgeHandler.KEY_COUNT))
    }

    @Test
    fun `negative count is clamped to 0`() {
        val store = InMemoryStore()
        val h = handler(store, "com.miui.home")
        h.setBadgeCount(-7)
        assertEquals(0L, h.storedCount())
        assertEquals(listOf(BadgeVendor.XIAOMI to 0), sent)
    }

    @Test
    fun `increment returns the new count and persists it`() {
        val store = InMemoryStore()
        val h = handler(store, "com.bbk.launcher2")
        assertEquals(1L, h.incrementBadge())
        assertEquals(2L, handler(store, "com.bbk.launcher2").incrementBadge())
        assertEquals(listOf(BadgeVendor.VIVO to 1, BadgeVendor.VIVO to 2), sent)
    }

    @Test
    fun `getBadgeCount returns null on Android`() {
        val h = handler(InMemoryStore(), "com.sec.android.app.launcher")
        h.setBadgeCount(3)
        assertNull(h.getBadgeCount())
    }

    @Test
    fun `every vendor package maps back to its vendor`() {
        for (v in BadgeVendor.entries) for (p in v.packages) assertEquals(v, BadgeVendor.of(p))
    }
}

class PushStorageTest {
    @Test
    fun `background config round-trips including null hookHandle`() {
        val store = InMemoryStore()
        val s = PushStorage(store)
        assertNull(s.loadBackgroundConfig())
        val c = BackgroundConfigMsg("d", "ck", "img", "t", "b", false, true, true, 42L)
        s.saveBackgroundConfig(c)
        assertEquals(c, PushStorage(store).loadBackgroundConfig())
        val noHook = c.copy(hookHandle = null, imageHttpsOnly = true)
        s.saveBackgroundConfig(noHook)
        assertEquals(noHook, s.loadBackgroundConfig())
    }

    @Test
    fun `last launch id round-trips`() {
        val s = PushStorage(InMemoryStore())
        assertNull(s.getLastLaunchId())
        s.setLastLaunchId("a\nb")
        assertEquals("a\nb", s.getLastLaunchId())
    }
}
