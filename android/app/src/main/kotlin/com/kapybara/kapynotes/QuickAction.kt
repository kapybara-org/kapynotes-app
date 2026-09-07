package com.kapybara.kapynotes

import android.content.Context

/**
 * The three things a tap on a widget can ask the app for.
 *
 * Each is an intent action and nothing else. A widget knows no note, holds no
 * text, and reads no store: it names which of three doors the user came
 * through and lets the app decide what is behind it. That is what lets every
 * widget here be drawn once and never updated again, and what keeps a locked
 * phone from showing anybody's writing.
 */
enum class QuickAction(
    /** What the widget names on the intent that starts [MainActivity]. */
    val intentAction: String,
    /** The `LaunchIntent` Dart knows this by — lib/core/quick_capture.dart. */
    val launchName: String,
    val label: Int,
    val icon: Int,
) {
    /**
     * Named CONTINUE_WRITING, and staying that way. It is the action the
     * first version of this widget shipped with, and a widget already sitting
     * on somebody's Home Screen holds a `PendingIntent` built around it.
     */
    WRITE(
        "com.kapybara.kapynotes.CONTINUE_WRITING",
        "continueWriting",
        R.string.widget_action_write,
        R.drawable.ic_write_note,
    ),
    DICTATE(
        "com.kapybara.kapynotes.DICTATE",
        "dictate",
        R.string.widget_action_dictate,
        R.drawable.ic_dictate,
    ),
    CAPTURE(
        "com.kapybara.kapynotes.CAPTURE",
        "capture",
        R.string.widget_action_capture,
        R.drawable.ic_capture,
    ),
    ;

    companion object {
        /**
         * What a square widget does until somebody says otherwise: what the
         * widget did when Write was the only thing it could do.
         */
        val DEFAULT = WRITE

        fun ofIntentAction(action: String?): QuickAction? =
            entries.firstOrNull { it.intentAction == action }

        fun named(name: String?): QuickAction? = entries.firstOrNull { it.name == name }
    }
}

/**
 * Which action each placed square widget was configured to do.
 *
 * One small preferences file, written by the configuration screen and read by
 * the provider. It is keyed by widget id because two of the same widget on
 * the same Home Screen are two different questions — one may be Dictate and
 * the other Capture.
 */
object WidgetActions {
    private const val FILE = "com.kapybara.kapynotes.widget_actions"

    fun of(context: Context, appWidgetId: Int): QuickAction =
        QuickAction.named(prefs(context).getString(key(appWidgetId), null)) ?: QuickAction.DEFAULT

    fun put(context: Context, appWidgetId: Int, action: QuickAction) {
        prefs(context).edit().putString(key(appWidgetId), action.name).apply()
    }

    /** Called when a widget is removed, so the file does not grow forever. */
    fun forget(context: Context, appWidgetIds: IntArray) {
        val edit = prefs(context).edit()
        for (id in appWidgetIds) edit.remove(key(id))
        edit.apply()
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    private fun key(appWidgetId: Int) = "action.$appWidgetId"
}
