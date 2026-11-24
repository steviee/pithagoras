#!/usr/bin/env bash
# Voice for Pithagoras on macOS (Apple Silicon), running natively on the GPU.
#
# The Voice service extension builds CUDA runtimes inside an NVIDIA container and
# cannot run on a Mac. This runs speech natively instead, as launchd agents:
#
#   whisper.cpp  whisper-server   127.0.0.1:8178/inference         speech to text (Metal)
#   Voxtral TTS  mlx-audio        127.0.0.1:7864/v1/audio/speech   text to speech (MLX, default)
#   audio.cpp    audiocpp_server  127.0.0.1:7861/v1/audio/speech   Breeze-TTS-2 (Metal, TTS_ENGINE=breeze)
#
# Both speech engines answer OpenAI's /v1/audio/speech, streamed as audio.cpp
# streams Breeze, so the portal speaks to them through its Voice servers
# extension: Settings → Extension settings → Voice servers.
# None uses a port of the Voice service extension (7862, 7863 and 8188): an
# address there is taken for that container's own.
#
#   deploy/macos-voice/setup.sh              # build, download, install and start
#   deploy/macos-voice/setup.sh uninstall    # stop and remove the launchd agents
#
# Environment:
#   TTS_ENGINE      voxtral (default) or breeze
#   VOICE_DIR       where sources, builds and models go (default: ./voice-runtime)
#   WHISPER_MODEL   whisper.cpp model (default: large-v3-turbo-q5_0; "base" is faster but weak in German)
#   WHISPER_PORT    default 8178
#   VOXTRAL_MODEL   default mlx-community/Voxtral-4B-TTS-2603-mlx-4bit
#   VOXTRAL_STEPS   flow-matching steps, default 6 (8 is the model default; fewer is faster)
#   VOXTRAL_VOICE_DE / VOXTRAL_VOICE_EN   default de_female / casual_female
#   VOXTRAL_PORT    default 7864
#   TTS_PORT        Breeze port, default 7861
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/deploy/macos-voice"
VOICE_DIR="${VOICE_DIR:-$ROOT/voice-runtime}"
TTS_ENGINE="${TTS_ENGINE:-voxtral}"
WHISPER_MODEL="${WHISPER_MODEL:-large-v3-turbo-q5_0}"
WHISPER_PORT="${WHISPER_PORT:-8178}"
VOXTRAL_MODEL="${VOXTRAL_MODEL:-mlx-community/Voxtral-4B-TTS-2603-mlx-4bit}"
VOXTRAL_STEPS="${VOXTRAL_STEPS:-6}"
VOXTRAL_VOICE_DE="${VOXTRAL_VOICE_DE:-de_female}"
VOXTRAL_VOICE_EN="${VOXTRAL_VOICE_EN:-casual_female}"
VOXTRAL_PORT="${VOXTRAL_PORT:-7864}"
TTS_PORT="${TTS_PORT:-7861}"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/Pithagoras"
LABELS=(com.pithagoras.voice.whisper com.pithagoras.voice.tts)

# Same pins as deploy/voice/setup.sh, so both deployments run identical code.
AUDIO_REV=efb04233dab73aeee4b2912042a90e7b36329061
WHISPER_REV=a2b36eb677918d4f9ab1db7b8a7ff968563ed163
BREEZE_URL="https://huggingface.co/audio-cpp/audio.cpp-gguf/resolve/056144d2744697c9439bd32647279674dba0c964/Breeze-TTS-2-GGUF/breeze-tts-2-bf16.gguf"
BREEZE_SHA256=a00c9f678b4c5ae03d1dcd228f636b329352cda200823faef4e01d3bd97c0a89
# Voxtral TTS arrived in mlx-audio 0.5; pinned so a rebuild does not move it.
MLX_AUDIO_VERSION=0.5.4

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

unload() {
  for label in "${LABELS[@]}"; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    # bootout returns before the service is gone, and bootstrapping it again
    # in that window fails with "Input/output error".
    for _ in $(seq 1 50); do
      launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break
      sleep 0.2
    done
  done
}

if [ "${1:-}" = "uninstall" ]; then
  unload
  for label in "${LABELS[@]}"; do rm -f "$AGENTS/$label.plist"; done
  echo "Voice agents removed. Builds and models remain in $VOICE_DIR."
  exit 0
fi

[ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] || fail "This script is for macOS on Apple Silicon."
case "$TTS_ENGINE" in voxtral|breeze) ;; *) fail "TTS_ENGINE must be voxtral or breeze" ;; esac
for tool in git cmake ninja curl; do
  command -v "$tool" >/dev/null || fail "$tool is missing: brew install cmake ninja aria2"
done
if [ "$TTS_ENGINE" = voxtral ]; then
  command -v uv >/dev/null || fail "uv is missing: brew install uv"
else
  command -v aria2c >/dev/null || fail "aria2c is missing: brew install aria2"
fi

# The Metal shader compiler ships with Xcode, not the Command Line Tools. Use
# Xcode for this build without switching the machine's active developer dir.
if ! xcrun --sdk macosx --find metal >/dev/null 2>&1; then
  if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
  xcrun --sdk macosx --find metal >/dev/null 2>&1 ||
    fail "Metal toolchain not found. Install Xcode, then: xcodebuild -downloadComponent MetalToolchain"
fi

mkdir -p "$VOICE_DIR/models" "$LOGS"
cd "$VOICE_DIR"
jobs="$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || sysctl -n hw.logicalcpu)"

checkout() {
  local directory="$1" repository="$2" revision="$3"
  if [ ! -d "$directory/.git" ]; then git clone "$repository" "$directory"; fi
  git -C "$directory" fetch --quiet origin "$revision" 2>/dev/null || true
  git -C "$directory" checkout --quiet "$revision"
  git -C "$directory" submodule update --init --recursive
}

say "whisper.cpp (Metal)"
checkout whisper https://github.com/ggml-org/whisper.cpp.git "$WHISPER_REV"
if [ ! -x whisper/build/bin/whisper-server ]; then
  cmake -S whisper -B whisper/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DWHISPER_BUILD_SERVER=ON
  cmake --build whisper/build --target whisper-server -j "$jobs"
fi

say "Whisper model: $WHISPER_MODEL"
if [ ! -s "models/ggml-$WHISPER_MODEL.bin" ]; then
  bash whisper/models/download-ggml-model.sh "$WHISPER_MODEL" "$VOICE_DIR/models"
fi

if [ "$TTS_ENGINE" = voxtral ]; then
  say "Voxtral TTS (MLX): $VOXTRAL_MODEL"
  if [ ! -x voxtral-venv/bin/python ]; then
    uv venv --quiet --python 3.12 voxtral-venv
  fi
  VIRTUAL_ENV="$VOICE_DIR/voxtral-venv" uv pip install --quiet \
    "mlx-audio==$MLX_AUDIO_VERSION" "mistral-common[audio]"
  voxtral-venv/bin/hf download "$VOXTRAL_MODEL" >/dev/null
else
  say "audio.cpp (Metal)"
  checkout audio https://github.com/0xShug0/audio.cpp.git "$AUDIO_REV"
  if [ ! -x audio/build/portal/bin/audiocpp_server ] || [ ! -x audio/build/portal/bin/audiocpp_gguf ]; then
    (cd audio && bash scripts/build_metal.sh --build-dir "$VOICE_DIR/audio/build/portal" --build-type Release \
      --model-set custom --models breeze_tts --target audiocpp_server --target audiocpp_gguf --jobs "$jobs")
  fi

  say "Breeze-TTS-2 (Q8_0)"
  if [ ! -s models/breeze-q8_0.gguf ]; then
    if [ ! -s models/breeze-bf16.gguf ]; then
      aria2c --continue=true --max-connection-per-server=4 --split=4 --min-split-size=16M \
        --file-allocation=none --auto-file-renaming=false --max-tries=5 --retry-wait=5 \
        --console-log-level=warn --summary-interval=30 --checksum=sha-256="$BREEZE_SHA256" \
        --dir=models --out=breeze-bf16.gguf.part "$BREEZE_URL"
      mv models/breeze-bf16.gguf.part models/breeze-bf16.gguf
    fi
    audio/build/portal/bin/audiocpp_gguf --input models/breeze-bf16.gguf \
      --output models/breeze-q8_0.partial.gguf --type q8_0 --overwrite
    mv models/breeze-q8_0.partial.gguf models/breeze-q8_0.gguf
    rm -f models/breeze-bf16.gguf
  fi

  cat > "$VOICE_DIR/server.json" <<JSON
{
  "host": "127.0.0.1",
  "port": $TTS_PORT,
  "backend": "metal",
  "device": 0,
  "threads": 4,
  "lazy_load": false,
  "max_loaded_models": 1,
  "models": [{
    "id": "breeze",
    "family": "breeze_tts",
    "path": "$VOICE_DIR/models/breeze-q8_0.gguf",
    "task": "tts",
    "mode": "streaming",
    "session_options": { "breeze_tts.reference_cache_slots": "1" }
  }]
}
JSON
fi

# One launchd agent per service: started at login, restarted if it dies.
agent() {
  local label="$1" workdir="$2" env="$3"; shift 3
  local args=""
  for a in "$@"; do args+="    <string>$a</string>"$'\n'; done
  cat > "$AGENTS/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
$args  </array>
  <key>EnvironmentVariables</key>
  <dict>
$env  </dict>
  <key>WorkingDirectory</key><string>$workdir</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOGS/$label.log</string>
  <key>StandardErrorPath</key><string>$LOGS/$label.log</string>
</dict>
</plist>
PLIST
}
kv() { printf '    <key>%s</key><string>%s</string>\n' "$1" "$2"; }

say "Installing launchd agents"
mkdir -p "$AGENTS"
unload
agent com.pithagoras.voice.whisper "$VOICE_DIR/whisper" "" \
  "$VOICE_DIR/whisper/build/bin/whisper-server" --host 127.0.0.1 --port "$WHISPER_PORT" \
  --model "$VOICE_DIR/models/ggml-$WHISPER_MODEL.bin" --language auto --threads 4
if [ "$TTS_ENGINE" = voxtral ]; then
  tts_port="$VOXTRAL_PORT"
  agent com.pithagoras.voice.tts "$VOICE_DIR" \
    "$(kv VOXTRAL_MODEL "$VOXTRAL_MODEL")$(kv VOXTRAL_STEPS "$VOXTRAL_STEPS")$(kv VOXTRAL_VOICE_DE "$VOXTRAL_VOICE_DE")$(kv VOXTRAL_VOICE_EN "$VOXTRAL_VOICE_EN")$(kv VOXTRAL_PORT "$VOXTRAL_PORT")$(kv PYTHONUNBUFFERED 1)" \
    "$VOICE_DIR/voxtral-venv/bin/python" "$HERE/voxtral_tts_server.py"
else
  tts_port="$TTS_PORT"
  agent com.pithagoras.voice.tts "$VOICE_DIR/audio" "" \
    "$VOICE_DIR/audio/build/portal/bin/audiocpp_server" --config "$VOICE_DIR/server.json"
fi
for label in "${LABELS[@]}"; do
  launchctl bootstrap "gui/$(id -u)" "$AGENTS/$label.plist"
done

say "Waiting for the services (loading models can take a minute)"
for _ in $(seq 1 90); do
  w="$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:$WHISPER_PORT/health" || true)"
  t="$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:$tts_port/health" || true)"
  if [ "$w" = 200 ] && [ "$t" = 200 ]; then
    cat <<DONE
Voice is running ($TTS_ENGINE). In the portal: Settings → Extension settings → Voice servers
  Speech recognition URL:  http://127.0.0.1:$WHISPER_PORT/inference
  Speech synthesis URL:    http://127.0.0.1:$tts_port/v1/audio/speech
  Streamed: Custom voices on, Breeze-TTS-2 → audio.cpp (or Fixed voices, one WAV per phrase)
  Then: Use for voice mode
Logs: $LOGS
DONE
    exit 0
  fi
  sleep 2
done
fail "Services did not become healthy (whisper=$w, tts=$t). See $LOGS"
