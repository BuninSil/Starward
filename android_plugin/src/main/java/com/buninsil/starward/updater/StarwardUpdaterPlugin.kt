package com.buninsil.starward.updater

import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.UsedByGodot
import java.io.File

/**
 * Hands a downloaded APK to the system package installer.
 * GDScript: Engine.get_singleton("StarwardUpdater").installApk(path) -> "" on success, error text otherwise.
 */
class StarwardUpdaterPlugin(godot: Godot) : GodotPlugin(godot) {

    override fun getPluginName() = PLUGIN_NAME

    /** False when the user has not yet allowed this app to install unknown apps (Android 8+). */
    @UsedByGodot
    fun canRequestPackageInstalls(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    /**
     * Starts the system installer for [path] (must be inside cacheDir/updates/).
     * If installs from this app are not allowed yet, Android itself shows the
     * "allow from this source" prompt and then continues with the install.
     */
    @UsedByGodot
    fun installApk(path: String): String {
        return try {
            val file = File(path)
            if (!file.isFile) {
                return "file not found: $path"
            }
            val ctx = activity ?: context
            val uri = FileProvider.getUriForFile(ctx, ctx.packageName + AUTHORITY_SUFFIX, file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, APK_MIME)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(intent)
            Log.i(TAG, "Installer started for $uri")
            ""
        } catch (e: Exception) {
            Log.e(TAG, "installApk failed", e)
            e.toString()
        }
    }

    /**
     * Asks Android for the display's highest refresh rate at the current
     * resolution (apps get 60 Hz by default even on 90/120 Hz screens).
     * Returns that rate in Hz (0 if there is no activity).
     */
    @UsedByGodot
    fun requestHighRefreshRate(): Float {
        val act = activity ?: return 0f
        return try {
            @Suppress("DEPRECATION")
            val display = act.windowManager.defaultDisplay
            val cur = display.mode
            val best = display.supportedModes
                .filter { it.physicalWidth == cur.physicalWidth && it.physicalHeight == cur.physicalHeight }
                .maxByOrNull { it.refreshRate } ?: cur
            act.runOnUiThread {
                val lp = act.window.attributes
                lp.preferredDisplayModeId = best.modeId
                lp.preferredRefreshRate = best.refreshRate
                act.window.attributes = lp
            }
            Log.i(TAG, "Display mode ${best.modeId}: ${best.refreshRate} Hz")
            best.refreshRate
        } catch (e: Exception) {
            Log.e(TAG, "requestHighRefreshRate failed", e)
            0f
        }
    }

    companion object {
        private const val TAG = "StarwardUpdater"
        private const val PLUGIN_NAME = "StarwardUpdater"
        private const val AUTHORITY_SUFFIX = ".starward.updater"
        private const val APK_MIME = "application/vnd.android.package-archive"
    }
}
