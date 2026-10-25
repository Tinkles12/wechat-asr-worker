# 兼容性与改动说明

## 适配的上游

| 项 | 值 |
| --- | --- |
| 项目 | [sourcepro5/WeChatAgent](https://github.com/sourcepro5/WeChatAgent) |
| 版本 | **v0.4.0**（commit `34766b6`） |
| 部署形态 | 源码版（`<root>\scripts`）与安装版（`<root>\data\workspace\scripts`）都支持 |
| 验证环境 | Windows 11 · 微信 4.1.10.27 · 内置 Python 3.13 · Node 22 |

`install.ps1` 会在动手前校验两个原版文件的指纹（换行统一成 LF 后的 SHA256）：

```text
reader-api.py     fba96bd6b52ce8bd0c9f1f618dc63095e8749417ddfb4cc97d69b4c22be326c9
hook-onebot.mjs   7b407c48359108402b7f3f2268bc56d5f688bbfc75c167306384e18493abca10
```

**不匹配就拒绝安装**——宁可装不上，也不要把补丁打进改过的代码里。

## 改了什么

只动两个文件、六个行为，全部围绕 `local_type = 34`（微信语音）：

| # | 文件 | 行为 |
| --- | --- | --- |
| 1 | `reader-api.py` | 放行 `type=34`，从 XML 取 `voicelength` |
| 2 | `reader-api.py` | 生成占位 `[语音 2.2 秒，内容未转写]` |
| 3 | `reader-api.py` | 新增 `GET /api/v1/voices/<svr_id>`，从 `media_0.db` 的 `VoiceInfo` 取 silk |
| 4 | `reader-api.py` | 异步转写：`queue_voice` → ASR → `flush_voice`（4 秒截止） |
| 5 | `reader-api.py` | `/api/v1/reader/status` 增加 `voice` 字段 |
| 6 | `hook-onebot.mjs` | 第二道类型白名单放行 34 |

**没有改**：文本、图片、表情、文件、引用、转发、拍一拍的任何路径；消息格式；DSH 插件。

## 依赖的外部服务

```text
asr-worker  →  http://127.0.0.1:5032
               可用 ASR_URL 环境变量覆盖
```

**它是可选的**。没起 worker 时，语音降级成占位文本，其它功能照旧——不会因为“没装 ASR”就连消息都收不到。

## 什么情况下会失效

| 情况 | 表现 | 处理 |
| --- | --- | --- |
| 上游升级到 v0.4.1+ | `install.ps1` 指纹校验失败 | 等适配版，或自己看 diff 手工合并 |
| 上游改了 `poll()` / `push_payload()` | 补丁能装上但行为错 | 同一原因：不要跨版本硬打 |
| asr-worker 没启动 | 语音只有占位 | 起 worker，或忽略 |
| 语音不在本机缓存 | 只有占位（`VOICE_NOT_FOUND`） | 无法补救，见下 |
| 之前已装过 | `install.ps1` 报 skip | 正常，幂等 |

## 已知限制（不是 bug）

1. **语音必须已在本地缓存**。`media_0.db` 的 `VoiceInfo` 只存落过盘的音频；没下载的语音取不到字节，只能占位。
2. **不做语音转写之外的媒体**。视频、位置、小程序卡片仍然丢弃（上游本来就不支持）。
3. **转写串行**。asr-worker 单实例，4 条并发时后 3 条要排队（每条约 1.3 秒）。
4. **简繁可能混用**。whisper 中文的固有毛病，worker 已带 `initial_prompt` 压制，不能完全消除。
5. **4 秒截止**。超时就发占位，宁可没内容也不让消息卡住。

## 安装

```powershell
# 1) 先把 asr-worker 跑起来
..\bootstrap.ps1
..\start.ps1
Invoke-RestMethod http://127.0.0.1:5032/health

# 2) 打补丁（自动探测安装路径；不确定就先 -DryRun）
.\install.ps1 -DryRun
.\install.ps1 -ProjectRoot 'D:\WeChatAgent'

# 3) 重启 WeChatAgent 服务
```

## 卸载

```powershell
.\uninstall.ps1 -ProjectRoot 'D:\WeChatAgent'            # 回到最近一次备份
.\uninstall.ps1 -ProjectRoot 'D:\WeChatAgent' -ToOriginal  # 回到最原始版本
```

备份命名：`reader-api.py.bak-wechatagent-voice-<yyyyMMdd-HHmmss>`，不会被自动清理。

## 安全边界

- 补丁只读写 `<scripts>` 目录下的两个文件，不碰数据库、配置、日志。
- 不发起任何网络请求（除了运行时调 `127.0.0.1:5032`）。
- 不创建服务、不写注册表、不改 PATH。
- `install.ps1` 里没有任何“下载”动作，全部来自本目录的 `files/`。
