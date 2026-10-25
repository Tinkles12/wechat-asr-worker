# 第三方声明

## integration/files/ 的来源

`integration/files/reader-api.py` 与 `integration/files/hook-onebot.mjs` **派生自**
[sourcepro5/WeChatAgent](https://github.com/sourcepro5/WeChatAgent) v0.4.0（commit `34766b6`）。

上游许可：

```text
MIT License

Copyright (c) 2026 Derpyu520 and qq-bridge / QSH contributors
```

MIT 允许修改与再分发，条件是保留版权声明与许可文本。本仓库整体同样以 MIT 发布，
两者兼容，不存在许可证冲突。

## 改了什么

只加了语音（`local_type = 34`）相关逻辑，逐条列在
[COMPATIBILITY.md](COMPATIBILITY.md) 的「改了什么」一节。文本、图片、表情、文件、
引用、转发、拍一拍的所有路径均未改动。

## 上游之外的依赖

| 组件 | 许可 | 是否随包分发 |
| --- | --- | --- |
| faster-whisper 1.2.1 | MIT | 否（运行时 pip 安装） |
| ctranslate2 4.8.3 | MIT | 否 |
| tokenizers 0.23.3 | Apache-2.0 | 否 |
| onnxruntime 1.31.0 | MIT | 否 |
| huggingface_hub 2.3.0 | Apache-2.0 | 否 |
| pilk 0.2.4 | MIT | **是**（`wheels/` 里是自行编译的 wheel） |
| Systran/faster-whisper-* 模型 | 见其模型仓库 | 否（用户运行时下载） |

## 不包含什么

本仓库**不包含**：

- 微信客户端本身
- WeChat-Hook 的源码或二进制
- `wx_key.dll` 或任何密钥提取工具
- 任何聊天记录、语音样本、账号标识
