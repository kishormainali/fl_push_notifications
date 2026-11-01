package com.kishormainali.push_notifications

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlin.coroutines.CoroutineContext
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Queues dispatched blocks without running them: any hop would be visible. */
private class HoldingDispatcher : CoroutineDispatcher() {
    val held = mutableListOf<Runnable>()
    override fun dispatch(context: CoroutineContext, block: Runnable) {
        held.add(block)
    }
    fun runAll() {
        while (held.isNotEmpty()) held.removeAt(0).run()
    }
}

class TapDeliveryTest {
    @Test
    fun `send happens synchronously inside the caller, without a dispatch hop`() {
        val dispatcher = HoldingDispatcher()
        val scope = CoroutineScope(Job() + dispatcher)
        val sent = mutableListOf<NativeTap>()
        val kept = mutableListOf<NativeTap>()
        deliverTapLive(scope, NativeTap("p", true), { sent.add(it) }, kept::add)
        assertEquals(listOf(NativeTap("p", true)), sent)
        assertTrue(dispatcher.held.isEmpty(), "nothing was posted for later")
        assertTrue(kept.isEmpty())
        scope.cancel()
    }

    @Test
    fun `no scope or no api keeps the tap with its flag`() {
        val kept = mutableListOf<NativeTap>()
        deliverTapLive(null, NativeTap("a", true), { error("not sent") }, kept::add)
        deliverTapLive(CoroutineScope(Dispatchers.Unconfined), NativeTap("b", false), null, kept::add)
        assertEquals(listOf(NativeTap("a", true), NativeTap("b", false)), kept)
    }

    @Test
    fun `a failed send keeps the tap with its flag`() {
        val dispatcher = HoldingDispatcher()
        val scope = CoroutineScope(Job() + dispatcher)
        val reply = CompletableDeferred<Unit>()
        val kept = mutableListOf<NativeTap>()
        deliverTapLive(scope, NativeTap("x", true), { reply.await() }, kept::add)
        assertTrue(kept.isEmpty())
        reply.completeExceptionally(IllegalStateException("no handler"))
        dispatcher.runAll()
        assertEquals(listOf(NativeTap("x", true)), kept)
        scope.cancel()
    }

    @Test
    fun `a send cancelled by engine detach keeps the tap`() {
        val dispatcher = HoldingDispatcher()
        val scope = CoroutineScope(Job() + dispatcher)
        val kept = mutableListOf<NativeTap>()
        deliverTapLive(scope, NativeTap("c", false), { CompletableDeferred<Unit>().await() }, kept::add)
        scope.cancel()
        dispatcher.runAll()
        assertEquals(listOf(NativeTap("c", false)), kept)
    }
}

class ActivityActiveTrackerTest {
    @Test
    fun `foreground tap - paused around onNewIntent after being resumed - is active`() {
        val t = ActivityActiveTracker()
        t.onStarted()
        t.onResumed()
        // Android pauses a resumed activity before delivering onNewIntent.
        t.onPaused()
        assertTrue(t.appWasActive)
    }

    @Test
    fun `background tap - restarted from stopped - is not active`() {
        val t = ActivityActiveTracker()
        t.onStarted()
        t.onResumed()
        t.onPaused()
        t.onStopped()
        assertEquals(false, t.appWasActive, "onNewIntent before onRestart")
        t.onStarted()
        assertEquals(false, t.appWasActive, "onNewIntent after onStart")
        t.onResumed()
        assertTrue(t.appWasActive)
    }

    @Test
    fun `fresh or reset tracker is not active`() {
        val t = ActivityActiveTracker()
        assertEquals(false, t.appWasActive)
        t.onResumed()
        t.reset()
        assertEquals(false, t.appWasActive)
    }
}
