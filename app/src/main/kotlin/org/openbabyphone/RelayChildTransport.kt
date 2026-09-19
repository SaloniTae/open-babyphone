package org.openbabyphone

import android.content.Context
import android.util.Log
import okhttp3.*
import okio.ByteString
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class RelayChildTransport(
    private val context: Context,
    private val claimActive: () -> Boolean,
    private val frameProvider: () -> ByteArray?,
    private val onParentCountChanged: (Int) -> Unit,
    private val onFailure: (Throwable?) -> Unit
) {
    private var client: OkHttpClient? = null
    @Volatile private var socket: WebSocket? = null

    fun start() {
        val relayUrl = RelayConfig.url(context)
        if (!relayUrl.startsWith("wss://") && !relayUrl.startsWith("ws://")) {
            onFailure(IllegalArgumentException("Invalid relay URL"))
            return
        }
        client = OkHttpClient.Builder()
            .pingInterval(20, TimeUnit.SECONDS)
            .build()

        val sessionId = ChildRelaySession.sessionId(context)
        val url = InternetRelay.buildUrl(
            relayUrl,
            sessionId,
            "child",
            RelayConfig.token(context)
        )

        socket = client!!.newWebSocket(
            Request.Builder().url(url).build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    Log.i(TAG, "Relay connected")
                    onParentCountChanged(1)
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    // The relay forwards parent messages only if a future control
                    // channel is introduced. Audio remains child -> parent.
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    onParentCountChanged(0)
                    if (claimActive()) onFailure(null)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    onParentCountChanged(0)
                    if (claimActive()) onFailure(t)
                }
            }
        )
    }

    fun send(frame: ByteArray, offset: Int, length: Int): Boolean {
        val ws = socket ?: return false
        if (!claimActive()) return false
        return ws.send(ByteString.of(frame.copyOfRange(offset, offset + length)))
    }

    fun stop() {
        socket?.close(1000, "stopping")
        socket = null
        client?.dispatcher?.cancelAll()
        client = null
        onParentCountChanged(0)
    }

    companion object {
        private const val TAG = "RelayChildTransport"
    }
}

object ChildRelaySession {
    private const val PREFS = "internet_relay_child"
    private const val KEY_SESSION = "session"

    fun sessionId(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return prefs.getString(KEY_SESSION, null) ?: InternetRelay.newSessionId().also {
            prefs.edit().putString(KEY_SESSION, it).apply()
        }
    }
}
