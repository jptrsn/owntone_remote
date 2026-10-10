package dev.educoder.owntone_remote

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
        flutterEngine.plugins.add(OwntoneRemotePlugin())
    }
}
