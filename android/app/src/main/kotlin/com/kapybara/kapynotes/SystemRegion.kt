package com.kapybara.kapynotes

import android.content.res.Resources
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Backs the `kapynotes/region` channel: the country this device is set to.
 *
 * Read from the *system* configuration rather than the activity's. Android 13
 * lets a single app be given a language of its own, and an app told to speak
 * Hindi has not moved to India — the phone's own locale list is the one that
 * says where its owner is.
 *
 * Android is the platform where region and language genuinely are one setting,
 * so this usually agrees with what Flutter already reports. It is here so that
 * the Dart side has one question with one answer everywhere; see
 * lib/core/system_region.dart for the platforms where they come apart.
 */
object SystemRegion {
    private const val CHANNEL = "kapynotes/region"

    fun register(messenger: BinaryMessenger): MethodChannel {
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "region" -> result.success(current())
                else -> result.notImplemented()
            }
        }
        return channel
    }

    /** Null where the system names no country, which Dart reads as "use the language". */
    private fun current(): String? {
        val locales = Resources.getSystem().configuration.locales
        if (locales.isEmpty) return null
        return locales.get(0).country.ifEmpty { null }
    }
}
