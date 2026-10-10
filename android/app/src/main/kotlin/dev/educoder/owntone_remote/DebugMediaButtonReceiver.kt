package dev.educoder.owntone_remote

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.view.KeyEvent

/**
 * DEBUG builds only. Fires the exact code path the audio_service
 * notification's action buttons use: a broadcast to
 * com.ryanheise.audioservice.MediaButtonReceiver carrying a
 * KEY_EVENT extra (the only form androidx.media's receiver accepts).
 *
 * Needed for device verification because (a) the shell cannot
 * construct a KeyEvent parcelable, (b) Android 16 does not render
 * this app's transport notification in the shade, and (c) the
 * lock screen is not uiautomator-reachable.
 *
 * Usage:
 *   adb shell am broadcast -a dev.educoder.owntone_remote.DEBUG_MEDIA_BUTTON \
 *     --ei keycode 85    # 85=play 86=pause 87=next 88=previous
 */
class DebugMediaButtonReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val isDebug =
            (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!isDebug) return
        val keyCode = intent.getIntExtra(EXTRA_KEYCODE, KeyEvent.KEYCODE_UNKNOWN)
        if (keyCode == KeyEvent.KEYCODE_UNKNOWN) return
        val mediaIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            component = ComponentName(
                context,
                com.ryanheise.audioservice.MediaButtonReceiver::class.java
            )
            putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
        }
        // A real system dispatch is required: the plugin's receiver
        // calls goAsync(), which only works inside framework delivery.
        context.sendBroadcast(mediaIntent)
    }

    companion object {
        const val ACTION = "dev.educoder.owntone_remote.DEBUG_MEDIA_BUTTON"
        const val EXTRA_KEYCODE = "keycode"
    }
}
