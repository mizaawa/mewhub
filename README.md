<div align="center">
  <img src="assets/images/icon.png" width="112" alt="MewHub icon" />
  <h1>MewHub</h1>
  <p>A warm, milk-white AI chat client for Android and iOS, built with Flutter.</p>
  <p>
    <a href="https://github.com/mizaawa/mewhub/actions/workflows/ci.yml"><img src="https://github.com/mizaawa/mewhub/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
    <a href="https://github.com/mizaawa/mewhub/releases/latest"><img src="https://img.shields.io/github/v/release/mizaawa/mewhub?include_prereleases" alt="Release" /></a>
  </p>
  <p><a href="#中文">中文</a> · <a href="#english">English</a></p>
</div>

---

## 中文

MewHub 是一个多供应商 AI 聊天客户端，功能参考 [RikkaHub](https://github.com/rikkahub/rikkahub)，用 Flutter 重写以同时支持 Android 与 iOS。界面是奶白色系，动画贯穿全程。

### 功能

- **四种协议原生实现**：OpenAI Chat Completions、OpenAI Responses、Anthropic Messages、Google Gemini，全部流式输出
- **任意第三方 API**：自定义 Base URL / 路径 / 请求头 / 请求体，多 Key 轮询，余额查询；内置 DeepSeek、OpenRouter、硅基流动、月之暗面、百炼、火山、智谱、xAI、Ollama 等模板
- **导入配置**：扫码 / 剪贴板导入，兼容 RikkaHub 的 `ai-provider:v1:` 分享码与通用 JSON
- **深度思考**：思考强度滑动条六档（auto / low / medium / high / xhigh / max），模型不支持的档位自动降级，新对话沿用上次的模型与强度；输入框可一键展开全屏编辑；按厂商自动转换参数（Claude adaptive thinking、OpenAI reasoning effort、Gemini thinkingConfig、DeepSeek/Qwen/GLM/Kimi 开关），思考过程可折叠；签名与加密推理内容会正确回传，多轮工具调用不丢上下文
- **工具调用（Agent 循环）**：联网搜索（Bing 免 Key、Tavily、Exa、Brave、Serper、Jina、智谱、博查、Perplexity、SearXNG、LinkUp）、网页读取、长期记忆、计算器、时间、剪贴板、设备信息；运行前可要求确认
- **MCP**：远程 Streamable HTTP 与 SSE 服务器，按工具开关
- **模型内置能力**：OpenAI / Claude / Gemini 原生联网搜索、Gemini URL 上下文、生图模型
- **多模态**：图片、拍照、PDF / Word / PPT / Excel / EPUB / 代码等文档（本地提取文本）
- **对话管理**：历史页支持置顶、侧滑删除与撤销、保留置顶并清理其余记录；消息搜索可按当前 / 所有助手筛选，按相关度或时间排序并高亮命中；另有分支、分叉、收藏、上下文压缩、Markdown / JSON 导出
- **后台会话**：发送后立即进入侧栏，可切换到新对话而不打断旧回复；生成中的标题旁显示进度，Android 后台持续流式生成并在完成时按通知设置提醒；相册多选图片会逐张进入裁剪、旋转和标记编辑器。iOS 后台运行时间由系统限制。
- **助手**：系统提示词变量、开场白、预设消息、消息模板、正则替换、世界书与模式注入、独立参数与背景图；导入 SillyTavern 角色卡（PNG / JSON，V1-V3）与世界书
- **其它**：翻译、绘图、语音输入、朗读、标题与追问建议自动生成、用量统计、请求日志、WebDAV 与本地备份、浅色 / 深色 / 六种主题色、中英双语、平板双栏布局

### 安全与隐私

- API Key、WebDAV 密码、MCP 请求头存放在系统钥匙串 / Android Keystore，不写入普通文件
- 所有数据只在 App 沙盒内；没有统计和广告；只会请求你配置的地址
- 默认只允许 HTTPS，明文 HTTP 仅限本机回环地址（本地模型）
- 权限按需申请：相机、麦克风、语音识别、相册、通知都只在你使用对应功能时询问

### 安装

到 [Releases](https://github.com/mizaawa/mewhub/releases) 下载：

- **Android**：大多数手机选 `arm64-v8a.apk`，不确定就选 `universal.apk`
- **iOS**：`ios-unsigned.ipa` 未签名，用 AltStore / SideStore / Sideloadly / TrollStore 安装（会用你自己的 Apple ID 重新签名）

### 开发

```bash
flutter pub get
flutter analyze
flutter test
flutter run
```

需要 Flutter 3.47+ / Dart 3.13+。Android 最低 7.0（API 24），iOS 最低 15.0。

### 发布新版本

1. 修改 `pubspec.yaml` 的 `version`
2. 打标签并推送：`git tag v1.2.3 && git push origin v1.2.3`
3. `Release` 工作流会构建 APK / AAB / IPA 并发布到 GitHub Release

首次发布前，在仓库 Settings → Secrets and variables → Actions 中配置以下四个 Secrets。CI 主分支 APK 和 Release APK/AAB 都使用同一份 JKS；缺少任意一项时构建会失败，避免发布无法覆盖升级的临时签名包。

| Secret | 说明 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | JKS 文件的单行 Base64；PowerShell：`[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path .\release.jks)))` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | key 别名 |
| `ANDROID_KEY_PASSWORD` | key 密码 |

请保管并备份原始 JKS 和密码，以后的版本继续使用同一密钥；如果已有正式签名密钥，应沿用原密钥。此前用临时 debug 签名安装的 APK 切换到固定签名时仍需卸载一次，此后同签名且 `versionCode` 不低于已安装版本即可覆盖升级。PR 只检查 debug 签名构建，不上传可安装的 APK。

如果还没有 JKS，可执行一次 `keytool -genkeypair -keystore release.jks -storetype JKS -alias mewhub -keyalg RSA -keysize 4096 -validity 10000` 创建，再将同一文件和密码保存为上面的 Secrets。CI 和 Release 使用各自的构建号；跨两种渠道安装时还需确认新 APK 的 `versionCode` 更高。

---

## English

MewHub is a multi-provider AI chat client inspired by [RikkaHub](https://github.com/rikkahub/rikkahub), rebuilt in Flutter for Android and iOS, with a milk-white theme and motion throughout.

**Highlights:** native OpenAI Chat / OpenAI Responses / Anthropic / Gemini streaming; any compatible gateway with custom URLs, headers, bodies and key rotation; reasoning controls mapped per vendor; agent tool loop with web search, page reading, memory and MCP; vision and document attachments; editable gallery photos; parallel background chats with Android streaming and completion notifications; a conversation history page with pinning, swipe-to-delete and undo, plus message search scoped by assistant with relevance/time sorting and highlighted matches; message branches, forks, favorites and context compression; assistants with lorebooks, regexes and SillyTavern card import; translation, image generation, voice input, TTS, usage stats, WebDAV backup; light/dark themes, Chinese and English.

**Privacy:** keys live in the iOS Keychain / Android Keystore; data stays in the app sandbox; no analytics; requests go only to endpoints you configure.

**Install:** grab an APK (Android) or the unsigned IPA (iOS, sideload with AltStore/SideStore) from [Releases](https://github.com/mizaawa/mewhub/releases).

**Build:** `flutter pub get && flutter test && flutter run` (Flutter 3.47+). Push a `vX.Y.Z` tag to publish a release.

## License

[AGPL-3.0](LICENSE). MewHub's feature set follows RikkaHub (AGPL-3.0); the code here is an independent Flutter implementation.
