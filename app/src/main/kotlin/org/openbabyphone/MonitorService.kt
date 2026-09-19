package org.openbabyphone

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdManager.RegistrationListener
import android.net.nsd.NsdServiceInfo
import android.os.Binder
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.openbabyphone.BuildConfig
import org.openbabyphone.audio.AudioFrameTiming
import org.openbabyphone.audio.FrameCodec
import org.openbabyphone.audio.AudioCaptureSource
import org.openbabyphone.audio.createAudioCaptureSource
import org.openbabyphone.service.MonitorServiceRepository
import org.openbabyphone.service.MonitorSessionError
import org.openbabyphone.service.MonitorSessionState
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

internal class MonitorFrameSequence {
    private var nextSequence = 0
    fun current(): Int = nextSequence
    fun take(clientCount: Int): Int? {
        require(clientCount >= 0)
        if (clientCount == 0) return null
        check(nextSequence < Int.MAX_VALUE) { "Stream sequence space exhausted" }
        return nextSequence++
    }
    fun reset() { nextSequence = 0 }
}

class MonitorService : Service() {
    private val binder: IBinder = MonitorBinder()
    private lateinit var nsdManager: NsdManager
    private lateinit var childIdentityStore: ChildDeviceIdentityStore
    private var registrationListener: RegistrationListener? = null
    private var currentSocket: ServerSocket? = null
    @Volatile private var currentAuthenticatingSocket: Socket? = null
    private val authenticatingSockets = ConcurrentHashMap.newKeySet<Socket>()
    private val handshakeExecutor = BoundedHandshakeExecutor()
    @Volatile private var connectionToken: Any? = null
    private var currentPort = ConnectionConstants.DEFAULT_PORT
    private lateinit var notificationManager: NotificationManager
    private var monitorThread: Thread? = null
    private var audioProducerThread: Thread? = null
    @Volatile private var isStreaming = false
    private val streamFrameLock = ReentrantLock()
    private val sessionStateLock = Any()
    private val workerGeneration = WorkerGeneration()
    @Volatile private var activeWorkerClaim: WorkerClaim? = null
    private val redeliveryTracker = ServiceRedeliveryTracker()
    @Volatile private var currentCaptureSource: AudioCaptureSource? = null
    @Volatile private var relaySocket: WebSocket? = null
    private var relayClient: OkHttpClient? = null
    private var relayConnected = false
    private var relaySessionId = ""

    private var pairingCodeSnapshot: String = ""
    private var streamSessionId: ByteArray? = null
    private var streamBaseKey: ByteArray? = null
    private var streamKey: ByteArray? = null
    private var streamKdfSalt: ByteArray? = null
    private val frameSequence = MonitorFrameSequence()
    @Volatile private var microphoneGain: Float = 1.0f
    private var prefsListener: SharedPreferences.OnSharedPreferenceChangeListener? = null

    private val pairingCode: String
        get() = pairingCodeSnapshot

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nsdManager = getSystemService(NSD_SERVICE) as NsdManager
        childIdentityStore = ChildDeviceIdentityStore(this)
        relayClient = OkHttpClient.Builder().pingInterval(20, TimeUnit.SECONDS).build()
        currentPort = ConnectionConstants.DEFAULT_PORT
        registerMicrophonePrefsListener()
    }

    override fun onStartCommand(intent: Intent, flags: Int, startId: Int): Int {
        val redelivered = flags and START_FLAG_REDELIVERY != 0
        val claim = synchronized(sessionStateLock) {
            workerGeneration.claim(startId).also {
                activeWorkerClaim = it
                redeliveryTracker.record(it, redelivered)
                connectionToken = null
                isStreaming = false
            }
        }
        retireSessionWorkers()
        return try {
            startMonitoringCommand(claim)
        } catch (exception: RuntimeException) {
            Log.e(TAG, "Failed to start monitoring service", exception)
            MonitorServiceRepository.updateError(
                MonitorSessionError.Startup,
                getString(R.string.monitoring_start_failed)
            )
            stopSelfResult(claim.startId)
            START_NOT_STICKY
        }
    }

    private fun startMonitoringCommand(claim: WorkerClaim): Int {
        pairingCodeSnapshot = PairingSettings.load(this).pairingCode
        microphoneGain = MicrophoneSensitivityPreferences.read(this).gain
        createNotificationChannel()
        ServiceCompat.startForeground(this, ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        clientManagerSetupForRelay(claim)
        startMonitorThread(claim)
        return START_REDELIVER_INTENT
    }

    private fun clientManagerSetupForRelay(claim: WorkerClaim) {
        // Local LAN clients still use the existing ClientManager. Internet mode uses
        // the WebSocket relay and does not expose the local listening socket.
        if (BuildConfig.DEFAULT_RELAY_URL.isBlank() ||
            BuildConfig.DEFAULT_RELAY_URL.contains("YOUR-DUCKDNS-HOST")
        ) return
        val url = InternetRelay.buildUrl(
            BuildConfig.DEFAULT_RELAY_URL,
            ChildRelaySession.sessionId(this),
            "child",
            BuildConfig.DEFAULT_RELAY_TOKEN
        )
        relaySessionId = ChildRelaySession.sessionId(this)
        relayClient?.newWebSocket(
            Request.Builder().url(url).build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: okhttp3.Response) {
                    synchronized(sessionStateLock) {
                        if (!isWorkerActive(claim)) {
                            webSocket.close(1000, "inactive")
                            return
                        }
                        relaySocket = webSocket
                        relayConnected = true
                        MonitorServiceRepository.updateSessionState(MonitorSessionState.WaitingForParent)
                    }
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    // Parent-to-child control can be added later.
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    relayConnected = false
                    if (isWorkerActive(claim)) MonitorServiceRepository.updateSessionState(MonitorSessionState.NoNetwork)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: okhttp3.Response?) {
                    relayConnected = false
                    if (isWorkerActive(claim)) MonitorServiceRepository.updateSessionState(MonitorSessionState.NoNetwork)
                }
            }
        )
    }

    private fun startMonitorThread(claim: WorkerClaim) {
        streamFrameLock.lock()
        try {
            streamBaseKey?.fill(0); streamKey?.fill(0)
            streamBaseKey = null; streamKey = null
            streamSessionId = null; streamKdfSalt = null
        } finally { streamFrameLock.unlock() }

        val currentToken = Any()
        synchronized(sessionStateLock) {
            if (!workerGeneration.isCurrent(claim)) return
            connectionToken = currentToken
        }

        monitorThread = Thread {
            val sessionId = CryptoHelper.generateSessionId()
            val kdfSalt = ensureKdfSalt()
            val baseKey = CryptoHelper.deriveKey(pairingCode, kdfSalt)
            val identity = childIdentityStore.identity
            val keyContext = Handshake.streamKeyContext(
                Handshake.createChildHello(identity, sessionId, kdfSalt, ByteArray(CryptoHelper.CHALLENGE_SIZE))
            )
            val derivedStreamKey = CryptoHelper.deriveStreamKey(baseKey, keyContext)
            streamFrameLock.lock()
            try {
                if (!isWorkerActive(claim) || connectionToken !== currentToken) {
                    baseKey.fill(0); derivedStreamKey.fill(0); return@Thread
                }
                streamSessionId = sessionId
                streamKdfSalt = kdfSalt
                streamBaseKey = baseKey
                streamKey = derivedStreamKey
                frameSequence.reset()
            } finally { streamFrameLock.unlock() }

            startAudioProducer(claim)

            while (isWorkerActive(claim) && connectionToken === currentToken) {
                if (BuildConfig.DEFAULT_RELAY_URL.isNotBlank() &&
                    !BuildConfig.DEFAULT_RELAY_URL.contains("YOUR-DUCKDNS-HOST")
                ) {
                    while (isWorkerActive(claim) && connectionToken === currentToken) {
                        Thread.sleep(250)
                    }
                    break
                }

                // Existing local-network server path remains available when no relay
                // URL has been configured.
                val serverSocket = try {
                    ServerSocket().apply {
                        reuseAddress = true
                        bind(InetSocketAddress(currentPort))
                    }
                } catch (e: IOException) {
                    currentPort++
                    continue
                }
                serverSocket.use {
                    val owns = synchronized(sessionStateLock) {
                        if (!isWorkerActive(claim) || connectionToken !== currentToken) false
                        else { currentSocket = it; true }
                    }
                    if (!owns) return@use
                    registerService(it.localPort, claim)
                    while (isWorkerActive(claim) && connectionToken === currentToken) {
                        val socket = try { it.accept() } catch (_: IOException) { continue }
                        dispatchParentHandshake(socket, claim)
                    }
                }
            }
        }.also {
            synchronized(sessionStateLock) {
                if (isWorkerActive(claim)) it.start()
            }
        }
    }

    private fun startAudioProducer(claim: WorkerClaim) {
        val canStart = synchronized(sessionStateLock) {
            if (!isWorkerActive(claim) || isStreaming) false else {
                isStreaming = true
                MonitorServiceRepository.updateSessionState(MonitorSessionState.Starting)
                true
            }
        }
        if (!canStart) return

        audioProducerThread = Thread {
            val audioSource = audioCaptureFactory() ?: run {
                stopStreamingIfCurrent(claim)
                handleAudioProducerFailure(MonitorSessionError.AudioCapture, claim)
                return@Thread
            }
            val pcmBuffer = ShortArray(AudioFrameTiming.FRAME_SAMPLES)
            val ulawBuffer = ByteArray(AudioFrameTiming.FRAME_SAMPLES)
            val frameBuffer = ByteArray(FrameCodec.MAX_FRAME_SIZE)
            val sessionStartTime = SystemClock.elapsedRealtime()
            var lastHeartbeatTime = 0L

            try {
                audioSource.start()
                currentCaptureSource = audioSource
                while (isStreaming && isWorkerActive(claim) && !Thread.currentThread().isInterrupted) {
                    var capturedSamples = 0
                    while (capturedSamples < AudioFrameTiming.FRAME_SAMPLES) {
                        val read = audioSource.read(pcmBuffer, capturedSamples, AudioFrameTiming.FRAME_SAMPLES - capturedSamples)
                        if (read <= 0) break
                        capturedSamples += read
                    }
                    if (capturedSamples != AudioFrameTiming.FRAME_SAMPLES) continue

                    val gain = microphoneGain
                    if (gain > 1.0f) MicrophoneSensitivity.applyGain(pcmBuffer, capturedSamples, gain)

                    val encoded = AudioCodecDefines.CODEC.encode(pcmBuffer, capturedSamples, ulawBuffer, 0)
                    if (encoded <= 0) continue

                    streamFrameLock.lock()
                    try {
                        val key = streamKey ?: continue
                        val session = streamSessionId ?: continue
                        val timestampMs = (SystemClock.elapsedRealtime() - sessionStartTime).toInt()
                        val sequence = frameSequence.take(1) ?: continue
                        val frameLength = FrameCodec.encodeFrameInto(
                            ulawBuffer, 0, encoded, sequence, timestampMs, key, session, frameBuffer
                        )
                        val relay = relaySocket
                        if (relayConnected && relay != null) {
                            relay.send(ByteString.of(frameBuffer.copyOf(frameLength)))
                        }
                        val currentTime = SystemClock.elapsedRealtime()
                        if (currentTime - lastHeartbeatTime >= AudioCodecDefines.HEARTBEAT_INTERVAL_MS) {
                            val heartbeatSequence = frameSequence.take(1)
                            if (heartbeatSequence != null) {
                                val heartbeatLength = FrameCodec.encodeHeartbeatInto(
                                    heartbeatSequence, timestampMs, key, session, frameBuffer
                                )
                                if (relayConnected) relay?.send(ByteString.of(frameBuffer.copyOf(heartbeatLength)))
                                lastHeartbeatTime = currentTime
                            }
                        }
                    } finally { streamFrameLock.unlock() }
                }
            } finally {
                try { audioSource.stop() } catch (_: Exception) {}
                audioSource.release()
                currentCaptureSource = null
                isStreaming = false
            }
        }.also { it.start() }
    }

    // Existing local methods remain below in the source if needed.
    // ...
}