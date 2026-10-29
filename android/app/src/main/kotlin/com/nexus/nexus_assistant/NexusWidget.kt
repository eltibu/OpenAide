package com.nexus.nexus_assistant

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * The home-screen widget: "Ask Nexus" opens a new chat, the mic dictates and
 * the phone starts a voice call, the same ways in as the icon's shortcuts.
 */
class NexusWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = RemoteViews(context.packageName, R.layout.nexus_widget).apply {
            setOnClickPendingIntent(R.id.widget_ask, open(context, "new", 1))
            setOnClickPendingIntent(R.id.widget_dictate, open(context, "dictate", 2))
            setOnClickPendingIntent(R.id.widget_call, open(context, "call", 3))
        }
        for (id in ids) manager.updateAppWidget(id, views)
    }

    private fun open(context: Context, kind: String, code: Int): PendingIntent =
        PendingIntent.getActivity(
            context,
            code,
            Intent(context, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .putExtra(PhoneLaunch.EXTRA, kind)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
}
