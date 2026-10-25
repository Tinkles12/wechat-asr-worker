"""WeChatAgent ASR worker.

把「微信语音原始字节」变成「一行文字」。独立进程的原因见 README.md：
它依赖 faster-whisper（CPU 密集、吃内存、且有 C 扩展版本约束），
不适合塞进 reader-api.py 所在的 3.13 冻结运行时。

接口契约见 schema.json。只监听 127.0.0.1。
"""
from __future__ import annotations

import base64
import binascii
import json
import os
import pathlib
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = '1.0.0'
HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent

# deps 用 append：site-packages 里的 numpy 优先。
# .voice/deps 里的 numpy 是 pip 装的原版，会被 Windows Smart App Control
# 拒绝加载（"应用程序控制策略已阻止此文件"），见 README 的「已知坑」。
DEPS = pathlib.Path(os.environ.get('ASR_DEPS') or ROOT / '.voice' / 'deps')
MODEL_DIR = pathlib.Path(os.environ.get('ASR_MODEL_DIR') or ROOT / '.voice' / 'models')
MODEL_NAME = os.environ.get('ASR_MODEL', 'small')
DEVICE = os.environ.get('ASR_DEVICE', 'cpu')
COMPUTE = os.environ.get('ASR_COMPUTE', 'int8')
PORT = int(os.environ.get('ASR_PORT', '5032'))
TOKEN = os.environ.get('ASR_TOKEN', '').strip()
DEFAULT_LANG = os.environ.get('ASR_LANG', 'zh')
MAX_BODY = 8 * 1024 * 1024  # 8MB：够放 30 秒内的高清 wav

if DEPS.is_dir():
    sys.path.append(str(DEPS))

import numpy as np  # noqa: E402
from faster_whisper import WhisperModel  # noqa: E402

MODEL = None
LOCK = threading.Lock()      # whisper 实例不做并发推理
STATE = {'busy': False, 'served': 0, 'failed': 0, 'started': time.time()}


def log(line: str) -> None:
    print('%s %s' % (time.strftime('%Y-%m-%d %H:%M:%S'), line), flush=True)


def pcm_from_silk(raw: bytes) -> tuple[bytes, int]:
    """silk -> 16k 单声道 s16le。pilk 的两个参数都必须是文件路径，所以走临时文件。"""
    import pilk
    handle, silk_path = tempfile.mkstemp(prefix='asr-silk-', suffix='.silk')
    os.close(handle)
    pcm_path = silk_path + '.pcm'
    try:
        pathlib.Path(silk_path).write_bytes(raw)
        pilk.decode(silk_path, pcm_path, 16000, 0)   # decode(输入, 输出, 采样率, 丢包)
        pcm = pathlib.Path(pcm_path).read_bytes()
        if not pcm:
            raise RuntimeError('ASR_SILK_DECODE_EMPTY')
        return pcm, 16000
    finally:
        for path in (silk_path, pcm_path):
            try:
                os.unlink(path)
            except OSError:
                pass


def pcm_from_wav(raw: bytes) -> tuple[bytes, int]:
    import io
    import wave
    with wave.open(io.BytesIO(raw), 'rb') as handle:
        if handle.getsampwidth() != 2:
            raise RuntimeError('ASR_WAV_NOT_16BIT')
        rate = handle.getframerate()
        channels = handle.getnchannels()
        frames = handle.readframes(handle.getnframes())
    if channels > 1:
        data = np.frombuffer(frames, dtype='<i2').reshape(-1, channels).mean(axis=1)
        frames = data.astype('<i2').tobytes()
    return frames, rate


def to_float32(pcm: bytes, rate: int) -> np.ndarray:
    audio = np.frombuffer(pcm, dtype='<i2').astype(np.float32) / 32768.0
    if rate != 16000:
        count = int(round(len(audio) * 16000 / rate))
        audio = np.interp(np.linspace(0, len(audio) - 1, count),
                          np.arange(len(audio)), audio).astype(np.float32)
    return audio


def transcribe(body: dict) -> dict:
    audio_b64 = body.get('audio')
    if not isinstance(audio_b64, str) or not audio_b64:
        raise ValueError('ASR_MISSING_AUDIO')
    try:
        raw = base64.b64decode(audio_b64, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError('ASR_INVALID_BASE64')
    if not raw:
        raise ValueError('ASR_EMPTY_AUDIO')

    fmt = (body.get('format') or 'silk').lower()
    if fmt == 'silk':
        pcm, rate = pcm_from_silk(raw)
    elif fmt == 'wav':
        pcm, rate = pcm_from_wav(raw)
    elif fmt == 'pcm16':
        pcm, rate = raw, int(body.get('sampleRate') or 16000)
    else:
        raise ValueError('ASR_UNSUPPORTED_FORMAT')

    audio = to_float32(pcm, rate)
    seconds = round(len(audio) / 16000, 2)
    language = body.get('language') or DEFAULT_LANG
    prompt = body.get('prompt') or '以下是简体中文普通话对话。'

    started = time.time()
    arrived = started
    with LOCK:
        started = time.time()          # 排队结束、真正开始推理
        STATE['busy'] = True
        try:
            segments, _info = MODEL.transcribe(
                audio, language=language, beam_size=5, vad_filter=True,
                initial_prompt=prompt if language.startswith('zh') else None)
            text = ''.join(segment.text for segment in segments).strip()
        finally:
            STATE['busy'] = False
    STATE['served'] += 1
    return {
        'text': text,
        'seconds': seconds,
        'inferMs': int((time.time() - started) * 1000),
        'waitMs': int((started - arrived) * 1000),
        'model': MODEL_NAME,
        'language': language,
        'format': fmt,
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'asr-worker/' + VERSION
    sys_version = ''

    def log_message(self, fmt, *args):  # 不让默认日志污染 stdout
        log('http %s' % (fmt % args))

    def _send(self, status: int, body: dict) -> None:
        raw = json.dumps(body, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(raw)

    def _authorized(self) -> bool:
        if not TOKEN:
            return True
        supplied = self.headers.get('X-ASR-Token', '')
        import hmac
        return hmac.compare_digest(supplied, TOKEN)

    def do_GET(self):  # noqa: N802
        if self.path.split('?')[0] != '/health':
            return self._send(404, {'error': 'ASR_NOT_FOUND'})
        if not self._authorized():
            return self._send(401, {'error': 'ASR_UNAUTHORIZED'})
        return self._send(200, {
            'ok': MODEL is not None,
            'version': VERSION,
            'model': MODEL_NAME,
            'device': DEVICE,
            'computeType': COMPUTE,
            'ready': MODEL is not None,
            'busy': STATE['busy'],
            'served': STATE['served'],
            'failed': STATE['failed'],
            'uptimeSec': int(time.time() - STATE['started']),
        })

    def do_POST(self):  # noqa: N802
        if self.path.split('?')[0] != '/transcribe':
            return self._send(404, {'error': 'ASR_NOT_FOUND'})
        if not self._authorized():
            return self._send(401, {'error': 'ASR_UNAUTHORIZED'})
        try:
            length = int(self.headers.get('Content-Length') or 0)
        except ValueError:
            return self._send(400, {'error': 'ASR_BAD_LENGTH'})
        if length <= 0:
            return self._send(400, {'error': 'ASR_EMPTY_BODY'})
        if length > MAX_BODY:
            return self._send(413, {'error': 'ASR_BODY_TOO_LARGE'})
        try:
            body = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeDecodeError):
            return self._send(400, {'error': 'ASR_INVALID_JSON'})
        if not isinstance(body, dict):
            return self._send(400, {'error': 'ASR_INVALID_JSON'})
        try:
            result = transcribe(body)
        except ValueError as error:
            STATE['failed'] += 1
            return self._send(400, {'error': str(error)})
        except Exception as error:      # 解码器/模型异常
            STATE['failed'] += 1
            log('transcribe failed: %s: %s' % (type(error).__name__, error))
            import traceback
            traceback.print_exc()
            return self._send(500, {'error': 'ASR_TRANSCRIBE_FAILED',
                                    'detail': type(error).__name__})
        return self._send(200, result)


def main() -> int:
    global MODEL
    log('asr-worker %s starting (deps=%s)' % (VERSION, DEPS))
    try:
        import numpy as _np
        log('numpy %s <- %s' % (_np.__version__, pathlib.Path(_np.__file__).parent))
    except Exception as error:
        log('numpy import failed: %s' % error)
        return 2
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    started = time.time()
    MODEL = WhisperModel(MODEL_NAME, device=DEVICE, compute_type=COMPUTE,
                         download_root=str(MODEL_DIR))
    log('model %s ready in %.1fs' % (MODEL_NAME, time.time() - started))

    server = ThreadingHTTPServer(('127.0.0.1', PORT), Handler)
    server.daemon_threads = True
    log('listening http://127.0.0.1:%d  (token=%s)' % (PORT, 'on' if TOKEN else 'off'))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log('stopping')
    finally:
        server.server_close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
