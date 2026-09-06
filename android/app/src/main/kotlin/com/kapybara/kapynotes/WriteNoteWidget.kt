package com.kapybara.kapynotes

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * The Write widget: a pencil, the word Write, and one tap back into the note
 * being written.
 *
 * It deliberately shows no note text. A widget that previewed what somebody
 * wrote would have to read the note store, keep itself refreshed, and put
 * that text on a locked phone for anyone holding it to read. Showing only the
 * action costs none of that: this layout never changes, so the widget is
 * drawn once and never updated again.
 */
class WriteNoteWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val views = RemoteViews(context.packageName, R.layout.widget_write_note)
        views.setOnClickPendingIntent(R.id.widget_write_note_root, writeIntent(context))
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    /**
     * Starts the app on its own action, which is the only thing telling it
     * apart from a tap on the icon. `SINGLE_TOP` keeps a running app in place
     * rather than stacking a second copy of the editor on top of the first.
     */
    private fun writeIntent(context: Context): PendingIntent {
        val intent =
            Intent(context, MainActivity::class.java).apply {
                action = MainActivity.ACTION_CONTINUE_WRITING
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
        return PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
