package com.kapybara.kapynotes

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Bundle
import android.view.View
import android.view.View.MeasureSpec
import android.widget.FrameLayout
import android.widget.RemoteViews
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * The two widgets as a launcher draws them, every size in light and dark, for
 * a reviewer to hold against the Widgets · v2 boards; and every tap on them,
 * followed into the app.
 *
 * tool/ci/android_widget_renders.sh runs these on an emulator and pulls the
 * PNGs they leave in the app's external files. Each render is the provider's
 * own RemoteViews, applied as a launcher applies them, at 2× (the boards'
 * scale) in the light or dark the launcher would be in. Which of a widget's
 * two layouts shows at a given size is the launcher's pick
 * ([labelledWhenTall]), so each is drawn at a size that picks it.
 */
class WidgetRendersTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val app: Context = instrumentation.targetContext
    private val wideCells =
        listOf(
            R.id.widget_quick_actions_first,
            R.id.widget_quick_actions_second,
            R.id.widget_quick_actions_third,
        )

    @Test
    fun rendersEveryWidgetInLightAndDark() {
        val out = File(app.getExternalFilesDir(null), "widget-renders")
        out.deleteRecursively()
        out.mkdirs()
        for (dark in listOf(false, true)) {
            val context = atBoardScale(dark)
            val mode = if (dark) "dark" else "light"
            val squares =
                QuickAction.entries.map { action ->
                    val name = "quick-action-${action.name.lowercase()}"
                    val taps = listOf(R.id.widget_quick_action_root to action)
                    fun square(labelled: Boolean, sizeDp: Int) =
                        draw(context, WriteNoteWidget.layoutFor(context, action, labelled), sizeDp, sizeDp, taps)
                    save(out, "$name-short-$mode", square(false, 57))
                    square(true, 80).also { save(out, "$name-$mode", it) }
                }
            val taps = wideCells.zip(QuickAction.entries)
            fun wide(labelled: Boolean, widthDp: Int, heightDp: Int) =
                draw(context, QuickActionsWidget.layout(context, labelled), widthDp, heightDp, taps)
            val threeByOne = wide(true, 264, 80)
            save(out, "quick-actions-$mode", threeByOne)
            save(out, "quick-actions-short-$mode", wide(false, 180, 57))
            save(out, "quick-actions-wider-$mode", wide(true, 352, 80))
            save(out, "android-$mode", board(dark, squares, threeByOne))
        }
    }

    @Test
    fun everyTapOpensItsActionInTheApp() {
        val opened = LinkedBlockingQueue<String>()
        val closed = LinkedBlockingQueue<Activity>()
        val watcher =
            object : Application.ActivityLifecycleCallbacks {
                override fun onActivityPreCreated(activity: Activity, savedInstanceState: Bundle?) {
                    if (activity is MainActivity) opened.add(activity.intent.action.orEmpty())
                }

                override fun onActivityPostCreated(activity: Activity, savedInstanceState: Bundle?) {
                    if (activity is MainActivity) activity.finish()
                }

                override fun onActivityDestroyed(activity: Activity) {
                    if (activity is MainActivity) closed.add(activity)
                }

                override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}

                override fun onActivityStarted(activity: Activity) {}

                override fun onActivityResumed(activity: Activity) {}

                override fun onActivityPaused(activity: Activity) {}

                override fun onActivityStopped(activity: Activity) {}

                override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
            }
        val application = app.applicationContext as Application
        application.registerActivityLifecycleCallbacks(watcher)
        try {
            for (labelled in listOf(true, false)) {
                val taps =
                    QuickAction.entries.map {
                        WriteNoteWidget.layoutFor(app, it, labelled) to R.id.widget_quick_action_root
                    } + wideCells.map { QuickActionsWidget.layout(app, labelled) to it }
                val expected = QuickAction.entries + QuickAction.entries
                for ((tap, action) in taps.zip(expected)) {
                    val (views, target) = tap
                    instrumentation.runOnMainSync {
                        val host = FrameLayout(app)
                        host.addView(views.apply(app, host))
                        host.findViewById<View>(target).performClick()
                    }
                    assertEquals(action.intentAction, opened.poll(60, TimeUnit.SECONDS))
                    assertNotNull("The app didn't close", closed.poll(60, TimeUnit.SECONDS))
                }
            }
        } finally {
            application.unregisterActivityLifecycleCallbacks(watcher)
        }
    }

    /** At 2×, the boards' scale, in the light or dark the launcher would be in. */
    private fun atBoardScale(dark: Boolean): Context {
        val config = Configuration(app.resources.configuration)
        val night = if (dark) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        config.uiMode = (config.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or night
        config.densityDpi = 320
        config.fontScale = 1f
        return app.createConfigurationContext(config)
    }

    /**
     * [views] applied as a launcher applies them, at [widthDp] × [heightDp],
     * once each of [taps] is shown to carry its action's tap and name.
     */
    private fun draw(
        context: Context,
        views: RemoteViews,
        widthDp: Int,
        heightDp: Int,
        taps: List<Pair<Int, QuickAction>>,
    ): Bitmap {
        val density = context.resources.displayMetrics.density
        val width = (widthDp * density).roundToInt()
        val height = (heightDp * density).roundToInt()
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val found = mutableListOf<Pair<Boolean, CharSequence?>>()
        instrumentation.runOnMainSync {
            val host = FrameLayout(context)
            host.addView(views.apply(context, host))
            host.measure(
                MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
                MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY),
            )
            host.layout(0, 0, width, height)
            for ((id, _) in taps) {
                val target = host.findViewById<View>(id)
                found += target.hasOnClickListeners() to target.contentDescription
            }
            host.draw(Canvas(bitmap))
        }
        for ((tap, action) in found.zip(taps.map { it.second })) {
            assertEquals(true to app.getString(action.label), tap.first to tap.second?.toString())
        }
        return bitmap
    }

    /** The boards' own layout: the three squares over the wide one. */
    private fun board(dark: Boolean, squares: List<Bitmap>, wide: Bitmap): Bitmap {
        val board = Bitmap.createBitmap(420 * 2, 300 * 2, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(board)
        canvas.drawColor(if (dark) 0xFF0F0E0C.toInt() else 0xFFD8D2C4.toInt())
        squares.forEachIndexed { i, square ->
            canvas.drawBitmap(square, (32 + i * 104) * 2f, 56 * 2f, null)
        }
        canvas.drawBitmap(wide, 32 * 2f, 188 * 2f, null)
        return board
    }

    private fun save(out: File, name: String, bitmap: Bitmap) {
        File(out, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
