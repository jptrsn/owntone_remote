package dev.educoder.owntone_remote

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Two small channels:
 *  - "owntone_remote/call_state": pushes "callStateChanged" events
 *    ("ringing" | "active" | "idle") from TelephonyCallback.
 *  - "owntone_remote/permissions": "requestNotificationPermission" -> bool.
 *
 * No playback is ever triggered from this plugin; it only reports the phone
 * state and grants the Android 13+ notification permission.
 */
class OwntoneRemotePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware {

    private var callChannel: MethodChannel? = null
    private var permChannel: MethodChannel? = null
    private var telephonyCallback: TelephonyCallback? = null
    private var phoneStateListener: PhoneStateListener? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        callChannel = MethodChannel(messenger, CHANNEL_CALL_STATE).also {
            it.setMethodCallHandler(this)
        }
        permChannel = MethodChannel(messenger, CHANNEL_PERMISSIONS).also {
            it.setMethodCallHandler(this)
        }
        // Call-state listening needs READ_PHONE_STATE (runtime), so it is
        // deferred until the permission is granted (see
        // ensureCallListening, called from the permission flow).
        ensureCallListening(binding.applicationContext)
    }

    private fun ensureCallListening(context: Context) {
        if (telephonyCallback != null || phoneStateListener != null) return
        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.READ_PHONE_STATE
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) return
        startCallListening(context)
    }

    private fun startCallListening(context: Context) {
        val telephony =
            context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val callback = object : TelephonyCallback(),
                TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) {
                    pushCallState(telephonyCallName(state))
                }
            }
            telephony.registerTelephonyCallback(context.mainExecutor, callback)
            telephonyCallback = callback
        } else {
            // minSdk 26..30 fallback (deprecated API, still functional).
            val listener = object : PhoneStateListener() {
                override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                    pushCallState(telephonyCallName(state))
                }
            }
            @Suppress("DEPRECATION")
            telephony.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
            phoneStateListener = listener
        }
    }

    private fun telephonyCallName(state: Int): String = when (state) {
        TelephonyManager.CALL_STATE_RINGING -> "ringing"
        TelephonyManager.CALL_STATE_OFFHOOK -> "active"
        else -> "idle"
    }

    private fun pushCallState(name: String) {
        callChannel?.invokeMethod("callStateChanged", name)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermissions" -> requestRuntimePermissions(result)
            else -> result.notImplemented()
        }
    }

    /**
     * Requests the runtime permissions the app needs (POST_NOTIFICATIONS on
     * 33+, READ_PHONE_STATE for the call listener). Returns a map of
     * permission name -> granted.
     */
    private fun requestRuntimePermissions(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("NO_ACTIVITY", "no attached activity", null)
            return
        }
        val needed = mutableListOf<String>()
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.POST_NOTIFICATIONS
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.READ_PHONE_STATE
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            needed.add(Manifest.permission.READ_PHONE_STATE)
        }
        if (needed.isEmpty()) {
            result.success(mapOf<String, Boolean>())
            return
        }
        pendingPermissionResult = result
        activity.requestPermissions(needed.toTypedArray(), REQUEST_NOTIFICATIONS)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        val telephony =
            context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        telephonyCallback?.let {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                telephony.unregisterTelephonyCallback(it)
            }
        }
        telephonyCallback = null
        phoneStateListener?.let {
            @Suppress("DEPRECATION")
            telephony.listen(it, PhoneStateListener.LISTEN_NONE)
        }
        phoneStateListener = null
        callChannel?.setMethodCallHandler(null)
        callChannel = null
        permChannel?.setMethodCallHandler(null)
        permChannel = null
    }

    private val permissionResultListener =
        io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener {
            requestCode,
            permissions,
            grantResults ->
            if (requestCode == REQUEST_NOTIFICATIONS) {
                val map = permissions.mapIndexed { i, p ->
                    p to (grantResults[i] == PackageManager.PERMISSION_GRANTED)
                }.toMap()
                pendingPermissionResult?.success(map)
                pendingPermissionResult = null
                if (map[Manifest.permission.READ_PHONE_STATE] == true) {
                    activityBinding?.activity?.let { ensureCallListening(it) }
                }
                true
            } else {
                false
            }
        }

    // ActivityAware
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(permissionResultListener)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeRequestPermissionsResultListener(permissionResultListener)
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addRequestPermissionsResultListener(permissionResultListener)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(permissionResultListener)
        activityBinding = null
    }

    companion object {
        const val CHANNEL_CALL_STATE = "owntone_remote/call_state"
        const val CHANNEL_PERMISSIONS = "owntone_remote/permissions"
        private const val REQUEST_NOTIFICATIONS = 42
    }
}
