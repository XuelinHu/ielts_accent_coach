import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class CoachMessage {
  const CoachMessage({required this.role, required this.content});

  final String role;
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

class DeviceRegistration {
  const DeviceRegistration({required this.userId, required this.sessionId});

  final String userId;
  final String sessionId;
}

class SavedAttempt {
  const SavedAttempt({required this.id, required this.createdAt});

  final String id;
  final DateTime createdAt;
}

class StoredAttempt {
  const StoredAttempt({
    required this.id,
    required this.accent,
    required this.topic,
    required this.level,
    required this.reference,
    required this.transcript,
    required this.focus,
    required this.overall,
    required this.accuracy,
    required this.completeness,
    required this.fluency,
    required this.requirements,
    required this.createdAt,
  });

  final String id;
  final String accent;
  final String topic;
  final String level;
  final String reference;
  final String transcript;
  final String focus;
  final int overall;
  final int accuracy;
  final int completeness;
  final int fluency;
  final List<String> requirements;
  final DateTime createdAt;

  factory StoredAttempt.fromJson(Map<String, dynamic> json) {
    return StoredAttempt(
      id: json['id'] as String,
      accent: json['accent'] as String,
      topic: json['topic'] as String,
      level: json['level'] as String,
      reference: json['reference'] as String,
      transcript: json['transcript'] as String,
      focus: json['focus'] as String,
      overall: (json['overall'] as num).toInt(),
      accuracy: (json['accuracy'] as num).toInt(),
      completeness: (json['completeness'] as num).toInt(),
      fluency: (json['fluency'] as num).toInt(),
      requirements: (json['requirements'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
      createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
    );
  }
}

class CoachReply {
  const CoachReply({
    required this.text,
    required this.conversationId,
    required this.persisted,
  });

  final String text;
  final String? conversationId;
  final bool persisted;
}

class CoachApi {
  CoachApi({required this.baseUrl});

  String baseUrl;

  String get _normalizedBase => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  Future<DeviceRegistration> ensureUser({
    required String installationId,
    required String deviceModel,
    required String appVersion,
  }) async {
    final payload = await _postJson('/api/users/ensure', {
      'installationId': installationId,
      'deviceModel': deviceModel,
      'appVersion': appVersion,
    });
    return DeviceRegistration(
      userId: payload['userId'] as String,
      sessionId: payload['sessionId'] as String,
    );
  }

  Future<List<StoredAttempt>> loadAttempts(String userId) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final uri = Uri.parse(
        '$_normalizedBase/api/practice-attempts',
      ).replace(queryParameters: {'userId': userId, 'limit': '50'});
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final body = await utf8.decoder.bind(response).join();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CoachApiException(payload['error'] as String? ?? '读取练习历史失败。');
      }
      return (payload['attempts'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(StoredAttempt.fromJson)
          .toList();
    } on SocketException {
      throw const CoachApiException('无法连接本机服务，请确认 Node 服务已启动并执行了 adb reverse。');
    } on TimeoutException {
      throw const CoachApiException('读取练习历史超时。');
    } on FormatException {
      throw const CoachApiException('练习历史返回格式异常。');
    } finally {
      client.close(force: true);
    }
  }

  Future<SavedAttempt> saveAttempt({
    required String userId,
    required String sessionId,
    required String accent,
    required String topic,
    required String level,
    required String reference,
    required String transcript,
    required String focus,
    required int overall,
    required int accuracy,
    required int completeness,
    required int fluency,
    required List<String> requirements,
    required DateTime createdAt,
  }) async {
    final payload = await _postJson('/api/practice-attempts', {
      'userId': userId,
      'sessionId': sessionId,
      'accent': accent,
      'topic': topic,
      'level': level,
      'reference': reference,
      'transcript': transcript,
      'focus': focus,
      'overall': overall,
      'accuracy': accuracy,
      'completeness': completeness,
      'fluency': fluency,
      'requirements': requirements,
      'createdAt': createdAt.toUtc().toIso8601String(),
    });
    return SavedAttempt(
      id: payload['id'] as String,
      createdAt: DateTime.parse(payload['createdAt'] as String).toLocal(),
    );
  }

  Future<String> transcribe({
    required Uint8List wavBytes,
    required String locale,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(
        Uri.parse('$_normalizedBase/api/transcribe'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'audio': 'data:audio/wav;base64,${base64Encode(wavBytes)}',
          'locale': locale,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 45),
      );
      final body = await utf8.decoder.bind(response).join();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CoachApiException(payload['error'] as String? ?? '网络语音识别失败。');
      }
      final transcript = payload['transcript'] as String?;
      if (transcript == null || transcript.trim().isEmpty) {
        throw const CoachApiException('没有识别到有效英语，请再试一次。');
      }
      return transcript.trim();
    } on SocketException {
      throw const CoachApiException('无法连接本机服务，请确认 Node 服务已启动并执行了 adb reverse。');
    } on TimeoutException {
      throw const CoachApiException('网络语音识别超时，请稍后重试。');
    } on FormatException {
      throw const CoachApiException('语音识别服务返回格式异常。');
    } finally {
      client.close(force: true);
    }
  }

  Future<CoachReply> ask({
    required String message,
    required List<CoachMessage> history,
    Map<String, Object?>? practiceContext,
    String? userId,
    String? sessionId,
    String? conversationId,
    String? practiceAttemptId,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(
        Uri.parse('$_normalizedBase/api/coach'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'message': message,
          'history': history.takeLast(8).map((item) => item.toJson()).toList(),
          'practiceContext': ?practiceContext,
          'userId': ?userId,
          'sessionId': ?sessionId,
          'conversationId': ?conversationId,
          'practiceAttemptId': ?practiceAttemptId,
        }),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await utf8.decoder.bind(response).join();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CoachApiException(payload['error'] as String? ?? 'AI 教练服务请求失败。');
      }
      final reply = payload['reply'] as String?;
      if (reply == null || reply.trim().isEmpty) {
        throw const CoachApiException('AI 教练返回了空内容。');
      }
      return CoachReply(
        text: reply.trim(),
        conversationId: payload['conversationId'] as String?,
        persisted: payload['persisted'] as bool? ?? false,
      );
    } on SocketException {
      throw const CoachApiException('无法连接本机服务，请确认 Node 服务已启动并执行了 adb reverse。');
    } on TimeoutException {
      throw const CoachApiException('AI 教练响应超时，请稍后重试。');
    } on FormatException {
      throw const CoachApiException('服务返回格式异常。');
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, Object?> body,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.postUrl(Uri.parse('$_normalizedBase$path'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final responseBody = await utf8.decoder.bind(response).join();
      final payload = jsonDecode(responseBody) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CoachApiException(payload['error'] as String? ?? '后台数据服务请求失败。');
      }
      return payload;
    } on SocketException {
      throw const CoachApiException('无法连接本机服务，请确认 Node 服务已启动并执行了 adb reverse。');
    } on TimeoutException {
      throw const CoachApiException('后台数据服务响应超时。');
    } on FormatException {
      throw const CoachApiException('后台数据服务返回格式异常。');
    } finally {
      client.close(force: true);
    }
  }
}

class CoachApiException implements Exception {
  const CoachApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

extension _TakeLast<T> on List<T> {
  Iterable<T> takeLast(int count) {
    if (length <= count) return this;
    return skip(length - count);
  }
}
