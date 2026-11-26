package dev.educoder.owntone_remote

import android.view.KeyEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * R-06/D20 (issue #84): the app-local, foreground-only path that maps the
 * hardware volume rocker to the OwnTone **server** volume.
 *
 * The media session used to do this by publishing `absolute` volume control
 * while foregrounded — which is also what made SystemUI's media tile / output
 * row render a slider showing the *server* volume. The session is now
 * published `fixed` in every app state, so Android never routes the rocker to
 * it and the tile shows transport + progress only. This hook replaces that
 * routing: [MainActivity] forwards the volume keys here and Dart steps the
 * server. A key this app declines goes to `super`, i.e. the phone's normal
 * volume behaviour (R-06's backgrounded rule).
 *
 * Two independent gates keep a backgrounded app off the server:
 *  - [onKeyEvent] needs *both* an attached Activity ([onActivityAttached]) and
 *    Dart's "the app is resumed" signal (`startForwarding`, cleared on
 *    Activity/engine detach). A screen-off app, or a process restarted by the
 *    audio service with no UI, therefore forwards nothing — and an Activity
 *    that re-attaches recovers the path without waiting for Dart.
 *  - Dart re-checks its own lifecycle flag before touching the server, which
 *    covers the foreground→background window where a key can still arrive for
 *    a window Android is just deselecting.
 *
 * The take-it-or-leave-it decision is made here rather than from Dart's reply
 * because `MethodChannel.invokeMethod` is asynchronous while Android key
 * consumption must be decided synchronously. That is safe: Dart sets its own
 * lifecycle flag *before* asking to forward, so a key is only ever taken while
 * Dart has committed to handling it. The one window where the two can disagree
 * is the foreground→background transition — there Dart's second-layer guard
 * drops the key instead of moving the server, costing one lost key press and
 * keeping the backgrounded-inert rule intact.
 *
 * Channel shape (same pattern as OwntoneRemotePlugin's channels):
 *  - Dart -> platform: `startForwarding` / `stopForwarding`.
 *  - platform -> Dart: `volumeKey` with "raise" | "lower" | "same"
 *    ("same" = key release / end-of-sequence marker, spike Finding 10 — it
 *    must never become a step, or every press cancels itself).
 */
object VolumeKeys : MethodChannel.MethodCallHandler {

    const val CHANNEL_VOLUME_KEYS = "owntone_remote/volume_keys"

    private var channel: MethodChannel? = null

    /** Set while Dart reports the app as resumed. */
    private var dartWantsKeys = false

    /** Set while an Activity is attached to the engine. */
    private var activityAttached = false

    /** The volume keyCode whose ACTION_DOWN was forwarded, so the matching
     * ACTION_UP is treated as part of the same press instead of leaking to
     * the phone's own stream to finish the sequence. */
    private var forwardedKeyCode = KeyEvent.KEYCODE_UNKNOWN

    /** Called from OwntoneRemotePlugin.onAttachedToEngine. */
    fun attach(messenger: BinaryMessenger) {
        if (channel != null) return
        channel = MethodChannel(messenger, CHANNEL_VOLUME_KEYS).also {
            it.setMethodCallHandler(this)
        }
    }

    /** Called from OwntoneRemotePlugin.onDetachedFromEngine. */
    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        dartWantsKeys = false
        activityAttached = false
        forwardedKeyCode = KeyEvent.KEYCODE_UNKNOWN
    }

    /** Called from OwntoneRemotePlugin.onAttachedToActivity. */
    fun onActivityAttached() {
        activityAttached = true
    }

    /** Called from OwntoneRemotePlugin.onDetachedFromActivity: with no
     * Activity there is nothing to forward, and the keys are the phone's. */
    fun onActivityDetached() {
        activityAttached = false
        forwardedKeyCode = KeyEvent.KEYCODE_UNKNOWN
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startForwarding" -> {
                dartWantsKeys = true
                result.success(true)
            }
            "stopForwarding" -> {
                dartWantsKeys = false
                forwardedKeyCode = KeyEvent.KEYCODE_UNKNOWN
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /** Handle one Android key event from [MainActivity]. Returns `true` when
     * this app took the key, in which case the caller must not pass it on. */
    fun onKeyEvent(event: KeyEvent): Boolean {
        val messenger = channel ?: return false
        if (!dartWantsKeys || !activityAttached) {
            resetIfNewPress(event)
            return false
        }
        val keyCode = event.keyCode
        val direction = when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> "raise"
            KeyEvent.KEYCODE_VOLUME_DOWN -> "lower"
            else -> null
        }
        if (direction == null) {
            resetIfNewPress(event)
            return false
        }
        return when (event.action) {
            // ACTION_MULTIPLE is the long-press repeat batch; treat it as one
            // press of the same direction so a held rocker keeps stepping the
            // server instead of leaking to the phone's stream mid-sequence.
            KeyEvent.ACTION_DOWN, KeyEvent.ACTION_MULTIPLE -> {
                messenger.invokeMethod("volumeKey", direction)
                forwardedKeyCode = keyCode
                true
            }
            KeyEvent.ACTION_UP -> {
                val ours = forwardedKeyCode == keyCode
                // End-of-sequence marker: forwarded as `same`, which Dart
                // must map to no server call (spike Finding 10).
                messenger.invokeMethod("volumeKey", "same")
                if (ours) forwardedKeyCode = KeyEvent.KEYCODE_UNKNOWN
                ours
            }
            else -> false
        }
    }

    private fun resetIfNewPress(event: KeyEvent) {
        if (event.action == KeyEvent.ACTION_DOWN ||
            event.action == KeyEvent.ACTION_MULTIPLE
        ) {
            forwardedKeyCode = KeyEvent.KEYCODE_UNKNOWN
        }
    }
}
