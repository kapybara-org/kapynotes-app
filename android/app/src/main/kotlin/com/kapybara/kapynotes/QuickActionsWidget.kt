package com.kapybara.kapynotes

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews

/**
 * The wide widget: all three actions at once, side by side.
 *
 * Three tap targets on one widget rather than three widgets on the Home
 * Screen. Each cell carries its own `PendingIntent`, so the app is told which
 * of the three was pressed the same way the square widget tells it.
 *
 * Nothing here is configured and nothing here changes, so it is drawn once
 * and never updated again.
 */
class QuickActionsWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        val views = RemoteViews(context.packageName, R.layout.widget_quick_actions)
        for ((cell, action) in cells.zip(QuickAction.entries)) {
            views.setImageViewResource(cell.icon, action.icon)
            views.setTextViewText(cell.label, context.getString(action.label))
            views.setContentDescription(cell.root, context.getString(action.label))
            views.setOnClickPendingIntent(cell.root, quickActionIntent(context, action))
        }
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    private data class Cell(val root: Int, val icon: Int, val label: Int)

    private val cells =
        listOf(
            Cell(
                R.id.widget_quick_actions_first,
                R.id.widget_quick_actions_first_icon,
                R.id.widget_quick_actions_first_label,
            ),
            Cell(
                R.id.widget_quick_actions_second,
                R.id.widget_quick_actions_second_icon,
                R.id.widget_quick_actions_second_label,
            ),
            Cell(
                R.id.widget_quick_actions_third,
                R.id.widget_quick_actions_third_icon,
                R.id.widget_quick_actions_third_label,
            ),
        )
}
