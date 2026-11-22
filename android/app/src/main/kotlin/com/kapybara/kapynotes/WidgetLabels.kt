package com.kapybara.kapynotes

import android.os.Build
import android.util.SizeF
import android.widget.RemoteViews

/**
 * A widget's words need 72 dp of height under its discs. Android 12 and up
 * let the launcher choose between the two layouts by the space the widget
 * really has, so a short widget shows its discs alone rather than a clipped
 * word. Older launchers can't choose, and get the words.
 */
fun labelledWhenTall(layout: (labelled: Boolean) -> RemoteViews): RemoteViews =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        RemoteViews(mapOf(SizeF(57f, 57f) to layout(false), SizeF(57f, 72f) to layout(true)))
    } else {
        layout(true)
    }
