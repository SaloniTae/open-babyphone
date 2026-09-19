package org.openbabyphone

import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Socket
import java.net.SocketAddress
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class WebSocketByteStreamSocket(
    private val sessionId: String,
    private val role: Role
) : Socket() {
    enum class Role { CHILD, PARENT }

    companion object {
        private const val TAG = "RelaySocket"
        private const val MAX_QUEUED_BYTES = 512 * 1024
        private val client = OkHttpClient.Builder()
            .pingInterval(20, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .build()
    }

    private val opened = CountDownLatch(1)
    private val closed = CountDownLatch(1)
    private val lock = Object()
    private val chunks = ArrayDeque<ByteArray>()
    private var chunkOffset = 0
    private var queuedBytes = 0
    private var failure: IOException? = null
    private var socketSoTimeoutMs = 0
    private var webSocket: WebSocket? = null
    private val isClosed = AtomicBoolean(false)

    private val input = object : InputStream() {
        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xff
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
            require(offset >= 0 && length >= 0 && offset <= buffer.size - length)
            if (length == 0) return 0
            synchronized(lock) {
                while (queuedBytes == 0 && failure == null && !isClosed.get()) {
                    waitForData()
                }
                if (queuedBytes == 0) {
                    failure?.let { throw it }
                    return -1
                }
                var copied = 0
                while (copied < length && chunks.isNotEmpty()) {
                    val chunk = chunks.first()
                    val available = chunk.size - chunkOffset
                    val take = minOf(length - copied, available)
                    chunk.copyInto(buffer, offset + copied, chunkOffset, chunkOffset + take)
                    copied += take
                    chunkOffset += take
                    queuedBytes -= take
                    if (chunkOffset == chunk.size) {
                        chunks.removeFirst()
                        chunkOffset = 0
                    }
                }
                return copied
            }
        }

        override fun available(): Int = synchronized(lock) { queuedBytes }

        override fun close() {
            this@WebSocketByteStreamSocket.close()
        }
    }

    private val output = object : OutputStream() {
        override fun write(value: Int) {
            write(byteArrayOf(value.toByte()))
        }

        override fun write(buffer: ByteArray, offset: Int, length: Int) {
            require(offset >= 0 && length >= 0 && offset <= buffer.size - length)
            if (length == 0) return
            val ws = synchronized(lock) {
                if (isClosed.get()) throw IOException("Relay socket is closed")
                webSocket ?: throw IOException("Relay WebSocket is not open")
            }
            if (!ws.send(ByteString.of(buffer, offset, length))) {
                throw IOException("Relay WebSocket rejected binary message")
            }
        }
    }

    private fun waitForData() {
        val timeout = socketSoTimeoutMs
        if (timeout <= 0) {
            try {
                lock.wait()
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                throw IOException("Interrupted while waiting for relay data", e)
            }
            return
        }
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeout.toLong())
        var remaining = deadline - System.nanoTime()
        while (remaining > 0L && queuedBytes == 0 && failure == null && !isClosed.get()) {
            try {
                val millis = TimeUnit.NANOSECONDS.toMillis(remaining).coerceAtLeast(1L)
                val nanos = (remaining - TimeUnit.MILLISECONDS.toNanos(millis)).toInt().coerceIn(0, 999_999)
                lock.wait(millis, nanos)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                throw IOException("Interrupted while waiting for relay data", e)
            }
            remaining = deadline - System.nanoTime()
        }
        if (queuedBytes == 0 && failure == null && !isClosed.get()) {
            throw java.net.SocketTimeoutException("Relay socket read timed out")
        }
    }

    override fun connect(endpoint: SocketAddress?, timeout: Int) {
        synchronized(lock) {
            if (webSocket != null || isClosed.get()) throw IOException("Relay socket already used")
        }
        val request = Request.Builder()
            .url("${RelayConfig.WSS_ENDPOINT}?session=$sessionId&role=${role.name.lowercase()}")
            .build()
        webSocket = client.newWebSocket(request, listener)
        if (!opened.await(timeout.coerceAtLeast(1).toLong(), TimeUnit.MILLISECONDS)) {
            close()
            throw java.net.SocketTimeoutException("Timed out opening relay WebSocket")
        }
        synchronized(lock) {
            failure?.let { throw it }
            if (isClosed.get()) throw IOException("Relay WebSocket closed while opening")
        }
    }

    override fun getInputStream(): InputStream = input
    override fun getOutputStream(): OutputStream = output

    override fun setSoTimeout(timeout: Int) {
        require(timeout >= 0)
        synchronized(lock) { socketSoTimeoutMs = timeout }
    }

    override fun getSoTimeout(): Int = synchronized(lock) { socketSoTimeoutMs }

    override fun close() {
        if (!isClosed.compareAndSet(false, true)) return
        synchronized(lock) {
            if (failure == null) failure = IOException("Relay socket closed")
            chunks.clear()
            chunkOffset = 0
            queuedBytes = 0
            lock.notifyAll()
        }
        webSocket?.close(1000, "closed")
        closed.countDown()
    }

    override fun isClosed(): Boolean = isClosed.get()
    override fun isConnected(): Boolean = webSocket != null && !isClosed.get()

    private val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            synchronized(lock) {
                this@WebSocketByteStreamSocket.webSocket = webSocket
                lock.notifyAll()
            }
            opened.countDown()
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            val data = bytes.toByteArray()
            synchronized(lock) {
                if (isClosed.get()) return
                if (queuedBytes + data.size > MAX_QUEUED_BYTES) {
                    failure = IOException("Relay receive buffer overflow")
                    isClosed.set(true)
                    lock.notifyAll()
                    webSocket.close(1009, "receive buffer overflow")
                    return
                }
                chunks.addLast(data)
                queuedBytes += data.size
                lock.notifyAll()
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            synchronized(lock) {
                if (failure == null) failure = if (t is IOException) t else IOException("Relay WebSocket failed", t)
                isClosed.set(true)
                lock.notifyAll()
            }
            opened.countDown()
            closed.countDown()
            Log.w(TAG, "Relay WebSocket failure for $role", t)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(code, reason)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            synchronized(lock) {
                isClosed.set(true)
                if (failure == null) failure = IOException("Relay WebSocket closed: $code $reason")
                lock.notifyAll()
            }
            closed.countDown()
        }
    }
}
