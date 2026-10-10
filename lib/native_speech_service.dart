import 'package:flutter/services.dart';

class DeviceIdentity {
  const DeviceIdentity({
    required this.installationId,
    required this.deviceModel,
    required this.appVersion,
  });

  final String installationId;
  final String deviceModel;
  final String appVersion;

  factory DeviceIdentity.fromMap(Map<Object?, Object?> map) {
    final installationId = map['installationId'] as String?;
    if (installationId == null || installationId.isEmpty) {
      throw PlatformException(
        code: 'identity_unavailable',
        message: '无法建立本机用户身份。',
      );
    }
    return DeviceIdentity(
      installationId: installationId,
      deviceModel: map['deviceModel'] as String? ?? 'Android',
      appVersion: map['appVersion'] as String? ?? 'unknown',
    );
  }
}

class SpeechRecognitionResult {
  const SpeechRecognitionResult({required this.text, required this.confidence});

  final String text;
  final double confidence;

  factory SpeechRecognitionResult.fromMap(Map<Object?, Object?> map) {
    return SpeechRecognitionResult(
      text: map['text'] as String? ?? '',
      confidence: (map['confidence'] as num?)?.toDouble() ?? 0,
    );
  }
}

class RecordedAudio {
  const RecordedAudio({required this.bytes, required this.path});

  final Uint8List bytes;
  final String path;

  factory RecordedAudio.fromMap(Map<Object?, Object?> map) {
    final bytes = map['bytes'] as Uint8List?;
    final path = map['path'] as String?;
    if (bytes == null || bytes.isEmpty || path == null || path.isEmpty) {
      throw PlatformException(code: 'empty_recording', message: '没有录到有效声音。');
    }
    return RecordedAudio(bytes: bytes, path: path);
  }
}

class NativeSpeechService {
  static const _channel = MethodChannel('com.ieltscoach/speech');

  Future<DeviceIdentity> getDeviceIdentity() async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'getDeviceIdentity',
    );
    if (value == null) {
      throw PlatformException(
        code: 'identity_unavailable',
        message: '无法建立本机用户身份。',
      );
    }
    return DeviceIdentity.fromMap(value);
  }

  Future<Map<String, String>> getRecordingReferences() async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'getRecordingReferences',
    );
    if (value == null) return const {};
    return value.map((key, path) => MapEntry(key.toString(), path.toString()));
  }

  Future<void> saveRecordingReference({
    required String attemptId,
    required String path,
  }) {
    return _channel.invokeMethod<void>('saveRecordingReference', {
      'attemptId': attemptId,
      'path': path,
    });
  }

  Future<bool> isRecognitionAvailable() async {
    return await _channel.invokeMethod<bool>('isRecognitionAvailable') ?? false;
  }

  Future<void> speak(String text, String locale, {double rate = 0.88}) {
    return _channel.invokeMethod<void>('speak', {
      'text': text,
      'locale': locale,
      'rate': rate,
    });
  }

  Future<void> stopSpeaking() => _channel.invokeMethod<void>('stopSpeaking');

  Future<SpeechRecognitionResult> listen(String locale) async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'startListening',
      {'locale': locale},
    );
    if (value == null) {
      throw PlatformException(code: 'empty_result', message: '系统语音服务没有返回识别结果。');
    }
    return SpeechRecognitionResult.fromMap(value);
  }

  Future<void> cancelListening() =>
      _channel.invokeMethod<void>('cancelListening');

  Future<void> startRecording() =>
      _channel.invokeMethod<void>('startRecording');

  Future<RecordedAudio> stopRecording() async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'stopRecording',
    );
    if (value == null) {
      throw PlatformException(code: 'empty_recording', message: '没有录到有效声音。');
    }
    return RecordedAudio.fromMap(value);
  }

  Future<void> cancelRecording() =>
      _channel.invokeMethod<void>('cancelRecording');

  Future<Duration> playRecording(String path) async {
    final durationMs = await _channel.invokeMethod<int>('playRecording', {
      'path': path,
    });
    return Duration(milliseconds: durationMs ?? 0);
  }

  Future<void> stopRecordingPlayback() =>
      _channel.invokeMethod<void>('stopRecordingPlayback');
}
