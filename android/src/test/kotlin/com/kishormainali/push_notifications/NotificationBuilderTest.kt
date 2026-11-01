package com.kishormainali.push_notifications

import android.app.Notification
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun content(
    id: Long = 7,
    channelId: String = "chat",
    badge: Long? = null,
    imageUrl: String? = null,
    style: ImageStyle = ImageStyle.NONE,
    extras: Map<String?, Any?> = emptyMap(),
    body: String? = "B",
) = NotificationContent(
    id = id,
    title = "T",
    body = body,
    channelId = channelId,
    data = mapOf("k" to "v", "q" to "a\"b\\c\n"),
    imageUrl = imageUrl,
    imageStyle = style,
    badge = badge,
    extras = extras,
)

private fun cfg(httpsOnly: Boolean = true, defaultChannel: String = "default") =
    BackgroundConfigMsg(defaultChannel, "channel_id", "image", "title", "body", httpsOnly, false, false, null)

class NotificationPlannerTest {
    private val known = setOf("default", "chat")
    private fun plan(c: NotificationContent, hasBitmap: Boolean = false, default: String? = "default") =
        NotificationPlanner.plan(c, hasBitmap, { it in known }, default)

    @Test
    fun `builder uses BigPictureStyle with bitmap and plain style without`() {
        assertEquals(NotificationStyleKind.BIG_PICTURE, plan(content(), hasBitmap = true).style)
        assertEquals(NotificationStyleKind.BIG_TEXT, plan(content()).style)
        assertEquals(NotificationStyleKind.PLAIN, plan(content(body = null)).style)
    }

    @Test
    fun `builder sets number from badge`() {
        assertEquals(3, plan(content(badge = 3)).number)
        assertNull(plan(content()).number)
    }

    @Test
    fun `unknown channel id falls back to the default channel`() {
        assertEquals("chat", plan(content(channelId = "chat")).channelId)
        assertEquals("default", plan(content(channelId = "nope")).channelId)
        // No stored default: keep the requested id rather than inventing one.
        assertEquals("nope", plan(content(channelId = "nope"), default = null).channelId)
    }

    @Test
    fun `notification id is the content id`() {
        assertEquals(42, plan(content(id = 42)).id)
    }

    @Test
    fun `payload JSON contains the contract fields`() {
        val p = plan(content(channelId = "nope", imageUrl = "https://i/x.png", style = ImageStyle.BIG_PICTURE)).payload
        assertEquals(
            "{\"id\":\"7\",\"title\":\"T\",\"body\":\"B\",\"data\":{\"k\":\"v\",\"q\":\"a\\\"b\\\\c\\n\"}," +
                "\"imageUrl\":\"https://i/x.png\",\"channelId\":\"default\"}",
            p,
        )
    }

    @Test
    fun `payload id is extras messageId when present`() {
        val p = plan(content(extras = mapOf("messageId" to "fcm-1"), body = null)).payload
        assertTrue(p.startsWith("{\"id\":\"fcm-1\",\"title\":\"T\",\"body\":null,"), p)
        assertTrue(p.endsWith("\"imageUrl\":null,\"channelId\":\"chat\"}"), p)
    }

    @Test
    fun `small icon resolution order`() {
        assertEquals(1, SmallIconResolver.pick(1, 2, 3))
        assertEquals(2, SmallIconResolver.pick(0, 2, 3))
        assertEquals(3, SmallIconResolver.pick(0, 0, 3))
        assertEquals(android.R.drawable.sym_def_app_icon, SmallIconResolver.pick(0, 0, 0))
    }
}

class NotificationPresenterTest {
    private val posted = mutableListOf<Int>()
    private val built = mutableListOf<Pair<NotificationContent, String?>>()
    private val loads = mutableListOf<Pair<String, Boolean>>()

    private fun presenter(
        config: BackgroundConfigMsg? = cfg(),
        image: String? = "bitmap",
        loadThrows: Boolean = false,
        canPost: Boolean = true,
    ) = NotificationPresenter<String>(
        config = { config },
        loadImage = { url, httpsOnly ->
            loads += url to httpsOnly
            if (loadThrows) error("boom")
            image
        },
        build = { c, img -> built += c to img; Notification() },
        canPost = { canPost },
        notifier = { id, _ -> posted += id },
    )

    @Test
    fun `same notification id replaces rather than stacks`() = runBlocking {
        val p = presenter()
        p.show(content(id = 5))
        p.show(content(id = 5))
        assertEquals(listOf(5, 5), posted)
    }

    @Test
    fun `image is downloaded with the persisted httpsOnly and passed to the builder`() = runBlocking {
        presenter(config = cfg(httpsOnly = false)).show(content(imageUrl = "http://i/x", style = ImageStyle.BIG_PICTURE))
        assertEquals(listOf("http://i/x" to false), loads)
        assertEquals("bitmap", built.single().second)
    }

    @Test
    fun `httpsOnly defaults to true without a persisted config`() = runBlocking {
        presenter(config = null).show(content(imageUrl = "https://i/x", style = ImageStyle.BIG_PICTURE))
        assertEquals(listOf("https://i/x" to true), loads)
    }

    @Test
    fun `image failure falls back to a text-only notification`() = runBlocking {
        presenter(image = null).show(content(id = 1, imageUrl = "https://i/x", style = ImageStyle.BIG_PICTURE))
        presenter(loadThrows = true).show(content(id = 2, imageUrl = "https://i/x", style = ImageStyle.BIG_PICTURE))
        assertEquals(listOf<String?>(null, null), built.map { it.second })
        assertEquals(listOf(1, 2), posted)
    }

    @Test
    fun `no download unless imageStyle is bigPicture`() = runBlocking {
        presenter().show(content(imageUrl = "https://i/x", style = ImageStyle.NONE))
        assertTrue(loads.isEmpty())
        assertNull(built.single().second)
    }

    @Test
    fun `missing permission skips posting without crashing`() = runBlocking {
        presenter(canPost = false).show(content())
        assertTrue(posted.isEmpty())
    }

    @Test
    fun `notifier SecurityException is swallowed`() = runBlocking {
        val p = NotificationPresenter<String>(
            config = { null },
            loadImage = { _, _ -> null },
            build = { _, _ -> Notification() },
            canPost = { true },
            notifier = { _, _ -> throw SecurityException("denied") },
        )
        p.show(content())
    }

    @Test
    fun `cancellation during image load is rethrown, not swallowed`() {
        val p = NotificationPresenter<String>(
            config = { null },
            loadImage = { _, _ -> throw CancellationException("cancelled") },
            build = { c, img -> built += c to img; Notification() },
            canPost = { true },
            notifier = { id, _ -> posted += id },
        )
        assertFailsWith<CancellationException> {
            runBlocking { p.show(content(imageUrl = "https://i/x", style = ImageStyle.BIG_PICTURE)) }
        }
        assertTrue(posted.isEmpty())
    }

    @Test
    fun `build failure with a bitmap retries once text-only`() = runBlocking {
        val p = NotificationPresenter<String>(
            config = { null },
            loadImage = { _, _ -> "bitmap" },
            build = { c, img ->
                built += c to img
                if (img != null) error("bitmap too large")
                Notification()
            },
            canPost = { true },
            notifier = { id, _ -> posted += id },
        )
        p.show(content(id = 3, imageUrl = "https://i/x", style = ImageStyle.BIG_PICTURE))
        assertEquals(listOf<String?>("bitmap", null), built.map { it.second })
        assertEquals(listOf(3), posted)
    }

    @Test
    fun `notify failure with a bitmap retries once text-only`() = runBlocking {
        val withImage = mutableListOf<Boolean>()
        val p = NotificationPresenter<String>(
            config = { null },
            loadImage = { _, _ -> "bitmap" },
            build = { c, img -> built += c to img; Notification() },
            canPost = { true },
            notifier = { id, _ ->
                withImage += built.last().second != null
                if (built.last().second != null) throw IllegalArgumentException("binder too large")
                posted += id
            },
        )
        p.show(content(id = 4, imageUrl = "https://i/x", style = ImageStyle.BIG_PICTURE))
        assertEquals(listOf(true, false), withImage)
        assertEquals(listOf(4), posted)
    }

    @Test
    fun `text-only build failure is not retried and propagates`() {
        var builds = 0
        val p = NotificationPresenter<String>(
            config = { null },
            loadImage = { _, _ -> null },
            build = { _, _ -> builds++; error("broken") },
            canPost = { true },
            notifier = { id, _ -> posted += id },
        )
        assertFailsWith<IllegalStateException> { runBlocking { p.show(content()) } }
        assertEquals(1, builds)
        assertTrue(posted.isEmpty())
    }
}

class FakeChannelStore : ChannelStore {
    val channels = linkedMapOf<String, ChannelSpec>()
    var upserts = 0
    override fun exists(id: String) = id in channels
    override fun upsert(spec: ChannelSpec) {
        upserts++
        channels[spec.id] = spec
    }
    override fun delete(id: String) {
        channels.remove(id)
    }
}

class ChannelManagerTest {
    private val store = FakeChannelStore()
    private val manager = ChannelManager(store) { "default" }

    private fun config(id: String = "chat", importance: Long = 4) =
        ChannelConfig(id, "Chat", "Messages", importance, false, true, false, "g1")

    @Test
    fun `createChannel is idempotent and applies settings`() {
        manager.create(config())
        manager.create(config())
        assertEquals(1, store.channels.size)
        assertEquals(
            ChannelSpec("chat", "Chat", "Messages", 4, playSound = false, enableVibration = true, showBadge = false, groupId = "g1"),
            store.channels["chat"],
        )
        assertTrue(manager.exists("chat"))
    }

    @Test
    fun `out-of-range importance maps to default importance`() {
        manager.create(config(importance = -1000))
        assertEquals(3, store.channels["chat"]!!.importance)
        manager.create(config(importance = 5))
        assertEquals(5, store.channels["chat"]!!.importance)
    }

    @Test
    fun `deleteChannel of the default channel is refused`() {
        manager.create(config(id = "default"))
        val e = assertFailsWith<FlutterError> { manager.delete("default") }
        assertEquals("default-channel", e.code)
        assertTrue(store.exists("default"))
    }

    @Test
    fun `deleteChannel removes a non-default channel`() {
        manager.create(config())
        manager.delete("chat")
        assertTrue(store.channels.isEmpty())
    }
}
