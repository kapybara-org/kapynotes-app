package com.kapybara.kapynotes

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.ImageView
import android.widget.TextView

/**
 * What the square widget asks when it is placed, and again whenever somebody
 * reconfigures it: which of the three actions is this one?
 *
 * Plain Android views and a dialog theme, deliberately. Starting the Flutter
 * engine to draw three rows would put a second copy of the app in memory
 * behind the Home Screen, and take long enough doing it that the launcher
 * would show a blank dialog first.
 *
 * On Android 12 and up the widget is `configuration_optional`, so this is not
 * in the way of placing one: a widget dropped on the Home Screen is a Write
 * widget immediately, and this is only reached by choosing to change it.
 */
class QuickActionConfigureActivity : Activity() {
    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Backing out of this must leave nothing behind, so the cancelled
        // answer is given before anything else can go wrong.
        setResult(RESULT_CANCELED)

        appWidgetId =
            intent?.extras?.getInt(
                AppWidgetManager.EXTRA_APPWIDGET_ID,
                AppWidgetManager.INVALID_APPWIDGET_ID,
            ) ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        setContentView(R.layout.activity_quick_action_configure)
        val chosen = WidgetActions.of(this, appWidgetId)
        for (action in QuickAction.entries) {
            bind(findViewById(rowId(action)), action, checked = action == chosen)
        }
    }

    private fun bind(row: View, action: QuickAction, checked: Boolean) {
        row.findViewById<ImageView>(R.id.quick_action_row_icon).setImageResource(action.icon)
        row.findViewById<TextView>(R.id.quick_action_row_label).setText(action.label)
        row.findViewById<View>(R.id.quick_action_row_tick).visibility =
            if (checked) View.VISIBLE else View.INVISIBLE
        row.contentDescription = getString(action.label)
        row.setOnClickListener { choose(action) }
    }

    /**
     * Saves the choice, draws the widget, and hands the launcher back the id
     * it asked about.
     *
     * Drawing it here is not belt and braces: a widget that goes through a
     * configuration activity is never sent the first `APPWIDGET_UPDATE`, so
     * this is the only thing standing between the user and an empty square.
     */
    private fun choose(action: QuickAction) {
        WidgetActions.put(this, appWidgetId, action)
        AppWidgetManager.getInstance(this)
            .updateAppWidget(appWidgetId, WriteNoteWidget.viewsFor(this, action))
        setResult(
            RESULT_OK,
            Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId),
        )
        finish()
    }

    private fun rowId(action: QuickAction): Int =
        when (action) {
            QuickAction.WRITE -> R.id.quick_action_choice_write
            QuickAction.DICTATE -> R.id.quick_action_choice_dictate
            QuickAction.CAPTURE -> R.id.quick_action_choice_capture
        }
}
