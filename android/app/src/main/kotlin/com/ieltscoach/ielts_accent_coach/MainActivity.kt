package com.ieltscoach.ielts_accent_coach

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Bundle
import android.os.Build
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Locale
import java.util.UUID
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {
    private val channelName = "com.ieltscoach/speech"
    private val microphoneRequestCode = 4102
    private var textToSpeech: TextToSpeech? = null
    private var ttsReady = false
    private var speechRecognizer: SpeechRecognizer? = null
    private var pendingRecognitionResult: MethodChannel.Result? = null
    private var pendingRecordingStartResult: MethodChannel.Result? = null
    private var pendingLocale = "en-GB"
    private var audioRecord: AudioRecord? = null
    private var recordingThread: Thread? = null
    private var recordingBuffer: ByteArrayOutputStream? = null
    private var mediaPlayer: MediaPlayer? = null
    @Volatile private var isRecording = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        textToSpeech = TextToSpeech(this, this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result -> handleSpeechCall(call, result) }
    }

    override fun onInit(status: Int) {
        ttsReady = status == TextToSpeech.SUCCESS
    }

    private fun handleSpeechCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getDeviceIdentity" -> result.success(getDeviceIdentity())
            "getRecordingReferences" -> result.success(getRecordingReferences())
            "saveRecordingReference" -> saveRecordingReference(call, result)
            "isRecognitionAvailable" -> result.success(SpeechRecognizer.isRecognitionAvailable(this))
            "speak" -> speak(call, result)
            "stopSpeaking" -> {
                textToSpeech?.stop()
                result.success(null)
            }
            "startListening" -> requestListening(call.argument<String>("locale") ?: "en-GB", result)
            "startRecording" -> requestAudioRecording(result)
            "stopRecording" -> stopAudioRecording(result)
            "playRecording" -> playRecording(call.argument<String>("path"), result)
            "stopRecordingPlayback" -> {
                stopRecordingPlayback()
                result.success(null)
            }
            "cancelRecording" -> {
                releaseAudioRecording(discard = true)
                result.success(null)
            }
            "cancelListening" -> {
                finishRecognitionError("cancelled", "本次录音已取消。")
                speechRecognizer?.cancel()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun getDeviceIdentity(): Map<String, String> {
        val preferences = getSharedPreferences("ielts_profile", MODE_PRIVATE)
        val installationId = preferences.getString("installation_id", null)
            ?: UUID.randomUUID().toString().also { generated ->
                preferences.edit().putString("installation_id", generated).apply()
            }
        val versionName = try {
            packageManager.getPackageInfo(packageName, 0).versionName ?: "unknown"
        } catch (_: PackageManager.NameNotFoundException) {
            "unknown"
        }
        return mapOf(
            "installationId" to installationId,
            "deviceModel" to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            "appVersion" to versionName,
        )
    }

    private fun getRecordingReferences(): Map<String, String> {
        val preferences = getSharedPreferences("ielts_recordings", MODE_PRIVATE)
        val references = mutableMapOf<String, String>()
        val staleKeys = mutableListOf<String>()
        preferences.all.forEach { (attemptId, value) ->
            val path = value as? String
            if (path != null && isLocalRecording(path)) {
                references[attemptId] = path
            } else {
                staleKeys.add(attemptId)
            }
        }
        if (staleKeys.isNotEmpty()) {
            preferences.edit().apply {
                staleKeys.forEach { remove(it) }
            }.apply()
        }
        return references
    }

    private fun saveRecordingReference(call: MethodCall, result: MethodChannel.Result) {
        val attemptId = call.argument<String>("attemptId")
        val path = call.argument<String>("path")
        if (attemptId.isNullOrBlank() || path.isNullOrBlank() || !isLocalRecording(path)) {
            result.error("recording_missing", "本地录音文件不存在。", null)
            return
        }
        getSharedPreferences("ielts_recordings", MODE_PRIVATE)
            .edit()
            .putString(attemptId, File(path).canonicalPath)
            .apply()
        result.success(null)
    }

    private fun isLocalRecording(path: String): Boolean {
        return try {
            val file = File(path).canonicalFile
            val recordingRoot = File(cacheDir, "practice_recordings").canonicalFile
            file.isFile && file.path.startsWith(recordingRoot.path + File.separator)
        } catch (_: Exception) {
            false
        }
    }

    private fun speak(call: MethodCall, result: MethodChannel.Result) {
        if (!ttsReady) {
            result.error("tts_unavailable", "系统朗读服务尚未准备好，请稍后重试。", null)
            return
        }

        val text = call.argument<String>("text").orEmpty()
        val localeCode = call.argument<String>("locale") ?: "en-GB"
        val rate = (call.argument<Double>("rate") ?: 0.88).toFloat()
        stopRecordingPlayback()
        val locale = localeFromCode(localeCode)
        val languageStatus = textToSpeech?.setLanguage(locale)
        if (languageStatus == TextToSpeech.LANG_MISSING_DATA ||
            languageStatus == TextToSpeech.LANG_NOT_SUPPORTED
        ) {
            result.error("locale_unavailable", "系统缺少 $localeCode 语音包。", null)
            return
        }

        textToSpeech?.setSpeechRate(rate)
        val status = textToSpeech?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "ielts-reference")
        if (status == TextToSpeech.ERROR) {
            result.error("tts_failed", "系统朗读失败。", null)
        } else {
            result.success(null)
        }
    }

    private fun requestListening(locale: String, result: MethodChannel.Result) {
        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            result.error("recognition_unavailable", "本机没有可用的系统语音识别服务。", null)
            return
        }
        if (pendingRecognitionResult != null) {
            result.error("recognition_busy", "语音识别正在进行中。", null)
            return
        }

        pendingRecognitionResult = result
        pendingLocale = locale
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), microphoneRequestCode)
            return
        }
        startRecognition()
    }

    private fun requestAudioRecording(result: MethodChannel.Result) {
        if (isRecording || pendingRecordingStartResult != null) {
            result.error("recording_busy", "录音正在进行中。", null)
            return
        }
        pendingRecordingStartResult = result
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), microphoneRequestCode)
            return
        }
        startAudioRecording()
    }

    private fun startAudioRecording() {
        val result = pendingRecordingStartResult ?: return
        val sampleRate = 16_000
        val channel = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBufferSize = AudioRecord.getMinBufferSize(sampleRate, channel, encoding)
        if (minBufferSize <= 0) {
            pendingRecordingStartResult = null
            result.error("recording_unavailable", "无法初始化系统录音。", null)
            return
        }

        val recorder = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                sampleRate,
                channel,
                encoding,
                maxOf(minBufferSize, 4096),
            )
        } catch (_: SecurityException) {
            pendingRecordingStartResult = null
            result.error("permission_denied", "麦克风权限未授予。", null)
            return
        }
        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            pendingRecordingStartResult = null
            result.error("recording_unavailable", "系统录音初始化失败。", null)
            return
        }

        audioRecord = recorder
        recordingBuffer = ByteArrayOutputStream()
        isRecording = true
        recorder.startRecording()
        recordingThread = Thread({
            val buffer = ByteArray(4096)
            val maximumBytes = sampleRate * 2 * 30
            while (isRecording && (recordingBuffer?.size() ?: 0) < maximumBytes) {
                val read = recorder.read(buffer, 0, buffer.size)
                if (read > 0) {
                    synchronized(this) {
                        recordingBuffer?.write(buffer, 0, read)
                    }
                }
            }
        }, "ielts-audio-recorder").apply { start() }

        pendingRecordingStartResult = null
        result.success(null)
    }

    private fun stopAudioRecording(result: MethodChannel.Result) {
        if (!isRecording) {
            result.error("recording_inactive", "当前没有正在进行的录音。", null)
            return
        }
        val pcm = releaseAudioRecording(discard = false)
        if (pcm == null || pcm.size < 3_200) {
            result.error("empty_recording", "录音时间太短，请完整朗读句子。", null)
            return
        }
        val wav = createWav(pcm, 16_000)
        val recordingDirectory = File(cacheDir, "practice_recordings").apply { mkdirs() }
        val recordingFile = File(recordingDirectory, "practice_${System.currentTimeMillis()}.wav")
        try {
            recordingFile.writeBytes(wav)
        } catch (_: Exception) {
            result.error("recording_save_failed", "录音保存失败。", null)
            return
        }
        result.success(mapOf("bytes" to wav, "path" to recordingFile.absolutePath))
    }

    private fun playRecording(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("recording_missing", "找不到本次录音。", null)
            return
        }
        val recordingFile = try {
            File(path).canonicalFile
        } catch (_: Exception) {
            result.error("recording_missing", "录音路径无效。", null)
            return
        }
        val cacheRoot = cacheDir.canonicalFile
        if (!recordingFile.path.startsWith(cacheRoot.path + File.separator) || !recordingFile.isFile) {
            result.error("recording_missing", "录音文件不存在。", null)
            return
        }

        stopRecordingPlayback()
        textToSpeech?.stop()
        try {
            mediaPlayer = MediaPlayer().apply {
                setDataSource(recordingFile.absolutePath)
                prepare()
                start()
            }
            result.success(mediaPlayer?.duration ?: 0)
        } catch (_: Exception) {
            stopRecordingPlayback()
            result.error("playback_failed", "录音播放失败。", null)
        }
    }

    private fun stopRecordingPlayback() {
        try {
            mediaPlayer?.stop()
        } catch (_: IllegalStateException) {
            // The player may already have completed playback.
        }
        mediaPlayer?.release()
        mediaPlayer = null
    }

    private fun releaseAudioRecording(discard: Boolean): ByteArray? {
        isRecording = false
        try {
            audioRecord?.stop()
        } catch (_: IllegalStateException) {
            // The recorder may already be stopped by the platform.
        }
        try {
            recordingThread?.join(1_500)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        audioRecord?.release()
        audioRecord = null
        recordingThread = null
        val pcm = if (discard) null else synchronized(this) { recordingBuffer?.toByteArray() }
        recordingBuffer?.close()
        recordingBuffer = null
        return pcm
    }

    private fun createWav(pcm: ByteArray, sampleRate: Int): ByteArray {
        val header = ByteArray(44)
        writeAscii(header, 0, "RIFF")
        writeIntLittleEndian(header, 4, 36 + pcm.size)
        writeAscii(header, 8, "WAVE")
        writeAscii(header, 12, "fmt ")
        writeIntLittleEndian(header, 16, 16)
        writeShortLittleEndian(header, 20, 1)
        writeShortLittleEndian(header, 22, 1)
        writeIntLittleEndian(header, 24, sampleRate)
        writeIntLittleEndian(header, 28, sampleRate * 2)
        writeShortLittleEndian(header, 32, 2)
        writeShortLittleEndian(header, 34, 16)
        writeAscii(header, 36, "data")
        writeIntLittleEndian(header, 40, pcm.size)
        return header + pcm
    }

    private fun writeAscii(target: ByteArray, offset: Int, value: String) {
        value.toByteArray(Charsets.US_ASCII).copyInto(target, offset)
    }

    private fun writeIntLittleEndian(target: ByteArray, offset: Int, value: Int) {
        target[offset] = value.toByte()
        target[offset + 1] = (value shr 8).toByte()
        target[offset + 2] = (value shr 16).toByte()
        target[offset + 3] = (value shr 24).toByte()
    }

    private fun writeShortLittleEndian(target: ByteArray, offset: Int, value: Int) {
        target[offset] = value.toByte()
        target[offset + 1] = (value shr 8).toByte()
    }

    private fun startRecognition() {
        speechRecognizer?.destroy()
        speechRecognizer = SpeechRecognizer.createSpeechRecognizer(this).also { recognizer ->
            recognizer.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) = Unit
                override fun onBeginningOfSpeech() = Unit
                override fun onRmsChanged(rmsdB: Float) = Unit
                override fun onBufferReceived(buffer: ByteArray?) = Unit
                override fun onEndOfSpeech() = Unit
                override fun onPartialResults(partialResults: Bundle?) = Unit
                override fun onEvent(eventType: Int, params: Bundle?) = Unit

                override fun onError(error: Int) {
                    val mapped = when (error) {
                        SpeechRecognizer.ERROR_NO_MATCH,
                        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "no_match" to "没有听清，请再试一次。"
                        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                            "permission_denied" to "麦克风权限未授予。"
                        SpeechRecognizer.ERROR_NETWORK,
                        SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
                            "network_error" to "系统语音识别网络不可用。"
                        SpeechRecognizer.ERROR_RECOGNIZER_BUSY ->
                            "recognition_busy" to "语音识别服务正忙，请稍后重试。"
                        SpeechRecognizer.ERROR_CLIENT -> "cancelled" to "本次录音已取消。"
                        else -> "recognition_failed" to "语音识别失败（错误码 $error）。"
                    }
                    finishRecognitionError(mapped.first, mapped.second)
                }

                override fun onResults(results: Bundle?) {
                    val candidates = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    val confidenceValues = results?.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
                    val text = candidates?.firstOrNull().orEmpty()
                    if (text.isBlank()) {
                        finishRecognitionError("no_match", "没有听清，请再试一次。")
                        return
                    }
                    val confidence = confidenceValues?.firstOrNull()?.takeIf { it >= 0f } ?: 0f
                    pendingRecognitionResult?.success(
                        mapOf(
                            "text" to text,
                            "confidence" to confidence.toDouble(),
                        )
                    )
                    pendingRecognitionResult = null
                }
            })
        }

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, pendingLocale)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, pendingLocale)
            putExtra(RecognizerIntent.EXTRA_ONLY_RETURN_LANGUAGE_PREFERENCE, false)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
        }
        speechRecognizer?.startListening(intent)
    }

    private fun finishRecognitionError(code: String, message: String) {
        pendingRecognitionResult?.error(code, message, null)
        pendingRecognitionResult = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != microphoneRequestCode) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            if (pendingRecordingStartResult != null) {
                startAudioRecording()
            } else {
                startRecognition()
            }
        } else {
            finishRecognitionError("permission_denied", "麦克风权限未授予。")
            pendingRecordingStartResult?.error("permission_denied", "麦克风权限未授予。", null)
            pendingRecordingStartResult = null
        }
    }

    private fun localeFromCode(code: String): Locale {
        val parts = code.split("-")
        return if (parts.size == 2) Locale(parts[0], parts[1]) else Locale.forLanguageTag(code)
    }

    override fun onDestroy() {
        finishRecognitionError("cancelled", "应用已关闭。")
        pendingRecordingStartResult?.error("cancelled", "应用已关闭。", null)
        pendingRecordingStartResult = null
        releaseAudioRecording(discard = true)
        stopRecordingPlayback()
        speechRecognizer?.destroy()
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        super.onDestroy()
    }
}
