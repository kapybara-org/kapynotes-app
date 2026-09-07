package com.kapybara.kapynotes

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews

/**
 * The square widget: one cell, one action, one tap into the note being
 * written.
 *
 * Which action is [WidgetActions.of] the widget — Write unless the person who
 * placed it chose otherwise in [QuickActionConfigureActivity]. The class name
 * is the one this shipped as when Write was all it did, and has to stay: the
 * launcher files a placed widget under the provider's component name, and
 * renaming it would strand every widget already on a Home Screen.
 *
 * It deliberately shows no note text. A widget that previewed what somebody
 * wrote would have to read the note store, keep itself refreshed, and put
 * that text on a locked phone for anyone holding it to read. Showing only the
 * action costs none of that: this layout changes only when the action does,
 * so the widget is drawn once and then left alone.
 */
class WriteNoteWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, viewsFor(context, WidgetActions.of(context, id)))
        }
    }

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        WidgetActions.forget(context, appWidgetIds)
    }

    companion object {
        /** Shared with the configuration screen, which draws the first one. */
        fun viewsFor(context: Context, action: QuickAction): RemoteViews =
            RemoteViews(context.packageName, R.layout.widget_quick_action).apply {
                setImageViewResource(R.id.widget_quick_action_icon, action.icon)
                setTextViewText(
                    R.id.widget_quick_action_label,
                    context.getString(action.label),
                )
                setContentDescription(
                    R.id.widget_quick_action_root,
                    context.getString(action.label),
                )
                setOnClickPendingIntent(
                    R.id.widget_quick_action_root,
                    quickActionIntent(context, action),
                )
            }
    }
}
