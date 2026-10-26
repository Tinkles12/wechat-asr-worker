# asr-worker

把「微信语音的原始字节」变成「一行文字」的独立后台服务。

给 WeChatAgent 用的，但**不依赖 WeChatAgent**：任何能发 HTTP 的程序都能调它。

---

## 为什么是独立进程

不是过度设计，是三个硬约束逼出来的：

| 约束 | 说明 |
| --- | --- |
| **Python 版本冲突** | WeChatAgent 的 `reader-api.py` 跑在安装包自带的 **3.13** 冻结运行时里（没有 pip，不能装包）；faster-whisper 在 **3.12** 下。C 扩展跨小版本不通用，两边不能互相 import。 |
| **资源特征不同** | 读库是「每秒一次、很轻」；ASR 是「CPU 打满、吃 500MB」。放一个进程里，转写会把轮询拖慢。 |
| **失败隔离** | 模型崩了、OOM 了，不应该连带「连消息都收不到」。 |

所以边界是：**3.13 负责“能读到字节”，3.12 负责“把字节变成文字”，两者只说 HTTP + JSON。**

---

## 目录

```text
asr-worker/
├── worker.py            HTTP 服务（/health, /transcribe）
├── schema.json          ★ 契约：请求/响应/错误码，双方都按它校验
├── pyproject.toml       声明依赖（不负责安装）
├── requirements.lock    ★ 锁定精确版本，换机器行为一致
├── bootstrap.ps1        按 lock 重建依赖目录
├── start.ps1            后台启动 + 等就绪 + 写 pid
├── stop.ps1             停止
├── logs/                运行日志（asr.out.log / asr.err.log）
├── run/                 pid 与启动元信息
└── .voice/              依赖与模型（在上一级，可重建，不入库）
    ├── deps/            pip --target 装的包
    └── models/          whisper 模型（~480MB）
```

依赖和模型放在**本目录之外**，是为了删掉重来时不用碰代码。

---

## 快速开始

### 双击党（不用记命令）

```text
Start-ASR.cmd    启动（双击，窗口会显示结果后停住）
Stop-ASR.cmd     停止（双击）
```

推荐的日常顺序：

```text
1. 先启动 WeChatAgent（控制台 / 快捷方式）
2. 再双击 Start-ASR.cmd
3. 看到 `ready : http://127.0.0.1:5032  model=small  pid=xxxxx` 就成了
4. 关闭那个黑窗口（不影响后台服务）
```

**为什么是手动而不是自动跟随**：

- WeChatAgent 每次启动会用模板覆盖 `data\workspace\scripts`，把它挂进 `manage.ps1` 活不过一次重启；
- 要真正做到“它起我也起”，得常驻一个轮询 5031 端口的看门狗进程，多一份复杂度和资源占用；
- 手动一步（双击）换来的是零依赖、零幻觉、出问题一眼能看出是谁没起。

顺序不能反：**ASR 先起、WeChatAgent 后起也没关系**，reader 只在收到语音时才去问 5032；但如果 ASR 没起，语音会进重试队列，5 分钟后静默丢弃（模型不会收到任何消息）。

`Start-ASR.cmd` 是**幂等**的：已经在跑就打印 `already running ... pid=xxx` 并退出 0，不会起第二个实例。

批处理默认优先用 `pwsh`（PowerShell 7+，已测），没有则回退 `powershell`（5.1 上 `start.ps1` 有兼容问题，见「已知坑」）。

### 命令行党

```powershell
# 1) 装依赖（第一次或换机器时；需要网络 + C 编译器）
.\bootstrap.ps1

# 2) 启动（会自动挑 DSH runtime 的 python 3.12）
.\start.ps1

# 3) 看一眼
Invoke-RestMethod http://127.0.0.1:5032/health
```

停止：

```powershell
.\stop.ps1
```

前台调试（能直接看到日志）：

```powershell
.\start.ps1 -Foreground
```

---

## Python 版本怎么选

一台跑着 WeChatAgent 的机器上通常有**三个** Python，别选错：

| Python | 来源 | 能装包吗 | pilk（silk 解码） |
| --- | --- | --- | --- |
| **3.13** | WeChatAgent 自带 | ❌ **没有 pip**，嵌入式隔离 | 用不了 |
| **3.12** | DSH 自带 | ✅ 有 pip | ✅ 随包 `wheels/pilk-*-cp312-*.whl` |
| 3.13 | 系统 | ✅ | ⚠️ 需现场编译（要 VS Build Tools） |
| 3.11 | 系统 | ✅ | ✅ 官方有 wheel |

**推荐直接用 DSH 自带的 3.12**：它是唯一“既有 pip、又有随包 wheel”的组合。`start.ps1` / `bootstrap.ps1` 默认就会找它（`%USERPROFILE%\.dsh\dsh-runtimes\...`）。

**为什么不把依赖装进 WeChatAgent 的 3.13？** 三点：

1. 它没有 pip，装包要手工解压 wheel；
2. 它用封闭的 `_pth` 启动，`site-packages` 不走常规路径，升级 WeChatAgent 时会被整体覆盖；
3. 那个解释器的职责是“读微信库”，不该再背 ASR 的 500MB 依赖。

`bootstrap.ps1` 会先检查版本：不在 **3.9–3.14** 直接拒绝（ctranslate2 没有更老/更新的 wheel），并在缺少匹配 pilk wheel 时明确警告“接下来要编译”。

### 关于 wheel

`wheels/` 里现在只有一份 `pilk-0.2.4-cp312-cp312-win_amd64.whl`（Python 3.12 用）。

其他版本想要“免编译”，把你的机器上 `pip wheel --no-deps pilk` 产出的 wheel 放进来即可：

```powershell
# 例如给 Python 3.13 编译一份
py -3.13 -m pip wheel --no-deps --wheel-dir .\wheels pilk
```

放进去后 `bootstrap.ps1` 会自动优先使用本地 wheel（`--find-links`），不再联网、不再编译。

## 模型下载与离线部署

**仓库不包含模型。** 首次 `start.ps1` 时会从 HuggingFace 自动下载，之后复用本地缓存。

| 项 | 值 |
| --- | --- |
| 默认模型 | `Systran/faster-whisper-small` |
| 体积 | **约 464 MB**（6 个文件） |
| 首次下载耗时 | 实测 225 秒（取决于网络） |
| 缓存位置 | `<asr-worker 上一级>/.voice/models/`，或 `ASR_MODEL_DIR` |

为什么不打包进仓库：

1. GitHub 单文件上限 100 MB，LFS 要额外配额，clone 会变成 464 MB；
2. 模型有自己的许可证，随仓库分发要单独处理；
3. 多数人只需要 `small`，没必要替所有人下。

### 内网 / 离线机器

把整个 `models--Systran--faster-whisper-small` 目录拷过去，放到目标机器的同一位置：

```text
<目标机器>\...\.voice\models\models--Systran--faster-whisper-small\
```

或用 `ASR_MODEL_DIR` 指向你放模型的地方：

```powershell
$env:ASR_MODEL_DIR = 'D:\models'
.\start.ps1
```

模型已在本地时，faster-whisper 不会再联网。

### 国内网络

```powershell
$env:HF_ENDPOINT = 'https://hf-mirror.com'
.\start.ps1
```

### 想更快启动

```powershell
.\start.ps1 -Model tiny     # ~75 MB
.\start.ps1 -Model base     # ~145 MB
```

实测 `small` 对 2 秒语音约 1.3 秒；`tiny` 约 0.4 秒，但中文短句容易漏字。

## 接口

只有两个端点，全部 JSON，只监听 `127.0.0.1`。

### `GET /health`

```json
{ "ok": true, "version": "1.0.0", "model": "small", "device": "cpu",
  "computeType": "int8", "ready": true, "busy": false,
  "served": 4, "failed": 0, "uptimeSec": 120 }
```

`ready=false` 表示模型还在加载（约 1.6 秒）。**先等 `ok=true` 再打流量。**

### `POST /transcribe`

```json
{ "audio": "<base64>", "format": "silk", "language": "zh" }
```

```json
{ "text": "你好大飞鱼", "seconds": 1.94, "inferMs": 1350,
  "waitMs": 0, "model": "small", "language": "zh", "format": "silk" }
```

| 字段 | 取值 | 说明 |
| --- | --- | --- |
| `audio` | base64 字符串 | **必填**。silk 直接放微信库里的 `voice_data` |
| `format` | `silk` / `wav` / `pcm16` | 默认 `silk` |
| `sampleRate` | 8000–48000 | 仅 `pcm16` 需要 |
| `language` | ISO-639-1，默认 `zh` | 填错会明显掉准确率 |
| `prompt` | ≤400 字符 | 中文默认带「简体中文普通话」提示，用于压制繁体输出 |

错误统一返回 `{"error": "ASR_XXX", "detail": "可选"}`，`error` 是**稳定的枚举**（见 `schema.json`），调用方按它分支，不要匹配 `detail`。

```powershell
# 直接拿一条微信语音试（.silk 从你自己的数据目录导出，见上文）
$silk = [IO.File]::ReadAllBytes('.\sample.silk')
$body = @{ audio=[Convert]::ToBase64String($silk); format='silk' } | ConvertTo-Json -Compress
Invoke-RestMethod http://127.0.0.1:5032/transcribe -Method Post `
  -ContentType 'application/json; charset=utf-8' `
  -Body ([Text.Encoding]::UTF8.GetBytes($body))
```

---

## 测试

```powershell
pwsh -File .\tests\run-tests.ps1
```

5 个用例，全部围绕**安装器的状态机**（不依赖模型，秒级完成）：

| 用例 | 验证什么 |
| --- | --- |
| 拒绝指纹不匹配的上游 | 指纹错了就中止，不会打进错误位置 |
| 首次安装 | 文件被替换 + 备份生成 |
| 重复安装 | 幂等，不重复备份 |
| 卸载 | 内容逐字节回到原版 |
| 无备份卸载 | 不误删文件 |

CI 在 `windows-latest` 上跑同一套，外加 `schema.json` 结构校验、`py_compile`、所有 `.ps1` 的语法解析。

## 配置（全部走环境变量）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `ASR_PORT` | `5032` | 监听端口（start.ps1 用 `-Port` 覆盖） |
| `ASR_MODEL` | `small` | `tiny` / `base` / `small` / `medium` / `large-v3` |
| `ASR_DEVICE` | `cpu` | 有 CUDA 可改 `cuda` |
| `ASR_COMPUTE` | `int8` | GPU 上用 `float16` |
| `ASR_LANG` | `zh` | 默认语言 |
| `ASR_TOKEN` | 空 | 设置了就要求 `X-ASR-Token` 头 |
| `ASR_DEPS` | `<上级>/.voice/deps` | 依赖目录 |
| `ASR_MODEL_DIR` | `<上级>/.voice/models` | 模型缓存 |
| `ASR_PYTHON` | 空 | start.ps1/bootstrap.ps1 默认用它挑解释器 |

**端口必须是 5032 吗？** 不是。但 reader-api 接线时会读同一个变量，改端口要两处一起改。

---

## 性能（本机实测，CPU int8）

| 项目 | 数值 |
| --- | --- |
| 模型加载（冷） | 1.6 s |
| 模型首次下载 | 225 s（~480MB） |
| 2 秒语音转写 | 1.2–1.4 s（约 0.6 倍实时） |
| 常驻内存 | ~500 MB |
| 并发 | **串行**（单模型实例 + 全局锁） |

串行是刻意的：ctranslate2 的同一实例并发推理收益很小，还会让延迟抖动。真需要并发就起两个实例、两个端口。

---

## 已知坑（都踩过，别再踩）

**1）`deps/numpy` 会被 Windows Smart App Control 拦**

```
ImportError: DLL load failed while importing _multiarray_umath:
应用程序控制策略已阻止此文件
```

pip 装的 numpy 是未签名二进制，被系统策略拒绝加载（事件日志 `CodeIntegrity` 3033/3077）。

**解法**：worker 用 `sys.path.append(deps)`（而不是 `PYTHONPATH`），让**宿主 Python 自带的 numpy** 优先；`bootstrap.ps1` 装完会主动删掉 `deps/numpy*`。

**2）faster-whisper 1.2.1 和 PyAV 19 不兼容**

```
TypeError: open() got an unexpected keyword argument 'metadata_errors'
```

它读音频文件时走 PyAV。**解法**：worker 不读文件——自己用 `wave` 读、重采样成 16k、把 `np.float32` 数组喂给 `model.transcribe()`。

**3）`pilk.decode` 的两个参数都必须是文件路径**

不接受 `None`、不接受 bytes。**解法**：临时文件进、临时文件出，`finally` 里删。

**4）装 pilk 需要 C 编译器**

PyPI 上没有 cp312 的预编译 wheel，会现场编译。没有 MSVC 就装不上，会报 `error: Microsoft Visual C++ 14.0 or greater is required`。

**5）在 DSH 沙箱里跑 pip 会失败**

pip 用 `tempfile.mkdtemp` 建 0o700 的临时目录，沙箱 token 写不进去，报 `PermissionError: ...whl.metadata`。**解法**：在普通 pwsh 里跑 `bootstrap.ps1`（本次就是这么装成功的），不要在受限沙箱里装。

**6）中文会混繁体**

whisper 的中文输出可能一半简体一半繁体（`大飞鱼` / `大飛魚`）。worker 默认带 `initial_prompt="以下是简体中文普通话对话。"` 压制，但**不能完全消除**。要彻底解决，转写后再过一遍 opencc 简繁转换。

**7）Windows PowerShell 5.1 跑不了 `start.ps1`**

现象：

```
start.ps1 : Cannot bind argument to parameter 'LiteralPath' because it is null.
```

`pwsh`（PowerShell 7+）跑同样的脚本完全正常。**解法**：`Start-ASR.cmd` / `Stop-ASR.cmd` 默认优先 `pwsh`，找不到才回退 `powershell`。

**8）`.cmd` 里不能出现中文**

批处理按 ANSI 代码页（936）解码，UTF-8 的中文注释会被拆成命令执行，报一堆 `'xxx' 不是内部或外部命令`。**解法**：两个 `.cmd` 全部纯 ASCII，注释也用英文。加了 BOM 同样会出问题。

**9）`start.ps1` 必须幂等**

原本端口被占用就直接 `throw`。双击场景下这会让用户以为“失败了”。现在改成：先探 `/health`，`ok:true` 就打印 `already running` 并返回 0；只有端口被**别的程序**占用时才报错。

---

## 版本矩阵（本机验证通过的组合）

```text
Python          3.12.14  (DSH runtime)
faster-whisper  1.2.1
ctranslate2     4.8.3
tokenizers      0.23.3
onnxruntime     1.31.0
pilk            0.2.4    (cp312, 现场编译)
numpy           2.3.5    (宿主 Python 提供，非 deps)
模型            Systran/faster-whisper-small (int8)
```

---

## 下一步：接进 WeChatAgent

本服务只负责「字节 → 文字」。要让它对微信生效，还需要给 WeChatAgent 打一个小补丁。

### 一键接入（推荐）

前提：对方已经有一个能正常收发消息的 WeChatAgent **v0.4.0**。

```powershell
# 1) 起本服务
.\bootstrap.ps1
.\start.ps1
Invoke-RestMethod http://127.0.0.1:5032/health

# 2) 给 WeChatAgent 打补丁（先 dry-run 看清楚再动手）
.\integration\install.ps1 -ProjectRoot 'D:\WeChatAgent' -DryRun
.\integration\install.ps1 -ProjectRoot 'D:\WeChatAgent'

# 3) 重启 WeChatAgent 服务
```

`install.ps1` 会做四件事：**探测安装路径 → 校验原版指纹 → 备份 → 替换两个文件**。
指纹不匹配会直接拒绝，避免把补丁打进改过的代码里。

回滚：

```powershell
.\integration\uninstall.ps1 -ProjectRoot 'D:\WeChatAgent'
```

细节见 [integration/COMPATIBILITY.md](integration/COMPATIBILITY.md)。

### 补丁改了什么

| 文件 | 改动 |
| --- | --- |
| `reader-api.py` | 放行 `type=34`、取 `voicelength`、`/api/v1/voices/<svr_id>`、异步转写编排、`/status` 加 `voice` 字段 |
| `hook-onebot.mjs` | 第二道类型白名单放行 34 |

**没动**：文本、图片、表情、文件、引用、转发、拍一拍的任何路径。

### 手工接线的三步（不想用脚本时）

1. `reader-api.py` 增加 `GET /api/v1/voices/<svr_id>`：从 `media_0.db` 的 `VoiceInfo` 取 `voice_data`，base64 返回。**3.13 侧不需要 pilk**，所以这一层没有新依赖。
2. `push_payload()` 里对 `type=34` 先推 `[语音 2.2 秒，内容未转写]`。
3. 异步补推：拿到文本后，按 `svr_id` 生成幂等键，再推 `[语音内容] xxx`。

失败时必须降级成明确的占位（`[语音 8 秒，转写失败，未提供内容]`），**不要让模型猜**——这是这个项目里图片链路已经验证过的原则。

---

## 清理

```powershell
.\stop.ps1
Remove-Item ..\.voice\deps   -Recurse -Force   # 依赖
Remove-Item ..\.voice\models -Recurse -Force   # 模型（~480MB）
```

代码本身没有任何全局副作用：不写注册表、不装服务、不改 PATH。
