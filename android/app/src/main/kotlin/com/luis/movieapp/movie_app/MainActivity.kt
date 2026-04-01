package com.luis.movieapp.movie_app

import android.content.Intent
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

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.luis.movieapp/webview_touch"
    private val INSTALL_CHANNEL = "com.luis.movieapp/install_apk"

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
