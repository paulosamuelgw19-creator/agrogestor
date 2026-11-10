package com.campo.agrogestao

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val activationExecutor = Executors.newSingleThreadExecutor()
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = LocalActivationBridge(applicationContext)
        val handler = Handler(Looper.getMainLooper())
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "agrogestor/local_activation")
            .setMethodCallHandler { call, result ->
                activationExecutor.execute {
                    try {
                        val value = when (call.method) {
                            "identity" -> bridge.identity()
                            "status" -> bridge.status()
                            "sign" -> bridge.sign(call.argument<String>("message") ?: "")
                            "accept" -> bridge.accept(call.argument<String>("license") ?: "")
                            "verify" -> bridge.verify(call.argument<String>("license") ?: "")
                            "diagnosticNetworkState" -> if (BuildConfig.DEBUG) mapOf("airplaneMode" to (android.provider.Settings.Global.getInt(contentResolver, android.provider.Settings.Global.AIRPLANE_MODE_ON, 0) == 1)) else null
                            else -> null
                        }
                        handler.post { if (value == null) result.notImplemented() else result.success(value) }
                    } catch (error: Exception) {
                        // Never return/log license bodies, activation codes, keys or proof bytes.
                        handler.post { result.error("activation_storage", "Nao foi possivel validar ou guardar a autorizacao neste aparelho.", null) }
                    }
                }
            }
    }
    override fun onDestroy() { activationExecutor.shutdown(); super.onDestroy() }
}
