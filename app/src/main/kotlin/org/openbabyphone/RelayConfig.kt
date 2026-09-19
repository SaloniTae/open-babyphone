package org.openbabyphone

import android.content.Context

object RelayConfig {
    private const val PREFS = "internet_relay"
    private const val KEY_URL = "url"
    private const val KEY_TOKEN = "token"

    private const val DEFAULT_URL = BuildConfig.DEFAULT_RELAY_URL
    private const val DEFAULT_TOKEN = BuildConfig.DEFAULT_RELAY_TOKEN

    fun url(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_URL, DEFAULT_URL) ?: DEFAULT_URL

    fun token(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_TOKEN, DEFAULT_TOKEN) ?: DEFAULT_TOKEN

    fun configure(context: Context, url: String, token: String) {
        require(url.startsWith("wss://"))
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_URL, url.removeSuffix("/"))
            .putString(KEY_TOKEN, token)
            .apply()
    }
}
