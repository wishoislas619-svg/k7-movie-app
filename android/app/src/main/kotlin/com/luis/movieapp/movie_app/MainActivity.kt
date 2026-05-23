package com.luis.movieapp.movie_app

import android.content.Intent
import android.media.audiofx.LoudnessEnhancer
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import cl.puntito.simple_pip_mode.PipCallbackHelperActivityWrapper

class MainActivity : PipCallbackHelperActivityWrapper() {

    private val CHANNEL = "com.luis.movieapp/webview_touch"
    private val INSTALL_CHANNEL = "com.luis.movieapp/install_apk"
    private val AUDIO_BOOST_CHANNEL = "com.luis.movieapp/audio_boost"
    private var loudnessEnhancer: LoudnessEnhancer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Canal existente para WebView touch
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "tapAt" -> {
                        val x = (call.argument<Double>("x") ?: 0.0).toFloat()
                        val y = (call.argument<Double>("y") ?: 0.0).toFloat()
                        val webView = findWebView(window.decorView)
                        if (webView != null) {
                            webView.post {
                                val downTime = SystemClock.uptimeMillis()
                                val eventDown = MotionEvent.obtain(
                                    downTime, downTime,
                                    MotionEvent.ACTION_DOWN, x, y, 0
                                )
                                val eventUp = MotionEvent.obtain(
                                    downTime, downTime + 80L,
                                    MotionEvent.ACTION_UP, x, y, 0
                                )
                                webView.dispatchTouchEvent(eventDown)
                                webView.postDelayed({
                                    webView.dispatchTouchEvent(eventUp)
                                    eventDown.recycle()
                                    eventUp.recycle()
                                }, 80)
                            }
                            result.success(true)
                        } else {
                            result.error("NO_WEBVIEW", "WebView not found in view hierarchy", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Nuevo canal para instalar APK usando FileProvider
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALL_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath == null) {
                            result.error("INVALID_PATH", "filePath is null", null)
                            return@setMethodCallHandler
                        }

                        try {
                            val apkFile = File(filePath)
                            if (!apkFile.exists()) {
                                result.error("FILE_NOT_FOUND", "APK not found at: $filePath", null)
                                return@setMethodCallHandler
                            }

                            val authority = "${applicationContext.packageName}.fileprovider"
                            val apkUri: Uri = FileProvider.getUriForFile(
                                applicationContext,
                                authority,
                                apkFile
                            )

                            val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                                setDataAndType(apkUri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }

                            applicationContext.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_BOOST_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setBoost" -> {
                        val boost = (call.argument<Double>("boost") ?: 1.0).toFloat()
                        try {
                            applyAudioBoost(boost)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("BOOST_ERROR", e.message, null)
                        }
                    }
                    "releaseBoost" -> {
                        releaseAudioBoost()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // Canal para control de PiP (Acciones Nativas y Expandir)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.luis.movieapp/pip_control")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "expandPip" -> {
                        expandActivity()
                        result.success(true)
                    }
                    "updatePipActions" -> {
                        val isPlaying = call.argument<Boolean>("isPlaying") ?: true
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            updatePipActions(isPlaying)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun applyAudioBoost(boost: Float) {
        if (boost <= 1.0f) {
            loudnessEnhancer?.enabled = false
            return
        }

        if (loudnessEnhancer == null) {
            loudnessEnhancer = LoudnessEnhancer(0)
        }

        val targetGainMb = ((20.0 * kotlin.math.log10(boost.toDouble())) * 100.0)
            .toInt()
            .coerceIn(0, 1200)

        loudnessEnhancer?.setTargetGain(targetGainMb)
        loudnessEnhancer?.enabled = true
    }

    private fun releaseAudioBoost() {
        loudnessEnhancer?.enabled = false
        loudnessEnhancer?.release()
        loudnessEnhancer = null
    }

    private fun expandActivity() {
        val intent = Intent(this, MainActivity::class.java)
        intent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        startActivity(intent)
    }

    private fun updatePipActions(isPlaying: Boolean) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val actions = mutableListOf<android.app.RemoteAction>()

        // Acción: Play/Pause (Centro)
        val playPauseIcon = if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val playPauseTitle = if (isPlaying) "Pause" else "Play"
        actions.add(createRemoteAction(playPauseIcon, playPauseTitle, "play_pause", 102))

        val aspectRatio = android.util.Rational(16, 9)
        val params = android.app.PictureInPictureParams.Builder()
            .setActions(actions)
            .setAspectRatio(aspectRatio)
            .build()
        setPictureInPictureParams(params)
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration?) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (isInPictureInPictureMode) {
            // Forzar actualización al entrar para asegurar que los botones estén ahí
            updatePipActions(true) 
        }
    }

    private fun createRemoteAction(iconResId: Int, title: String, action: String, requestCode: Int): android.app.RemoteAction {
        val intent = Intent("com.luis.movieapp.PIP_ACTION").apply {
            putExtra("action", action)
            `package` = packageName
        }
        val pendingIntent = android.app.PendingIntent.getBroadcast(
            this, requestCode, intent, 
            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
        )
        val icon = android.graphics.drawable.Icon.createWithResource(this, iconResId)
        return android.app.RemoteAction(icon, title, title, pendingIntent)
    }

    private val pipActionReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: android.content.Intent?) {
            val action = intent?.getStringExtra("action") ?: return
            // Enviar la acción de vuelta a Flutter para que el controlador responda
            flutterEngine?.let { engine ->
                MethodChannel(engine.dartExecutor.binaryMessenger, "com.luis.movieapp/pip_control")
                    .invokeMethod("onPipAction", action)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val filter = android.content.IntentFilter("com.luis.movieapp.PIP_ACTION")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(pipActionReceiver, filter, android.content.Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(pipActionReceiver, filter)
            }
        }
    }

    override fun onStop() {
        super.onStop()
        try {
            unregisterReceiver(pipActionReceiver)
        } catch (e: Exception) {}
    }

    override fun onDestroy() {
        releaseAudioBoost()
        super.onDestroy()
    }

    private fun findWebView(view: View): WebView? {

        if (view is WebView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                val found = findWebView(view.getChildAt(i))
                if (found != null) return found
            }
        }
        return null
    }
}
