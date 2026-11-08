package io.github.mizaawa.mewhub

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
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/** Keeps the process running while Flutter consumes active chat response streams. */
class ChatGenerationService : Service() {
    private val conversations = linkedSetOf<String>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onTaskRemoved(rootIntent: Intent?) {
        conversations.clear()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val conversationId = intent?.getStringExtra(EXTRA_CONVERSATION_ID)
        when (intent?.action) {
            ACTION_START -> {
                if (conversationId.isNullOrBlank()) {
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                conversations.add(conversationId)
                startForegroundNotification()
            }

            ACTION_STOP -> {
                if (conversationId != null) conversations.remove(conversationId)
                if (conversations.isEmpty()) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf(startId)
                } else {
                    startForegroundNotification()
                }
            }

            else -> stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    private fun startForegroundNotification() {
        createNotificationChannel()
        val count = conversations.size
        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_mewhub)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(
                if (count == 1) getString(R.string.chat_generation_running)
                else getString(R.string.chat_generations_running, count),
            )
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent())
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, getString(R.string.chat_generation_channel), NotificationManager.IMPORTANCE_LOW),
        )
    }

    private fun openAppIntent(): PendingIntent? {
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(
            this,
            NOTIFICATION_ID,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    companion object {
        private const val ACTION_START = "io.github.mizaawa.mewhub.CHAT_GENERATION_START"
        private const val ACTION_STOP = "io.github.mizaawa.mewhub.CHAT_GENERATION_STOP"
        private const val EXTRA_CONVERSATION_ID = "conversation_id"
        private const val CHANNEL_ID = "chat_generation"
        private const val NOTIFICATION_ID = 9137

        fun start(context: Context, conversationId: String) {
            val intent = Intent(context, ChatGenerationService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_CONVERSATION_ID, conversationId)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context, conversationId: String) {
            val intent = Intent(context, ChatGenerationService::class.java)
                .setAction(ACTION_STOP)
                .putExtra(EXTRA_CONVERSATION_ID, conversationId)
            context.startService(intent)
        }
    }
}
