"""Voxtral TTS for Pithagoras on Apple Silicon, on OpenAI's /v1/audio/speech.

mistralai/Voxtral-4B-TTS-2603 running in MLX, for the portal's Voice servers
extension, which asks in one of two ways:

  response_format "wav"   Fixed voices: the phrase as one 24 kHz mono WAV. A
                          "voice" names a Voxtral voice (de_female, …).
  anything else           Breeze-TTS-2 through audio.cpp: raw 24 kHz mono s16le
                          PCM, streamed while it is spoken.

Voxtral's voices are tied to a language, so without a voice of its own a phrase
gets one by the language of its text. Fields sent for Breeze (instruction,
guidance, reference audio) have no meaning here and are ignored.

Environment:
  VOXTRAL_MODEL      default mlx-community/Voxtral-4B-TTS-2603-mlx-4bit
  VOXTRAL_STEPS      flow-matching steps, default 6 (model default 8; fewer is faster)
  VOXTRAL_VOICE_DE   default de_female
  VOXTRAL_VOICE_EN   default casual_female
  VOXTRAL_HOST/PORT  default 127.0.0.1:7864
"""

import io
import json
import os
import re
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import mlx.core as mx
import numpy as np
from mlx_audio.tts.models.voxtral_tts.acoustic_head import FlowMatchingAudioTransformer
from mlx_audio.tts.utils import load_model

MODEL = os.environ.get("VOXTRAL_MODEL", "mlx-community/Voxtral-4B-TTS-2603-mlx-4bit")
STEPS = int(os.environ.get("VOXTRAL_STEPS", "6"))
VOICE_DE = os.environ.get("VOXTRAL_VOICE_DE", "de_female")
VOICE_EN = os.environ.get("VOXTRAL_VOICE_EN", "casual_female")
HOST = os.environ.get("VOXTRAL_HOST", "127.0.0.1")
PORT = int(os.environ.get("VOXTRAL_PORT", "7864"))
SAMPLE_RATE = 24000

# Words that are common in German and rare in English. Umlauts and ß settle it
# on their own; otherwise two hits are enough for a sentence-sized chunk.
GERMAN = re.compile(
    r"\b(und|ich|nicht|das|die|der|ist|ein|eine|du|dir|dich|mir|mich|wir|sie|es|zu|mit|"
    r"auf|für|noch|schon|auch|aber|oder|wenn|dann|bitte|danke|gerne|gern|habe|hast|kann|"
    r"kannst|soll|jetzt|hier|dort|keine|kein|wie|was|warum|ja|nein)\b",
    re.IGNORECASE,
)


# Stage directions the LLM writes into spoken replies: "(chuckles)", "(plays a
# bit of piano music)", "*sighs*". The portal invites a few such cues for Breeze.
# Voxtral has no tags for them: it improvises on the words, so laughter comes
# out as moaning, "(very quiet)" as speaking from across a hall, and "music" is
# attempted.
#
# What Voxtral does well is interjections — it gives "Haha," or "Hmm," the
# prosody they call for. So a cue with a sound of its own becomes that sound,
# spoken; a gesture, a volume or a soundtrack has none and is dropped.
# Longer parentheses are asides — "(You should be aware that …)", often in
# another language than the reply — and are dropped whole: read out, they sound
# like a second answer.
STAGE_DIRECTION = re.compile(r"\(([^()]{1,800})\)|\[([^\[\]]{1,80})\]|\*([^*\n]{1,80})\*")
CUE_MAX = 40
# (pattern in the cue, German, English) — first match wins.
INTERJECTIONS = [
    (r"laugh|lach|giggl|kicher", "Haha,", "Haha,"),
    (r"chuckl|schmunzel|grins|grin|smil|lächel", "Heh,", "Heh,"),
    (r"sigh|seufz|exhal|stöhn|groan", "Hach,", "Ahh,"),
    (r"clears? (his |her |their )?throat|räusper|cough|hust", "Ähem,", "Ahem,"),
    (r"hmm|thinks|thinking|ponder|überleg|nachdenk", "Hm,", "Hmm,"),
    (r"gasp|surpris|überrasch|staun", "Oh,", "Oh,"),
]
SILENCE = np.zeros(int(0.05 * 24000), dtype="<i2").tobytes()


def speakable(text: str, german: bool) -> str:
    def replace(match: re.Match) -> str:
        cue = next(g for g in match.groups() if g).lower()
        if len(cue) > CUE_MAX:
            return " "
        for pattern, de, en in INTERJECTIONS:
            if re.search(pattern, cue):
                return f" {de if german else en} "
        return " "

    spoken = STAGE_DIRECTION.sub(replace, text)
    # Two cues in a row ("Haha, Haha,") read as one.
    spoken = re.sub(r"\b(\w+,)(\s+\1)+", r"\1", spoken)
    spoken = re.sub(r"\s{2,}", " ", spoken).strip(" ;:")
    # A reply that was only a cue ("(laughs)") still ends like a sentence.
    return re.sub(r",$", ".", spoken)


def wav_of(pcm: bytes) -> bytes:
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm)
    return out.getvalue()


def voice_for(text: str) -> str:
    if re.search(r"[äöüÄÖÜß]", text) or len(GERMAN.findall(text)) >= 2:
        return VOICE_DE
    return VOICE_EN


print(f"loading {MODEL} ({STEPS} steps)", flush=True)
model = load_model(MODEL)
for module in (m for _, m in model.named_modules() if isinstance(m, FlowMatchingAudioTransformer)):
    module.args.n_denoising_steps = STEPS
# Compile Metal kernels now rather than on the first reply somebody waits for.
for _ in model.generate(text="Ready.", voice=VOICE_EN):
    pass
print(f"ready on {HOST}:{PORT}", flush=True)

# One generation at a time: a second request answers 409, which the portal
# already treats as "busy, retry shortly".
busy = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # body ends when the connection closes

    def log_message(self, fmt, *args):
        pass

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"status": "ok", "model": MODEL, "steps": STEPS})
        self._json(404, {"error": "not found"})

    def _wav(self, pcm: bytes, voice: str):
        body = wav_of(pcm)
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Voice", voice)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/v1/audio/speech":
            return self._json(404, {"error": "not found"})
        try:
            request = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
            text = str(request.get("input") or "").strip()
        except ValueError:
            return self._json(400, {"error": "body must be JSON"})
        if not text:
            return self._json(400, {"error": "input required"})
        wav = request.get("response_format") == "wav"
        asked = str(request.get("voice") or "").strip()
        voice = asked if wav and re.fullmatch(r"[a-z]+(_[a-z]+)+", asked) else voice_for(STAGE_DIRECTION.sub(" ", text))
        spoken = speakable(text, german=voice == VOICE_DE or voice.startswith("de_"))
        if not re.search(r"\w", spoken):
            if wav:
                return self._wav(SILENCE, voice)
            # Nothing left to say. A short silence rather than an error: the
            # portal treats an empty body as a failed synthesis.
            self.send_response(200)
            self.send_header("Content-Type", "audio/pcm")
            self.send_header("X-Sample-Rate", str(SAMPLE_RATE))
            self.end_headers()
            self.wfile.write(SILENCE)
            print(f"skipped stage direction: {text[:60]!r}", flush=True)
            return
        text = spoken
        if not busy.acquire(blocking=False):
            return self._json(409, {"error": "busy"})
        if wav:
            try:
                started = time.time()
                chunks = [np.array(r.audio, dtype=np.float32).reshape(-1) for r in model.generate(text=text, voice=voice)]
                audio = np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
                self._wav((np.clip(audio, -1.0, 1.0) * 32767.0).astype("<i2").tobytes(), voice)
                print(f"{voice} {audio.size / SAMPLE_RATE:.1f}s audio (wav) in {time.time() - started:.2f}s: {text[:60]!r}", flush=True)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as e:  # an unknown voice, for one
                try:
                    self._json(400, {"error": str(e)})
                except OSError:
                    pass
            finally:
                mx.clear_cache()
                busy.release()
            return
        try:
            started = time.time()
            self.send_response(200)
            self.send_header("Content-Type", "audio/pcm")
            self.send_header("X-Sample-Rate", str(SAMPLE_RATE))
            self.send_header("X-Sample-Format", "s16le")
            self.send_header("X-Voice", voice)
            self.end_headers()
            samples = 0
            for result in model.generate(text=text, voice=voice, stream=True, streaming_interval=0.5):
                audio = np.array(result.audio, dtype=np.float32).reshape(-1)
                if not audio.size:
                    continue
                pcm = (np.clip(audio, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()
                self.wfile.write(pcm)
                self.wfile.flush()
                samples += audio.size
            took = time.time() - started
            print(f"{voice} {samples / SAMPLE_RATE:.1f}s audio in {took:.2f}s: {text[:60]!r}", flush=True)
        except (BrokenPipeError, ConnectionResetError):
            # The portal cancels speech the moment somebody interrupts.
            pass
        finally:
            mx.clear_cache()
            busy.release()


if __name__ == "__main__":
    try:
        ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
