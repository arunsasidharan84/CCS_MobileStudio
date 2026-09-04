package com.ccs.mobile_studio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Keeps the app process alive and the CPU awake for the duration of an EEG
 * recording session, so that long recordings (trainNIDRA, ANGEL, adaptiveWM)
 * are not stopped or throttled by Android when the screen turns off, the
 * user switches away from the app, or the device enters Doze / App Standby.
 *
 * Started/stopped from Dart via [MainActivity]'s `ccs/audio` method channel
 * (`startRecordingService` / `stopRecordingService`), which is called from
 * DeviceAwakeService.acquire()/release() whenever SessionManager starts or
 * stops a recording session.
 *
 * This does NOT run any Dart code itself — it simply raises the process
 * importance (foreground service) and holds a partial wake lock so that the
 * existing FlutterEngine/Dart isolate hosted in MainActivity keeps executing
 * BLE callbacks, timers, and file writes in the background.
 */
class RecordingForegroundService : Service() {

    companion object {
        private const val TAG = "RecordingFgService"
        const val ACTION_START = "com.ccs.mobile_studio.action.START_RECORDING"
        const val ACTION_STOP = "com.ccs.mobile_studio.action.STOP_RECORDING"
        private const val CHANNEL_ID = "ccs_recording_channel"
        private const val ALERT_CHANNEL_ID = "ccs_recording_alert_channel"
        private const val NOTIFICATION_ID = 4271
        private const val ALERT_NOTIFICATION_ID = 4272
        private const val WAKE_LOCK_TAG = "ccs_mobile_studio:RecordingWakeLock"

        // Safety-net ceiling so the wake lock can never be held forever even
        // if a release call is somehow dropped (e.g. process death races).
        private const val WAKE_LOCK_TIMEOUT_MS = 12L * 60L * 60L * 1000L // 12 hours
    }

    private var wakeLock: PowerManager.WakeLock? = null

    // True only while this service was started for an active recording
    // session (between ACTION_START and ACTION_STOP). Used to distinguish a
    // genuine mid-recording interruption from an already-stopped service
    // incidentally receiving onTaskRemoved().
    private var isRecordingActive: Boolean = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopRecordingForeground()
                return START_NOT_STICKY
            }
            else -> {
                startRecordingForeground()
                return START_NOT_STICKY
            }
        }
    }

    private fun startRecordingForeground() {
        try {
            createNotificationChannel()
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            acquireWakeLock()
            isRecordingActive = true
            Log.i(TAG, "Recording foreground service started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start recording foreground service: ${e.message}")
        }
    }

    private fun stopRecordingForeground() {
        isRecordingActive = false
        releaseWakeLock()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping foreground: ${e.message}")
        }
        stopSelf()
        Log.i(TAG, "Recording foreground service stopped")
    }

    /**
     * Called by Android when the user removes this app's task from Recents
     * (swipe-away) while our foreground service is still running. Because
     * [android.R.attr.stopWithTask] is false, this service — and therefore
     * the process and its wake lock — survives that action. The Activity and
     * its FlutterEngine/Dart isolate, however, are torn down as part of the
     * same task removal, so no Dart code remains to keep feeding the EDF
     * recorder with new samples.
     *
     * Data captured up to this point is already safe: the native EDF writer
     * flushes and updates the record count after every completed 1-second
     * record, so nothing already written to disk is lost. What *is* lost is
     * any further recording — this can't be resumed headlessly without a
     * much larger architecture change (a Dart background isolate independent
     * of the Activity). Rather than silently going dark, surface a clear,
     * high-priority alert and shut down cleanly instead of holding a wake
     * lock for a session nothing is driving anymore.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (isRecordingActive) {
            Log.w(TAG, "App task removed while recording was active — recording stopped; data captured so far is saved.")
            showInterruptedAlert()
        }
        stopRecordingForeground()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
        lock.setReferenceCounted(false)
        lock.acquire(WAKE_LOCK_TIMEOUT_MS)
        wakeLock = lock
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            Log.e(TAG, "Error releasing wake lock: ${e.message}")
        }
        wakeLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "EEG Recording",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shown while an EEG recording session is in progress"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun createAlertNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(ALERT_CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            ALERT_CHANNEL_ID,
            "Recording Interrupted Alerts",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Alerts when an EEG recording session is unexpectedly interrupted"
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }

    private fun showInterruptedAlert() {
        try {
            createAlertNotificationChannel()
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val contentIntent = launchIntent?.let {
                PendingIntent.getActivity(this, 1, it, pendingIntentFlags)
            }

            val builder = Notification.Builder(this).apply {
                setContentTitle("Recording interrupted")
                setContentText(
                    "CCS Mobile Studio was closed while recording. Data captured so far is saved — reopen the app to verify the file or start a new session."
                )
                setStyle(Notification.BigTextStyle().bigText(
                    "CCS Mobile Studio was closed while recording. Data captured so far is saved — reopen the app to verify the file or start a new session."
                ))
                setSmallIcon(R.mipmap.ic_launcher)
                setAutoCancel(true)
                setDefaults(Notification.DEFAULT_ALL)
                contentIntent?.let { setContentIntent(it) }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    setChannelId(ALERT_CHANNEL_ID)
                }
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(ALERT_NOTIFICATION_ID, builder.build())
        } catch (e: Exception) {
            Log.e(TAG, "Failed to show interrupted-recording alert: ${e.message}")
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntentFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(this, 0, it, pendingIntentFlags)
        }

        val builder = Notification.Builder(this).apply {
            setContentTitle("CCS Mobile Studio")
            setContentText("EEG recording in progress — keep this app open in the background")
            setSmallIcon(R.mipmap.ic_launcher)
            setOngoing(true)
            setOnlyAlertOnce(true)
            contentIntent?.let { setContentIntent(it) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                setChannelId(CHANNEL_ID)
            }
        }
        return builder.build()
    }

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }
}
