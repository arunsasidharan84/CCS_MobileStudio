package com.ccs.mobile_studio

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.SoundPool
import android.media.ToneGenerator
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MainActivity : FlutterActivity() {
    private val AUDIO_CHANNEL = "ccs/audio"
    private val ANGEL_NETWORK_CHANNEL = "angel/network"
    private val NIDRA_NETWORK_CHANNEL = "trainNidra/network"
    private val CCS_NETWORK_CHANNEL = "ccs/network"

    private var soundPool: SoundPool? = null
    private var beepSoundId: Int = -1
    private var mediaPlayer: MediaPlayer? = null
    private var preparedMp3Path: String? = null
    private var isMp3Prepared = false

    private var multicastLock: WifiManager.MulticastLock? = null
    private var pendingFolderResult: MethodChannel.Result? = null
    private val REQUEST_CODE_SELECT_FOLDER = 1001

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 1. Initialize SoundPool and load beep asynchronously
        try {
            val audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            soundPool = SoundPool.Builder()
                .setMaxStreams(2)
                .setAudioAttributes(audioAttributes)
                .build()

            val beepFile = File(context.cacheDir, "beep.wav")
            generateBeepWav(beepFile)
            soundPool?.let { pool ->
                beepSoundId = pool.load(beepFile.absolutePath, 1)
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "Error initializing SoundPool: ${e.message}")
        }

        // 2. Audio Channel Handler
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "keepScreenOn" -> {
                    val enable = call.argument<Boolean>("enable") ?: false
                    try {
                        if (enable) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WINDOW_ERROR", e.message, null)
                    }
                }
                "startRecordingService" -> {
                    try {
                        val serviceIntent = Intent(this, RecordingForegroundService::class.java).apply {
                            action = RecordingForegroundService.ACTION_START
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(serviceIntent)
                        } else {
                            startService(serviceIntent)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e("MainActivity", "Failed to start recording service: ${e.message}")
                        result.error("FOREGROUND_SERVICE_ERROR", e.message, null)
                    }
                }
                "stopRecordingService" -> {
                    try {
                        // Plain startService (not startForegroundService): the service is
                        // already in the foreground at this point, and this path never
                        // calls startForeground() itself, so it must not be launched via
                        // the API that requires startForeground() within a few seconds.
                        val serviceIntent = Intent(this, RecordingForegroundService::class.java).apply {
                            action = RecordingForegroundService.ACTION_STOP
                        }
                        startService(serviceIntent)
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e("MainActivity", "Failed to stop recording service: ${e.message}")
                        result.error("FOREGROUND_SERVICE_ERROR", e.message, null)
                    }
                }
                "playTone" -> {
                    val volume = call.argument<Int>("volume") ?: 80
                    try {
                        if (soundPool != null && beepSoundId != -1) {
                            val vol = (volume.toFloat() / 100.0f).coerceIn(0.0f, 1.0f)
                            soundPool?.play(beepSoundId, vol, vol, 1, 0, 1.0f)
                            result.success(true)
                        } else {
                            // Fallback to ToneGenerator if SoundPool is not ready
                            val durationMs = call.argument<Int>("durationMs") ?: 200
                            val tg = ToneGenerator(AudioManager.STREAM_MUSIC, volume)
                            tg.startTone(ToneGenerator.TONE_PROP_BEEP, durationMs)
                            Handler(Looper.getMainLooper()).postDelayed({ tg.release() }, durationMs.toLong() + 100)
                            result.success(true)
                        }
                    } catch (e: Exception) {
                        result.error("AUDIO_ERROR", e.message, null)
                    }
                }
                "prepareMp3" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("BAD_ARGS", "Path is null", null)
                        return@setMethodCallHandler
                    }
                    if (path == preparedMp3Path && isMp3Prepared) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    try {
                        mediaPlayer?.release()
                        mediaPlayer = null
                        isMp3Prepared = false
                        preparedMp3Path = null

                        val mp = MediaPlayer()
                        mp.setDataSource(path)
                        mp.setOnPreparedListener {
                            isMp3Prepared = true
                            preparedMp3Path = path
                        }
                        mp.setOnCompletionListener {
                            try {
                                it.seekTo(0)
                            } catch (e: Exception) {
                                // ignore
                            }
                        }
                        mp.prepareAsync()
                        mediaPlayer = mp
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("PREPARE_ERROR", e.message, null)
                    }
                }
                "playMp3" -> {
                    try {
                        val mp = mediaPlayer
                        if (mp != null && isMp3Prepared) {
                            mp.start()
                            result.success(true)
                        } else {
                            result.error("NOT_PREPARED", "MediaPlayer is not prepared or null", null)
                        }
                    } catch (e: Exception) {
                        result.error("PLAY_ERROR", e.message, null)
                    }
                }
                "stopMp3" -> {
                    try {
                        mediaPlayer?.let {
                            if (it.isPlaying) {
                                it.pause()
                            }
                            it.seekTo(0)
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_ERROR", e.message, null)
                    }
                }
                "selectFolder" -> {
                    pendingFolderResult = result
                    try {
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                        startActivityForResult(intent, REQUEST_CODE_SELECT_FOLDER)
                    } catch (e: Exception) {
                        pendingFolderResult = null
                        result.error("PICKER_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 3. Network Channels Handler (for LSL / fNIRS multicast locks)
        val networkHandler = MethodChannel.MethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    try {
                        if (multicastLock == null) {
                            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            val lock = wifiManager.createMulticastLock("ccs_lsl_multicast")
                            lock.setReferenceCounted(true)
                            lock.acquire()
                            multicastLock = lock
                        } else if (!multicastLock!!.isHeld) {
                            multicastLock!!.acquire()
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("MULTICAST_LOCK_ERROR", e.message, null)
                    }
                }
                "releaseMulticastLock" -> {
                    try {
                        multicastLock?.let {
                            if (it.isHeld) it.release()
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("MULTICAST_LOCK_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ANGEL_NETWORK_CHANNEL).setMethodCallHandler(networkHandler)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NIDRA_NETWORK_CHANNEL).setMethodCallHandler(networkHandler)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CCS_NETWORK_CHANNEL).setMethodCallHandler(networkHandler)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_SELECT_FOLDER) {
            val res = pendingFolderResult
            pendingFolderResult = null
            if (res != null) {
                if (resultCode == RESULT_OK && data != null) {
                    val treeUri = data.data
                    if (treeUri != null) {
                        val path = getAbsolutePathFromDocumentTreeUri(treeUri)
                        if (path != null) {
                            res.success(path)
                        } else {
                            res.error("PATH_RESOLVE_FAILED", "Could not resolve absolute path from folder URI", null)
                        }
                    } else {
                        res.error("NO_DATA", "Selected folder URI is null", null)
                    }
                } else {
                    res.success(null) // user cancelled
                }
            }
        }
    }

    private fun getAbsolutePathFromDocumentTreeUri(uri: Uri): String? {
        try {
            val docId = DocumentsContract.getTreeDocumentId(uri)
            val split = docId.split(":")
            val type = split[0]
            val relativePath = if (split.size > 1) split[1] else ""

            if ("primary".equals(type, ignoreCase = true)) {
                return Environment.getExternalStorageDirectory().absolutePath + "/" + relativePath
            }
            // Secondary storage (SD cards)
            val storagePoints = File("/storage").listFiles()
            if (storagePoints != null) {
                for (point in storagePoints) {
                    if (point.name.equals(type, ignoreCase = true)) {
                        return point.absolutePath + "/" + relativePath
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("MainActivity", "Error resolving Uri to path: ${e.message}")
        }
        return null
    }

    private fun generateBeepWav(file: File) {
        if (file.exists()) return // only generate once
        val sampleRate = 48000
        val durationMs = 200
        val numSamples = (sampleRate * (durationMs / 1000.0)).toInt()
        val totalAudioLen = numSamples * 2L
        val totalDataLen = totalAudioLen + 36

        FileOutputStream(file).use { out ->
            val header = ByteArray(44)
            header[0] = 'R'.code.toByte()
            header[1] = 'I'.code.toByte()
            header[2] = 'F'.code.toByte()
            header[3] = 'F'.code.toByte()
            header[4] = (totalDataLen and 0xff).toByte()
            header[5] = ((totalDataLen shr 8) and 0xff).toByte()
            header[6] = ((totalDataLen shr 16) and 0xff).toByte()
            header[7] = ((totalDataLen shr 24) and 0xff).toByte()
            header[8] = 'W'.code.toByte()
            header[9] = 'A'.code.toByte()
            header[10] = 'V'.code.toByte()
            header[11] = 'E'.code.toByte()
            header[12] = 'f'.code.toByte()
            header[13] = 'm'.code.toByte()
            header[14] = 't'.code.toByte()
            header[15] = ' '.code.toByte()
            header[16] = 16
            header[17] = 0
            header[18] = 0
            header[19] = 0
            header[20] = 1 // PCM
            header[21] = 0
            header[22] = 1 // Mono
            header[23] = 0
            header[24] = (sampleRate and 0xff).toByte()
            header[25] = ((sampleRate shr 8) and 0xff).toByte()
            header[26] = ((sampleRate shr 16) and 0xff).toByte()
            header[27] = ((sampleRate shr 24) and 0xff).toByte()
            val byteRate = sampleRate * 2L
            header[28] = (byteRate and 0xff).toByte()
            header[29] = ((byteRate shr 8) and 0xff).toByte()
            header[30] = ((byteRate shr 16) and 0xff).toByte()
            header[31] = ((byteRate shr 24) and 0xff).toByte()
            header[32] = 2 // Block align
            header[33] = 0
            header[34] = 16 // Bits per sample
            header[35] = 0
            header[36] = 'd'.code.toByte()
            header[37] = 'a'.code.toByte()
            header[38] = 't'.code.toByte()
            header[39] = 'a'.code.toByte()
            header[40] = (totalAudioLen and 0xff).toByte()
            header[41] = ((totalAudioLen shr 8) and 0xff).toByte()
            header[42] = ((totalAudioLen shr 16) and 0xff).toByte()
            header[43] = ((totalAudioLen shr 24) and 0xff).toByte()
            out.write(header)

            val fadeSamples = (sampleRate * 0.01).toInt() // 10ms fade
            val buffer = ByteBuffer.allocate(numSamples * 2).order(ByteOrder.LITTLE_ENDIAN)
            for (i in 0 until numSamples) {
                val t = i.toDouble() / sampleRate
                var amplitude = 1.0
                if (i < fadeSamples) {
                    amplitude = i.toDouble() / fadeSamples
                } else if (i > numSamples - fadeSamples) {
                    amplitude = (numSamples - i).toDouble() / fadeSamples
                }
                val value = (Math.sin(2.0 * Math.PI * 1000.0 * t) * 32767.0 * amplitude).toInt().toShort()
                buffer.putShort(value)
            }
            out.write(buffer.array())
        }
    }

    override fun onDestroy() {
        soundPool?.release()
        soundPool = null
        mediaPlayer?.release()
        mediaPlayer = null
        multicastLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }
}
