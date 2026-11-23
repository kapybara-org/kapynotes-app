package com.kapybara.kapynotes

import android.content.Context
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.install.model.UpdateAvailability
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Backs the `kapynotes/store_update` channel: whether Google Play has a newer
 * version for this install, and that version's code.
 *
 * Play answers only for a copy it installed. A sideloaded or debug build, or
 * a phone without Play, fails the request, and Dart reads that as no answer
 * rather than as up to date. Play names a release by its version code alone,
 * so Dart finds the version number in the changelog.
 */
object StoreUpdate {
    private const val CHANNEL = "kapynotes/store_update"

    fun register(messenger: BinaryMessenger, context: Context) {
        val manager by lazy { AppUpdateManagerFactory.create(context.applicationContext) }
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method != "check") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            manager.appUpdateInfo
                .addOnSuccessListener { info ->
                    result.success(
                        when (info.updateAvailability()) {
                            UpdateAvailability.UPDATE_AVAILABLE -> mapOf(
                                "available" to true,
                                "versionCode" to info.availableVersionCode(),
                            )
                            UpdateAvailability.UPDATE_NOT_AVAILABLE -> mapOf("available" to false)
                            else -> null
                        },
                    )
                }
                .addOnFailureListener { result.success(null) }
        }
    }
}
