package com.luis.movieapp.movie_app

import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.luis.movieapp/webview_touch"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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
