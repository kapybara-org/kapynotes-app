package com.kapybara.kapynotes

import android.app.PendingIntent
import android.content.Context
import android.content.Intent

/**
 * The one way a widget starts the app.
 *
 * Naming its own action on the intent is the only thing telling a widget tap
 * apart from a tap on the icon. `SINGLE_TOP` keeps a running app in place
 * rather than stacking a second copy of the editor on top of the first, which
 * is also what puts the tap through `MainActivity.onNewIntent`.
 *
 * The request code is the action's own, so that the three actions never share
 * a `PendingIntent` — `FLAG_UPDATE_CURRENT` rewrites the one it matches, and
 * matching ignores everything this varies.
 */
fun quickActionIntent(context: Context, action: QuickAction): PendingIntent {
    val intent =
        Intent(context, MainActivity::class.java).apply {
            this.action = action.intentAction
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
    return PendingIntent.getActivity(
        context,
        action.ordinal,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
