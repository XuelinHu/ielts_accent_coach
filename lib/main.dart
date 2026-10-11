import 'dart:async';

import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_data.dart';
import 'coach_api.dart';
import 'native_speech_service.dart';
import 'pronunciation_score.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IeltsAccentApp());
}

const _ink = Color(0xFF17202A);
const _navy = Color(0xFF173F5F);
const _teal = Color(0xFF15807A);
const _coral = Color(0xFFE76F51);
const _paper = Color(0xFFF7F8F5);
const _line = Color(0xFFDDE2E0);
const _oidcIssuer = String.fromEnvironment(
  'IELTS_OIDC_ISSUER',
  defaultValue: 'https://192.168.1.9:8042/realms/front',
);
const _oidcClientId = 'ielts-accent-android';
const _oidcRedirectUrl = 'ieltsaccentcoach:/oauth2redirect';

class IeltsAccentApp extends StatelessWidget {
  const IeltsAccentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IELTS Accent Lab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme:
            ColorScheme.fromSeed(
              seedColor: _teal,
              brightness: Brightness.light,
              surface: _paper,
            ).copyWith(
              primary: _navy,
              secondary: _teal,
              tertiary: _coral,
              outlineVariant: _line,
            ),
        scaffoldBackgroundColor: _paper,
        fontFamily: 'sans-serif',
        textTheme: const TextTheme(
          headlineSmall: TextStyle(
            color: _ink,
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
          titleLarge: TextStyle(
            color: _ink,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
          titleMedium: TextStyle(
            color: _ink,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: TextStyle(color: _ink, fontSize: 16, height: 1.55),
          bodyMedium: TextStyle(color: Color(0xFF4A565F), height: 1.45),
        ),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: _line),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            borderSide: BorderSide(color: _line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            borderSide: BorderSide(color: _line),
          ),
        ),
      ),
      home: const AppShell(),
    );
  }
}

class AttemptRecord {
  const AttemptRecord({
    required this.line,
    required this.transcript,
    required this.result,
    required this.createdAt,
    required this.recordingPath,
    this.serverId,
  });

  final PracticeLine line;
  final String transcript;
  final PronunciationResult result;
  final DateTime createdAt;
  final String? recordingPath;
  final String? serverId;

  AttemptRecord withServerId(String id) => AttemptRecord(
    line: line,
    transcript: transcript,
    result: result,
    createdAt: createdAt,
    recordingPath: recordingPath,
    serverId: id,
  );
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tabIndex = 0;
  int _lineIndex = 0;
  AccentProfile _accent = AccentProfile.british;
  String _apiBaseUrl = const String.fromEnvironment(
    'IELTS_API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8041',
  );
  final FlutterAppAuth _appAuth = const FlutterAppAuth();
  String? _accessToken;
  bool _loggingIn = false;
  String? _loginError;
  final List<AttemptRecord> _attempts = [];
  final List<AttemptRecord> _historyAttempts = [];
  AttemptRecord? _latestAttempt;
  int _historyPage = 1;
  int _historyPageSize = 20;
  int _historyTotal = 0;
  int _historyTotalPages = 1;
  bool _historyLoading = false;
  String? _userId;
  String? _sessionId;
  String? _conversationId;
  bool _databaseOnline = false;
  int _pendingSyncs = 0;
  final List<CoachMessage> _messages = const [
    CoachMessage(
      role: 'assistant',
      content: '你好，我是你的 IELTS 口语教练。完成一次跟读后，我可以结合识别结果帮你分析；也可以直接问我连读、重音或答题表达。',
    ),
  ].toList();

  List<PracticeLine> get _accentLines =>
      practiceLines.where((line) => line.accent == _accent).toList();

  PracticeLine get _currentLine =>
      _accentLines[_lineIndex % _accentLines.length];

  Future<void> _signIn() async {
    if (_loggingIn) return;
    setState(() {
      _loggingIn = true;
      _loginError = null;
    });
    try {
      final result = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          _oidcClientId,
          _oidcRedirectUrl,
          issuer: _oidcIssuer,
          scopes: const ['openid', 'profile'],
        ),
      );
      final token = result.accessToken;
      if (token == null || token.isEmpty) {
        throw const CoachApiException('统一登录没有返回访问令牌。');
      }
      if (!mounted) return;
      setState(() => _accessToken = token);
      await _initializeBackend(token);
    } catch (error) {
      if (mounted) setState(() => _loginError = '登录失败：$error');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  void _signOut() {
    setState(() {
      _accessToken = null;
      _userId = null;
      _sessionId = null;
      _databaseOnline = false;
      _conversationId = null;
      _attempts.clear();
      _historyAttempts.clear();
      _latestAttempt = null;
      _historyTotal = 0;
      _historyPage = 1;
    });
  }

  Future<void> _initializeBackend(String accessToken) async {
    try {
      final identity = await NativeSpeechService().getDeviceIdentity();
      final api = CoachApi(baseUrl: _apiBaseUrl, accessToken: accessToken);
      final registration = await api.ensureUser(
        installationId: identity.installationId,
        deviceModel: identity.deviceModel,
        appVersion: identity.appVersion,
      );
      final storedPage = await api.loadAttempts();
      final recordingReferences = await NativeSpeechService()
          .getRecordingReferences();
      if (!mounted) return;
      setState(() {
        _userId = registration.userId;
        _sessionId = registration.sessionId;
        _databaseOnline = true;
        final attempts = storedPage.attempts
            .map(
              (attempt) => _attemptFromStorage(
                attempt,
                recordingPath: recordingReferences[attempt.id],
              ),
            )
            .toList();
        _attempts
          ..clear()
          ..addAll(attempts);
        _historyAttempts
          ..clear()
          ..addAll(attempts);
        _latestAttempt = attempts.firstOrNull;
        _historyPage = storedPage.page;
        _historyPageSize = storedPage.pageSize;
        _historyTotal = storedPage.total;
        _historyTotalPages = storedPage.totalPages;
      });
    } catch (_) {
      if (mounted) setState(() => _databaseOnline = false);
    }
  }

  AttemptRecord _attemptFromStorage(
    StoredAttempt stored, {
    String? recordingPath,
  }) {
    final accent = AccentProfile.values.firstWhere(
      (item) => item.name == stored.accent,
      orElse: () => AccentProfile.british,
    );
    final line = PracticeLine(
      topic: stored.topic,
      level: stored.level,
      text: stored.reference,
      focus: stored.focus,
      tip: '该记录已从数据库恢复。',
      accent: accent,
    );
    final marks = scorePronunciation(stored.reference, stored.transcript, 0);
    return AttemptRecord(
      line: line,
      transcript: stored.transcript,
      result: PronunciationResult(
        overall: stored.overall,
        accuracy: stored.accuracy,
        completeness: stored.completeness,
        fluency: stored.fluency,
        referenceMarks: marks.referenceMarks,
      ),
      createdAt: stored.createdAt,
      recordingPath: recordingPath,
      serverId: stored.id,
    );
  }

  void _changeAccent(AccentProfile accent) {
    setState(() {
      _accent = accent;
      _lineIndex = 0;
    });
  }

  void _nextLine() {
    setState(() => _lineIndex = (_lineIndex + 1) % _accentLines.length);
  }

  void _addAttempt(AttemptRecord attempt) {
    setState(() {
      _attempts.insert(0, attempt);
      _latestAttempt = attempt;
      _historyTotal++;
      if (_historyPage == 1) {
        _historyAttempts.insert(0, attempt);
        if (_historyAttempts.length > _historyPageSize) {
          _historyAttempts.removeLast();
        }
      }
      _historyTotalPages = (_historyTotal / _historyPageSize)
          .ceil()
          .clamp(1, 1 << 30)
          .toInt();
    });
    unawaited(_persistAttempt(attempt));
  }

  Future<void> _loadHistoryPage(int page) async {
    final userId = _userId;
    final accessToken = _accessToken;
    if (userId == null ||
        accessToken == null ||
        !_databaseOnline ||
        _historyLoading) {
      return;
    }
    setState(() => _historyLoading = true);
    try {
      final result = await CoachApi(
        baseUrl: _apiBaseUrl,
        accessToken: accessToken,
      ).loadAttempts(page: page, pageSize: _historyPageSize);
      final recordingReferences = await NativeSpeechService()
          .getRecordingReferences();
      if (!mounted) return;
      setState(() {
        _historyAttempts
          ..clear()
          ..addAll(
            result.attempts.map(
              (attempt) => _attemptFromStorage(
                attempt,
                recordingPath: recordingReferences[attempt.id],
              ),
            ),
          );
        _historyPage = result.page;
        _historyTotal = result.total;
        _historyTotalPages = result.totalPages;
      });
    } on CoachApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('读取练习历史失败：${error.message}')));
      }
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _persistAttempt(AttemptRecord attempt) async {
    final userId = _userId;
    final sessionId = _sessionId;
    final accessToken = _accessToken;
    if (userId == null || sessionId == null || accessToken == null) return;
    if (mounted) setState(() => _pendingSyncs++);
    try {
      final saved =
          await CoachApi(
            baseUrl: _apiBaseUrl,
            accessToken: accessToken,
          ).saveAttempt(
            sessionId: sessionId,
            accent: attempt.line.accent.name,
            topic: attempt.line.topic,
            level: attempt.line.level,
            reference: attempt.line.text,
            transcript: attempt.transcript,
            focus: attempt.line.focus,
            overall: attempt.result.overall,
            accuracy: attempt.result.accuracy,
            completeness: attempt.result.completeness,
            fluency: attempt.result.fluency,
            requirements: _nextRoundRequirements(attempt.result, attempt.line),
            createdAt: attempt.createdAt,
          );
      if (attempt.recordingPath != null) {
        await NativeSpeechService().saveRecordingReference(
          attemptId: saved.id,
          path: attempt.recordingPath!,
        );
      }
      if (!mounted) return;
      setState(() {
        final index = _attempts.indexOf(attempt);
        if (index >= 0) _attempts[index] = attempt.withServerId(saved.id);
        _databaseOnline = true;
      });
    } on CoachApiException catch (error) {
      if (!mounted) return;
      setState(() => _databaseOnline = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('练习结果暂未同步：${error.message}')));
    } finally {
      if (mounted) setState(() => _pendingSyncs--);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_accessToken == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('IELTS Accent Lab')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const _BrandMark(),
                  const SizedBox(height: 20),
                  Text(
                    '登录后同步练习记录',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _loggingIn ? null : _signIn,
                    icon: _loggingIn
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.login),
                    label: Text(_loggingIn ? '正在连接统一登录' : '使用统一账号登录'),
                  ),
                  if (_loginError != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _loginError!,
                      style: const TextStyle(color: _coral),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }
    final pages = [
      PracticePage(
        key: ValueKey('${_accent.name}-$_lineIndex'),
        accent: _accent,
        line: _currentLine,
        attempts: _attempts,
        apiBaseUrl: _apiBaseUrl,
        accessToken: _accessToken!,
        onAccentChanged: _changeAccent,
        onAttempt: _addAttempt,
        onNext: _nextLine,
      ),
      CoachPage(
        messages: _messages,
        latestAttempt: _latestAttempt,
        apiBaseUrl: _apiBaseUrl,
        accessToken: _accessToken!,
        sessionId: _sessionId,
        conversationId: _conversationId,
        onMessagesChanged: () => setState(() {}),
        onConversationIdChanged: (value) =>
            setState(() => _conversationId = value),
        onApiBaseUrlChanged: (value) => setState(() => _apiBaseUrl = value),
      ),
      ProgressPage(
        attempts: _historyAttempts,
        databaseOnline: _databaseOnline,
        syncing: _pendingSyncs > 0,
        page: _historyPage,
        total: _historyTotal,
        totalPages: _historyTotalPages,
        loading: _historyLoading,
        onPageChanged: _loadHistoryPage,
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: _paper,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 20,
        title: const Row(
          children: [
            _BrandMark(),
            SizedBox(width: 10),
            Text(
              'IELTS Accent Lab',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '退出登录',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: IndexedStack(index: _tabIndex, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        height: 68,
        onDestinationSelected: (value) => setState(() => _tabIndex = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.graphic_eq_outlined),
            selectedIcon: Icon(Icons.graphic_eq),
            label: '跟读',
          ),
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: 'AI 教练',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: '进度',
          ),
        ],
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: const BoxDecoration(color: _navy, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: const Icon(Icons.mic_rounded, size: 18, color: Colors.white),
    );
  }
}

class PracticePage extends StatefulWidget {
  const PracticePage({
    super.key,
    required this.accent,
    required this.line,
    required this.attempts,
    required this.apiBaseUrl,
    required this.accessToken,
    required this.onAccentChanged,
    required this.onAttempt,
    required this.onNext,
  });

  final AccentProfile accent;
  final PracticeLine line;
  final List<AttemptRecord> attempts;
  final String apiBaseUrl;
  final String accessToken;
  final ValueChanged<AccentProfile> onAccentChanged;
  final ValueChanged<AttemptRecord> onAttempt;
  final VoidCallback onNext;

  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage> {
  final _speech = NativeSpeechService();
  bool _isListening = false;
  bool _isSpeaking = false;
  bool _usingNetworkRecording = false;
  String? _error;
  String? _transcript;
  String? _recordingPath;
  PronunciationResult? _result;

  Future<void> _playReference() async {
    if (_isSpeaking) {
      await _speech.stopSpeaking();
      if (mounted) setState(() => _isSpeaking = false);
      return;
    }
    setState(() {
      _isSpeaking = true;
      _error = null;
    });
    try {
      await _speech.speak(widget.line.text, widget.accent.locale);
      await Future<void>.delayed(const Duration(milliseconds: 900));
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message ?? '系统朗读不可用。');
    } finally {
      if (mounted) setState(() => _isSpeaking = false);
    }
  }

  Future<void> _startPractice() async {
    if (_isListening) {
      if (_usingNetworkRecording) {
        await _finishNetworkRecording();
      } else {
        await _speech.cancelListening();
        if (mounted) setState(() => _isListening = false);
      }
      return;
    }
    setState(() {
      _isListening = true;
      _error = null;
      _transcript = null;
      _recordingPath = null;
      _result = null;
    });
    try {
      await _speech.stopRecordingPlayback();
      await _speech.startRecording();
      if (mounted) setState(() => _usingNetworkRecording = true);
      return;
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlySpeechError(error));
    } finally {
      if (mounted && !_usingNetworkRecording) {
        setState(() => _isListening = false);
      }
    }
  }

  Future<void> _finishNetworkRecording() async {
    setState(() {
      _isListening = false;
      _usingNetworkRecording = false;
      _error = null;
    });
    try {
      final recording = await _speech.stopRecording();
      final transcript = await CoachApi(
        baseUrl: widget.apiBaseUrl,
        accessToken: widget.accessToken,
      ).transcribe(wavBytes: recording.bytes, locale: widget.accent.locale);
      _applyRecognition(transcript, 0, recordingPath: recording.path);
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = _friendlySpeechError(error));
    } on CoachApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  void _applyRecognition(
    String transcript,
    double confidence, {
    String? recordingPath,
  }) {
    final result = scorePronunciation(widget.line.text, transcript, confidence);
    final attempt = AttemptRecord(
      line: widget.line,
      transcript: transcript,
      result: result,
      createdAt: DateTime.now(),
      recordingPath: recordingPath,
    );
    if (!mounted) return;
    setState(() {
      _transcript = transcript;
      _recordingPath = recordingPath;
      _result = result;
    });
    widget.onAttempt(attempt);
  }

  String _friendlySpeechError(PlatformException error) {
    return switch (error.code) {
      'permission_denied' => '需要麦克风权限才能开始跟读，请在系统设置中允许。',
      'recognition_unavailable' => '本机没有可用的系统语音识别服务。',
      'no_match' => '没有听清，请靠近麦克风并再试一次。',
      'cancelled' => '本次录音已取消。',
      _ => error.message ?? '语音识别失败，请重试。',
    };
  }

  @override
  Widget build(BuildContext context) {
    final todayCount = widget.attempts
        .where((item) => DateUtils.isSameDay(item.createdAt, DateTime.now()))
        .length;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _GoalStrip(todayCount: todayCount),
            const SizedBox(height: 20),
            Text('选择目标口音', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            SegmentedButton<AccentProfile>(
              segments: [
                for (final accent in AccentProfile.values)
                  ButtonSegment(value: accent, label: Text(accent.label)),
              ],
              selected: {widget.accent},
              showSelectedIcon: false,
              onSelectionChanged: (value) =>
                  widget.onAccentChanged(value.first),
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.line.topic,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        _Label(text: widget.line.level, color: _coral),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text(
                      widget.line.text,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 21,
                        height: 1.45,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        IconButton.filledTonal(
                          tooltip: _isSpeaking ? '停止朗读' : '播放示范',
                          onPressed: _playReference,
                          icon: Icon(
                            _isSpeaking ? Icons.stop : Icons.volume_up,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${widget.accent.englishLabel} · ${widget.accent.detail}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text('训练重点：${widget.line.focus}'),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 30),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.lightbulb_outline,
                          color: _teal,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(widget.line.tip)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 54,
              child: FilledButton.icon(
                onPressed: _startPractice,
                style: FilledButton.styleFrom(
                  backgroundColor: _isListening ? _coral : _navy,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: Icon(
                  _isListening ? Icons.stop_circle_outlined : Icons.mic,
                ),
                label: Text(
                  _isListening
                      ? (_usingNetworkRecording ? '录音中，点击完成' : '正在聆听，点击取消')
                      : '开始跟读',
                ),
              ),
            ),
            if (_isListening) ...[
              const SizedBox(height: 12),
              _ListeningIndicator(isNetworkRecording: _usingNetworkRecording),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              _Notice(text: _error!, isError: true),
            ],
            if (_result != null && _transcript != null) ...[
              const SizedBox(height: 20),
              _ResultPanel(
                result: _result!,
                transcript: _transcript!,
                line: widget.line,
                recordingPath: _recordingPath,
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: widget.onNext,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('下一句'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GoalStrip extends StatelessWidget {
  const _GoalStrip({required this.todayCount});

  final int todayCount;

  @override
  Widget build(BuildContext context) {
    final progress = (todayCount / 5).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF3F1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.local_fire_department_outlined, color: _coral),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '今日训练 $todayCount / 5',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                  backgroundColor: Colors.white,
                  color: _teal,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text('${(progress * 100).round()}%'),
        ],
      ),
    );
  }
}

class _ListeningIndicator extends StatelessWidget {
  const _ListeningIndicator({required this.isNetworkRecording});

  final bool isNetworkRecording;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Text(isNetworkRecording ? '请朗读整句话，完成后点击按钮' : '请自然朗读整句话…'),
      ],
    );
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({
    required this.result,
    required this.transcript,
    required this.line,
    required this.recordingPath,
  });

  final PronunciationResult result;
  final String transcript;
  final PracticeLine line;
  final String? recordingPath;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 66,
                  height: 66,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _scoreColor(result.overall),
                      width: 5,
                    ),
                  ),
                  child: Text(
                    '${result.overall}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '本次结果',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      Text(_scoreAdvice(result.overall)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _Metric(label: '准确度', value: result.accuracy),
                ),
                Expanded(
                  child: _Metric(label: '完整度', value: result.completeness),
                ),
                Expanded(
                  child: _Metric(label: '流利度', value: result.fluency),
                ),
              ],
            ),
            if (recordingPath != null) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: _RecordingPlaybackButton(path: recordingPath!),
              ),
            ],
            const Divider(height: 30),
            const Text('系统听到', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(transcript, style: const TextStyle(fontSize: 16, height: 1.4)),
            const SizedBox(height: 14),
            const Text('单词匹配', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final mark in result.referenceMarks)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: mark.isMatch
                          ? const Color(0xFFE5F3EE)
                          : const Color(0xFFFCE9E4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      mark.word,
                      style: TextStyle(
                        color: mark.isMatch
                            ? const Color(0xFF146B52)
                            : const Color(0xFFA13B2B),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: 30),
            const Row(
              children: [
                Icon(Icons.assignment_outlined, color: _teal, size: 20),
                SizedBox(width: 8),
                Text('下一轮跟读要求', style: TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 10),
            for (final requirement in _nextRoundRequirements(result, line))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      color: _teal,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(requirement)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecordingPlaybackButton extends StatefulWidget {
  const _RecordingPlaybackButton({required this.path, this.compact = false});

  final String path;
  final bool compact;

  @override
  State<_RecordingPlaybackButton> createState() =>
      _RecordingPlaybackButtonState();
}

class _RecordingPlaybackButtonState extends State<_RecordingPlaybackButton> {
  final _speech = NativeSpeechService();
  bool _isPlaying = false;
  bool _isLoading = false;
  int _playbackGeneration = 0;

  Future<void> _togglePlayback() async {
    final generation = ++_playbackGeneration;
    if (_isPlaying) {
      await _speech.stopRecordingPlayback();
      if (mounted) setState(() => _isPlaying = false);
      return;
    }

    setState(() => _isLoading = true);
    try {
      final duration = await _speech.playRecording(widget.path);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isPlaying = true;
      });
      await Future<void>.delayed(duration + const Duration(milliseconds: 250));
      if (mounted && generation == _playbackGeneration) {
        setState(() => _isPlaying = false);
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _isPlaying = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message ?? '录音播放失败。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = _isLoading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            _isPlaying ? Icons.stop_circle_outlined : Icons.play_arrow_rounded,
          );
    if (widget.compact) {
      return IconButton(
        tooltip: _isPlaying ? '停止播放' : '播放本次录音',
        onPressed: _isLoading ? null : _togglePlayback,
        icon: icon,
      );
    }
    return OutlinedButton.icon(
      onPressed: _isLoading ? null : _togglePlayback,
      icon: icon,
      label: Text(_isPlaying ? '停止播放' : '播放我的录音'),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '$value',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class CoachPage extends StatefulWidget {
  const CoachPage({
    super.key,
    required this.messages,
    required this.latestAttempt,
    required this.apiBaseUrl,
    required this.accessToken,
    required this.sessionId,
    required this.conversationId,
    required this.onMessagesChanged,
    required this.onConversationIdChanged,
    required this.onApiBaseUrlChanged,
  });

  final List<CoachMessage> messages;
  final AttemptRecord? latestAttempt;
  final String apiBaseUrl;
  final String accessToken;
  final String? sessionId;
  final String? conversationId;
  final VoidCallback onMessagesChanged;
  final ValueChanged<String?> onConversationIdChanged;
  final ValueChanged<String> onApiBaseUrlChanged;

  @override
  State<CoachPage> createState() => _CoachPageState();
}

class _CoachPageState extends State<CoachPage> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send([String? suggested]) async {
    final message = (suggested ?? _controller.text).trim();
    if (message.isEmpty || _sending) return;
    _controller.clear();
    setState(() {
      _sending = true;
      _error = null;
      widget.messages.add(CoachMessage(role: 'user', content: message));
    });
    widget.onMessagesChanged();
    _scrollToBottom();
    try {
      final reply =
          await CoachApi(
            baseUrl: widget.apiBaseUrl,
            accessToken: widget.accessToken,
          ).ask(
            message: message,
            history: widget.messages,
            practiceContext: _practiceContext(widget.latestAttempt),
            sessionId: widget.sessionId,
            conversationId: widget.conversationId,
            practiceAttemptId: widget.latestAttempt?.serverId,
          );
      if (!mounted) return;
      setState(
        () => widget.messages.add(
          CoachMessage(role: 'assistant', content: reply.text),
        ),
      );
      widget.onConversationIdChanged(reply.conversationId);
      widget.onMessagesChanged();
    } on CoachApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  Map<String, Object?>? _practiceContext(AttemptRecord? attempt) {
    if (attempt == null) return null;
    return {
      'accent': attempt.line.accent.englishLabel,
      'reference': attempt.line.text,
      'transcript': attempt.transcript,
      'focus': attempt.line.focus,
      'overall': attempt.result.overall,
      'accuracy': attempt.result.accuracy,
      'completeness': attempt.result.completeness,
      'fluency': attempt.result.fluency,
    };
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _editServer() async {
    final controller = TextEditingController(text: widget.apiBaseUrl);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本机服务地址'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'http://127.0.0.1:8041'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && value.isNotEmpty) widget.onApiBaseUrlChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI 口语教练',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const Text('由阿里百炼提供对话能力'),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '配置服务地址',
                  onPressed: _editServer,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
          ),
          if (widget.latestAttempt != null)
            Container(
              margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF3F1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.auto_awesome_outlined,
                    size: 20,
                    color: _teal,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '已带入最近一次跟读：${widget.latestAttempt!.result.overall} 分',
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              itemCount: widget.messages.length,
              itemBuilder: (context, index) =>
                  _ChatBubble(message: widget.messages[index]),
            ),
          ),
          if (widget.messages.length == 1)
            SizedBox(
              height: 40,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                scrollDirection: Axis.horizontal,
                children: [
                  ActionChip(
                    label: const Text('分析最近跟读'),
                    onPressed: () => _send('请分析我最近一次跟读，并给出三个具体改进点。'),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: const Text('练习连读'),
                    onPressed: () => _send('请给我一组适合 IELTS 的英语连读练习。'),
                  ),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: _Notice(text: _error!, isError: true),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              10,
              20,
              MediaQuery.viewInsetsOf(context).bottom > 0 ? 8 : 16,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: '问发音、表达或 IELTS 答题…',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: '发送',
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message});

  final CoachMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 330),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: isUser ? _navy : Colors.white,
          border: isUser ? null : Border.all(color: _line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          message.content.replaceAll('**', '').replaceAll('✅ ', ''),
          style: TextStyle(color: isUser ? Colors.white : _ink, height: 1.45),
        ),
      ),
    );
  }
}

class ProgressPage extends StatelessWidget {
  const ProgressPage({
    super.key,
    required this.attempts,
    required this.databaseOnline,
    required this.syncing,
    required this.page,
    required this.total,
    required this.totalPages,
    required this.loading,
    required this.onPageChanged,
  });

  final List<AttemptRecord> attempts;
  final bool databaseOnline;
  final bool syncing;
  final int page;
  final int total;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    final average = attempts.isEmpty
        ? 0
        : (attempts.map((item) => item.result.overall).reduce((a, b) => a + b) /
                  attempts.length)
              .round();
    final best = attempts.isEmpty
        ? 0
        : attempts
              .map((item) => item.result.overall)
              .reduce((a, b) => a > b ? a : b);
    return SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: [
          Text('训练进度', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(databaseOnline ? '已保存的全部练习记录' : '当前设备上的本次练习记录'),
          const SizedBox(height: 10),
          _SyncStatus(databaseOnline: databaseOnline, syncing: syncing),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20),
            decoration: BoxDecoration(
              color: _navy,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _SummaryValue(value: '$total', label: '完成次数'),
                ),
                Expanded(
                  child: _SummaryValue(value: '$average', label: '本页均分'),
                ),
                Expanded(
                  child: _SummaryValue(value: '$best', label: '本页最佳'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text('最近练习', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (loading) const LinearProgressIndicator(),
          if (attempts.isEmpty)
            const _EmptyProgress()
          else
            for (final attempt in attempts)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    leading: CircleAvatar(
                      backgroundColor: _scoreColor(
                        attempt.result.overall,
                      ).withValues(alpha: 0.14),
                      foregroundColor: _scoreColor(attempt.result.overall),
                      child: Text(
                        '${attempt.result.overall}',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    title: Text(
                      attempt.line.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      '${attempt.line.accent.label} · ${attempt.line.focus}',
                    ),
                    trailing: attempt.recordingPath == null
                        ? null
                        : _RecordingPlaybackButton(
                            path: attempt.recordingPath!,
                            compact: true,
                          ),
                  ),
                ),
              ),
          if (databaseOnline && totalPages > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: page > 1 && !loading
                        ? () => onPageChanged(page - 1)
                        : null,
                    icon: const Icon(Icons.chevron_left),
                    label: const Text('上一页'),
                  ),
                  Expanded(child: Center(child: Text('$page / $totalPages 页'))),
                  OutlinedButton.icon(
                    onPressed: page < totalPages && !loading
                        ? () => onPageChanged(page + 1)
                        : null,
                    icon: const Icon(Icons.chevron_right),
                    label: const Text('下一页'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SyncStatus extends StatelessWidget {
  const _SyncStatus({required this.databaseOnline, required this.syncing});

  final bool databaseOnline;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    final color = syncing
        ? const Color(0xFFD28B22)
        : databaseOnline
        ? _teal
        : const Color(0xFFA13B2B);
    final label = syncing
        ? '正在同步练习文本与评分'
        : databaseOnline
        ? '数据库已同步 · 录音仅保存在本机'
        : '数据库离线 · 录音和当前结果仍可使用';
    return Row(
      children: [
        Icon(
          syncing
              ? Icons.sync
              : databaseOnline
              ? Icons.cloud_done_outlined
              : Icons.cloud_off_outlined,
          color: color,
          size: 18,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label, style: TextStyle(color: color, fontSize: 13)),
        ),
      ],
    );
  }
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Color(0xFFD6E3EC))),
      ],
    );
  }
}

class _EmptyProgress extends StatelessWidget {
  const _EmptyProgress();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 24),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: _line),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
      ),
      child: const Column(
        children: [
          Icon(Icons.graphic_eq, size: 34, color: _teal),
          SizedBox(height: 10),
          Text('完成第一次跟读后，这里会显示你的得分变化。', textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.isError});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? const Color(0xFFA13B2B) : _teal;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

Color _scoreColor(int score) {
  if (score >= 85) return _teal;
  if (score >= 65) return const Color(0xFFD28B22);
  return _coral;
}

List<String> _nextRoundRequirements(
  PronunciationResult result,
  PracticeLine line,
) {
  final missedWords = result.referenceMarks
      .where((mark) => !mark.isMatch)
      .map((mark) => mark.word)
      .take(4)
      .toList();
  final wordRequirement = missedWords.isEmpty
      ? '保持全部关键词清晰，下一遍尝试减少逐词停顿。'
      : '先单独练习 ${missedWords.join('、')}，每个词清晰读 3 遍。';
  final paceRequirement = result.fluency < 75
      ? '把速度降到示范音频的约 80%，按意群完成整句，不在单词中间停顿。'
      : '保持当前速度，重读内容词，弱化冠词和介词。';
  return [
    wordRequirement,
    paceRequirement,
    '重点检查“${line.focus}”：回放自己的录音 1 次，再听示范并重录。',
  ];
}

String _scoreAdvice(int score) {
  if (score >= 90) return '表达清晰自然，继续保持当前节奏。';
  if (score >= 75) return '整体不错，重点复习标红单词。';
  if (score >= 55) return '放慢一点，先保证每个关键词清晰。';
  return '建议先听示范，再分意群逐段模仿。';
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
