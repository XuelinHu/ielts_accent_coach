# IELTS Accent Lab

面向 Android 的雅思口语跟读 APP。Flutter 负责界面，Kotlin 调用 Android 系统语音识别与朗读，Node 本地代理调用阿里云百炼。

## 功能

- 英式、美式、澳式三种口音练习与示范朗读
- IELTS Part 1/2/3 句库、训练重点和发音提示
- 真机语音识别、单词级匹配、准确度/完整度/流利度评分
- 系统识别不可用时，自动录制 16 kHz WAV 并使用百炼 `qwen3-asr-flash`
- 每次跟读保留本地 WAV，可在评分结果和最近练习中回放
- 根据漏词、流利度和当前训练重点生成下一轮跟读要求
- 本次训练进度和最近练习记录
- PostgreSQL 持久化用户、会话、语音转写文本、评分、训练要求和 AI 对话
- APP 启动时按本机安装 ID 恢复历史，录音始终只保存在 Android 本地缓存
- 携带最近一次跟读结果与百炼 AI 教练对话
- API Key 仅保存在 `server/.env`，不会打包进 APK

## 真机运行

在项目根目录打开两个 PowerShell 窗口。

窗口一启动百炼代理：

```powershell
cd D:\workspace\front\ielts_accent_coach\server
npm start
```

首次部署或迁移数据库时先执行：

```powershell
cd D:\workspace\front\ielts_accent_coach\server
npm run db:migrate
```

窗口二建立 USB 端口映射并运行 APP：

```powershell
cd D:\workspace\front\ielts_accent_coach
adb reverse tcp:8041 tcp:8041
$env:FLUTTER_SKIP_UPDATE_CHECK='true'
flutter --no-version-check run
```

APP 默认请求 `http://127.0.0.1:8041`。真机通过 `adb reverse` 访问电脑上的代理，不需要在同一 Wi-Fi 下暴露服务端口。

## 构建 APK

```powershell
cd D:\workspace\front\ielts_accent_coach
$env:FLUTTER_SKIP_UPDATE_CHECK='true'
flutter --no-version-check build apk --debug
```

输出文件：`build\app\outputs\flutter-apk\app-debug.apk`。

## 配置

本机密钥配置位于 `server/.env`，示例见 `server/.env.example`。可调整：

- `DASHSCOPE_API_KEY`：百炼 API Key
- `DASHSCOPE_API_URL`：OpenAI 兼容 Chat Completions 地址
- `DASHSCOPE_MODEL`：默认 `qwen-plus`
- `DASHSCOPE_ASR_MODEL`：语音识别模型，默认 `qwen3-asr-flash`
- `PORT`：本机代理端口，默认 `8041`
- `DB_HOST` / `DB_PORT`：PostgreSQL 地址和端口
- `DB_USER` / `DB_PASSWORD`：PostgreSQL 登录信息
- `DB_NAME`：独立业务数据库，默认 `ielts_accent_lab`
- `DB_SSL`：公网数据库要求 TLS 时设为 `true`

数据库只保存用户身份、会话、参考文本、语音转写文本、评分、训练要求和 AI 对话。WAV 文件保存在 Android 应用缓存目录 `practice_recordings`，转写请求完成后不会写入 PostgreSQL；清理 APP 缓存或卸载 APP 会删除这些本地录音。

## 测试

常规测试：

```powershell
cd D:\workspace\front\ielts_accent_coach\server
npm test
```

PostgreSQL 集成测试会创建/写入数据库并模拟 AI 与 ASR 响应。仅使用以 `_test` 结尾的独立库；测试数据库会保留供检查：

```powershell
cd D:\workspace\front\ielts_accent_coach\server
$env:DB_NAME = 'ielts_accent_lab_local_test'
npm run db:migrate
$env:RUN_POSTGRES_INTEGRATION = '1'
npm run test:integration
```

Android 朗读与识别使用手机当前安装的系统语音服务。若手机缺少某个英语语音包，可在系统的“文字转语音”设置中安装；后续接入 Azure Speech 时，应继续由本机/云端后端持有 Azure Key，不能放入 Flutter 客户端。

## 启动端口

网页入口：原生移动应用，不监听 HTTP 端口；后台服务：8041。完整启动约定见 [PORTS.md](./PORTS.md)。
