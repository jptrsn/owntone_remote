package dev.educoder.owntone_remote

import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

// AudioServiceActivity (not plain FlutterActivity): it registers the
// activity's engine in the FlutterEngineCache under the id audio_service
// uses, so the bound AudioService reuses the SAME engine. A plain
// FlutterActivity makes the service spawn a second engine that runs main()
// again (duplicate Dart runtime, "wrong engine" platform errors).
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // NOT load-bearing for volume correctness: FlutterEngineConnectionRegistry.add()
        // already short-circuits on a duplicate plugin class (it logs "Attempted to
        // register plugin … already registered" and returns without calling
        // onAttachedToEngine), and VolumeKeys.attach() is itself idempotent, so a
        // post-config-change re-attach could never stack a second handler on the
        // volume-key channel. Kept so the re-attach skips the warning log and the
        // throwaway plugin instance instead of relying on that behaviour two
        // layers down.
        if (flutterEngine.plugins.get(OwntoneRemotePlugin::class.java) == null) {
            flutterEngine.plugins.add(OwntoneRemotePlugin())
        }
    }

    // R-06/D20 (issue #84): the hardware volume rocker reaches the server's
    // master volume through this Activity path, not through the media
    // session — the session is published `fixed` in every app state, so
    // SystemUI renders no server-volume slider and Android never routes the
    // keys to it. VolumeKeys forwards only while Dart says the app is
    // resumed; anything it declines goes to super, i.e. the phone's normal
    // volume behaviour.
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        VolumeKeys.onKeyEvent(event) || super.onKeyDown(keyCode, event)

    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean =
        VolumeKeys.onKeyEvent(event) || super.onKeyUp(keyCode, event)

    override fun onKeyMultiple(keyCode: Int, repeatCount: Int, event: KeyEvent): Boolean =
        VolumeKeys.onKeyEvent(event) || super.onKeyMultiple(keyCode, repeatCount, event)
}
