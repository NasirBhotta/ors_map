package com.example.ors_map_test

import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ors_map_test/api_keys"
        ).setMethodCallHandler { call, result ->
            if (call.method != "getApiKeys") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            val appInfo = packageManager.getApplicationInfo(
                packageName,
                PackageManager.GET_META_DATA
            )
            val metadata = appInfo.metaData
            result.success(
                mapOf(
                    "mapboxAccessToken" to metadata.getString("MAPBOX_ACCESS_TOKEN", ""),
                    "googleMapsApiKey" to metadata.getString(
                        "com.google.android.geo.API_KEY",
                        ""
                    )
                )
            )
        }
    }
}
