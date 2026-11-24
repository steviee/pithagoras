# macOS (Apple Silicon)

Pithagoras runs on a Mac with the same image and Compose file as on Linux. What
changes is where the heavy parts live: containers on a Mac get no GPU, so models
run natively — the LLM in [oMLX](https://github.com/jundot/omlx), speech
recognition in whisper.cpp and speech synthesis in mlx-audio — and the portal
reaches them over localhost.

```
Browser ──▶ portal (Docker, OrbStack host networking) ──▶ oMLX :8000        (native, Metal)
                    │                                 ├─▶ whisper :8178     (native, Metal)
                    │                                 └─▶ Voxtral TTS :7864 (native, MLX)
                    └─▶ pithagoras-browser (Docker, arm64)
```

Tested on an M5 Pro with 64 GB. The model below needs about 17 GB, so a Mac with
32 GB should run it alongside the portal and voice (not tested).

## Requirements

- macOS on Apple Silicon
- [OrbStack](https://orbstack.dev) (`brew install orbstack`)
- [oMLX](https://github.com/jundot/omlx) with an API key set, and at least one
  model with tool calling
- For voice: Xcode (for the Metal shader compiler) and
  `brew install cmake ninja aria2`

::: tip Docker Desktop
Docker Desktop works too, from 4.34 on, with **Settings → Resources → Network →
Enable host networking** turned on. Do not run it at the same time as OrbStack:
both claim `/var/run/docker.sock`, which the portal uses to manage the browser.
:::

## Install

```bash
git clone https://github.com/thecodacus/Pithagoras.git
cd Pithagoras
deploy/macos/setup.sh
```

The script is safe to run again. It:

1. writes a `.env` if there is none — a random `PORTAL_SECRET`,
   `PORTAL_HOST=127.0.0.1`, workspaces in
   `~/Pithagoras/workspaces`, and `OMLX_API_KEY` read from
   `~/.omlx/settings.json`;
2. checks that oMLX answers with that key;
3. builds and starts the portal with
   `docker compose -f docker-compose.yml -f docker-compose.macos.yml up -d --build`;
4. installs pi's `models.json` and `settings.json` for the `omlx` provider, and
   an `AGENTS.md` with conversation rules, into the data volume
   (`/data/home/.pi/agent`). Existing files are kept unless you pass `--force`.

Then open `http://localhost:4100` and choose the portal's password: there is
none until you do, and **Settings → Authentication** changes it later.

Your own pi installation (`~/.pi/agent`) is not touched: the portal has its own
agent directory on the data volume.

## Running

Pithagoras on a Mac is four parts. Only the portal runs in Docker:

| Part | Runs as | Starts by itself | Check |
|---|---|---|---|
| oMLX (LLM) | macOS app | if "Start at login" is on in oMLX | `curl -s localhost:8000/health` |
| Voice: Whisper + Voxtral | launchd agents | at login | `launchctl list \| grep pithagoras` |
| Portal | Docker container `pithagoras` | whenever OrbStack starts | `docker ps` |
| Agent browser | Docker container `pithagoras-browser` | whenever OrbStack starts, once installed | `docker ps` |

Two ways to run the portal: the container, for using it, or from source with
hot reload, for working on it. They share `.env` but not their data, and they
cannot run at the same time — both listen on port 4100.

### Docker (normal use)

The first start is `deploy/macos/setup.sh` (see [Install](#install)). After that:

Run these from the repository folder. The alias saves typing both Compose files
every time; put it in `~/.zshrc` to keep it.

```bash
alias pc='docker compose -f docker-compose.yml -f docker-compose.macos.yml'

pc up -d              # start (OrbStack must be running: orbctl start)
pc stop portal        # stop
pc restart portal     # restart, e.g. after editing .env or pi's settings
pc logs -f portal     # follow the log
pc up -d --build      # rebuild after changing the code, or: deploy/macos/setup.sh
```

Open `http://localhost:4100` and log in with the password you chose on the
first visit.

The container has `restart: unless-stopped`, so it comes back with OrbStack
after a reboot — unless you stopped it yourself. If Docker Desktop is also
installed, check that the Docker CLI talks to OrbStack: `docker context show`
should print `orbstack` (`docker context use orbstack` otherwise).

Data lives in the Docker volume `pithagoras_portal-data`: the database, pi's
sessions and its settings under `/data/home/.pi/agent`. To change pi's model
configuration, edit `deploy/macos/pi-models.json` and run
`deploy/macos/setup.sh --force`, which copies it into the volume.

### From source (development)

```bash
deploy/macos/dev.sh
```

Then open `http://localhost:5190` — the Vite dev server, which forwards `/api`
and the agent's browser to the server on port 4100. Both halves reload on save:
the server through `tsx watch`, the UI through Vite. Ctrl-C stops both.

What the script does:

- checks for Node 22.19 or newer, which pi needs. With
  [mise](https://mise.jdx.dev): `mise exec node@24 -- deploy/macos/dev.sh`;
- refuses to start while port 4100 is taken — stop the container first with
  `docker compose -f docker-compose.yml -f docker-compose.macos.yml stop portal`;
- reads `.env` for the secret, oMLX key and workspace folder. The password is
  kept in the database, so the dev portal asks for one of its own on its
  first start;
- keeps everything else in `./data/dev` (ignored by git): database, sessions,
  and its own pi agent directory `./data/dev/pi-agent`, seeded from
  `deploy/macos/pi-models.json` and `pi-settings.json`. Neither the container's
  volume nor your own `~/.pi` is touched;
- runs `npm install` if `node_modules` is missing, builds the extensions
  (terminal, files, git, documents …) with `npm run build:extensions`, and
  links the `pi` from `node_modules` into `./data/dev/bin`, where the server
  finds it.

The agent then runs as your macOS user, not inside a container: it can reach
anything your account can, not only the workspace folder. The
[sandbox](/guide/sandbox) needs Linux and is off here: Settings says so. The
list of the agent's background jobs stays empty, since it reads Linux's
`/proc`. Use this for development, and the container for everything else.

oMLX, the voice agents and the browser container are the same ones the
container uses, so they need no extra setup. The built-in terminal opens your
login shell (`$SHELL`).

### Voice services

```bash
launchctl list | grep pithagoras                                      # running?
launchctl kickstart -k gui/$(id -u)/com.pithagoras.voice.tts          # restart speech synthesis
launchctl kickstart -k gui/$(id -u)/com.pithagoras.voice.whisper      # restart recognition
tail -f ~/Library/Logs/Pithagoras/com.pithagoras.voice.tts.log        # what is being spoken
deploy/macos-voice/setup.sh                                           # reinstall after changing a setting
deploy/macos-voice/setup.sh uninstall                                 # stop and remove both
```

Settings such as `VOXTRAL_STEPS` or `VOXTRAL_VOICE_DE` are baked into the launchd
agent when `setup.sh` runs, so run it again after changing one — for example
`VOXTRAL_STEPS=8 deploy/macos-voice/setup.sh`.

## Models

`deploy/macos/pi-models.json` registers oMLX as an OpenAI-compatible provider
with a single model, Qwen3-Coder:

```json
{
  "providers": {
    "omlx": {
      "baseUrl": "http://127.0.0.1:8000/v1",
      "api": "openai-completions",
      "apiKey": "$OMLX_API_KEY",
      "compat": { "supportsDeveloperRole": false, "supportsReasoningEffort": false, "maxTokensField": "max_tokens" },
      "models": [
        { "id": "Qwen3-Coder-30B-A3B-Instruct-4bit", "reasoning": false, "contextWindow": 131072, "maxTokens": 32768 }
      ]
    }
  }
}
```

and `deploy/macos/pi-settings.json` makes it the default, with thinking off.

- `id` must match what oMLX lists under `GET /v1/models` — the model's folder name.
  Download it with
  `hf download mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit --local-dir ~/.omlx/models/mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`
  or from the oMLX admin page (about 17 GB).
- Qwen3-Coder is a mixture-of-experts model with about 3B active parameters: fast,
  reliable at tool calls, and without a thinking mode.
- Keep `contextWindow` at or below the per-model context limit set in oMLX.

::: warning Set Qwen3-Coder's sampling in oMLX
oMLX does not read a model's `generation_config.json`. Without per-model settings
it samples with its global defaults — temperature 1.0, no top-k and no
repetition penalty — and pi's SDK in the portal sends none of its own. With
those, Qwen3-Coder 4-bit falls into loops, repeating the same two sentences until
it runs out of tokens, and emits tool calls as plain text more often.

Set Qwen's recommended values for the model in the oMLX admin page (**Models →
Qwen3-Coder-30B-A3B-Instruct-4bit → Settings**): temperature `0.7`, top-p `0.8`,
top-k `20`, repetition penalty `1.05`. In a test with the browser tools, correct
`browser_navigate` calls rose from 4 of 6 to 7 of 8.
:::

::: warning Thinking models in voice mode
With Qwen3.8-27B through oMLX, multi-turn voice conversations regularly produced
several rephrased answers in one reply — the model did not stop after the first.
Sending `preserve_thinking: false` made it rarer but did not remove it. Qwen3-Coder
has no thinking mode and is the model this setup uses.
:::

### Conversation rules

`deploy/macos/pi-AGENTS.md` becomes pi's global `AGENTS.md`, loaded into every
session. Qwen3-Coder works from an English system prompt, and in German
conversations it tended to add English notes in parentheses ("You should be
aware that …"), to describe pages it had not opened, and to rephrase answers it
had already given. The file asks it to stay in the user's language, leave out
such asides, report only what a tool returned and say each thing once. Edit it
in the volume and restart the portal to change the rules:

```bash
docker compose -f docker-compose.yml -f docker-compose.macos.yml cp \
  deploy/macos/pi-AGENTS.md portal:/data/home/.pi/agent/AGENTS.md
docker compose -f docker-compose.yml -f docker-compose.macos.yml restart portal
```

To add another model, place it under `~/.omlx/models`, add an entry to
`pi-models.json`, and run `deploy/macos/setup.sh --force`.

## Only on this Mac

With host networking on a Mac, anything a container binds to `0.0.0.0` is
reachable from the LAN. The portal therefore listens on `127.0.0.1`
(`PORTAL_HOST`). To reach it from other devices, set `PORTAL_HOST=0.0.0.0`, and
read [Deploying](/guide/deploying) first.

The browser add-on's own viewer (`3010`/`3011`) listens on `127.0.0.1` as
well and is reached through the portal's `/browser-ui`. Leave `BROWSER_BIND`
unset to keep it that way; see [The agent's browser](/guide/browser).

## Browser

**Browser → Install** pulls `lscr.io/linuxserver/chromium`, which has an arm64
build, and runs it exactly as on Linux. Set a password first; the portal holds it
and proxies the viewer, so you are not asked for it again.

## Voice

The managed Voice add-on builds CUDA runtimes in an NVIDIA container and does
not run on a Mac. `deploy/macos-voice/setup.sh` runs speech natively on the GPU
instead and installs two launchd agents that start at login:

| Service | Address | Model |
|---|---|---|
| whisper.cpp `whisper-server` (Metal) | `http://127.0.0.1:8178/inference` | Whisper large-v3-turbo, q5_0 |
| Voxtral TTS on mlx-audio (MLX) | `http://127.0.0.1:7864/v1/audio/speech` | `mlx-community/Voxtral-4B-TTS-2603-mlx-4bit` |

The speech service answers in the audio.cpp protocol — raw 24 kHz PCM as it is
generated — so the portal needs no changes:

```bash
deploy/macos-voice/setup.sh                    # build, download, start
TTS_ENGINE=breeze deploy/macos-voice/setup.sh  # Breeze-TTS-2 on audio.cpp instead
deploy/macos-voice/setup.sh uninstall          # remove the launchd agents
```

Then open **Settings → Add-ons → Voice → Advanced connection**, choose
**Breeze audio.cpp** (Streaming) as the speech runtime and enter both URLs. Leave
**Install voice** alone; that is the NVIDIA installer. Logs are in
`~/Library/Logs/Pithagoras`.

::: warning Voxtral moved from 7863 to 7864
The managed add-on now uses 7863 for its CPU engines, and the portal treats an
address there as its own container, trying to load and unload models on it.
After updating, run `deploy/macos-voice/setup.sh` again so the launchd agent
listens on 7864, and change the speech synthesis URL to match.
:::

Voxtral's voices belong to a language, so the service picks one per sentence
from the language of the text: `de_female` for German, `casual_female` for
English. `VOXTRAL_VOICE_DE`, `VOXTRAL_VOICE_EN` and `VOXTRAL_STEPS` change that.
The portal's voice description and reference clones have no effect on Voxtral.

Models write stage directions into spoken replies — `(chuckles)`, `*sighs*`,
`(very quiet)`, `(plays a bit of piano music)`. The portal invites a few of those
cues for Breeze. Voxtral has no tags for them and improvises on the words:
laughter comes out as moaning, "(very quiet)" as speaking from across a hall, and
"music" is attempted. The service therefore turns a cue that has a sound of its
own into that sound, spoken — `(laughs)` becomes "Haha,", `(seufzt)` becomes
"Hach,", `(clears throat)` becomes "Ahem," — which Voxtral delivers with fitting
prosody. Gestures, volumes and soundtracks have no such sound and are dropped.

### Measured on an M5 Pro

Speech speed as a multiple of normal speaking pace, for a sentence of about
eight seconds, while Qwen3-Coder generates on the same GPU (the normal case in
voice mode). Below 1× the audio stalls.

| Engine | Idle | LLM running | First audio | German |
|---|---|---|---|---|
| Voxtral TTS 4-bit, 8 steps | 3.4× | 2.5× | 0.2 s | yes |
| Voxtral TTS 4-bit, 6 steps (default) | 4.1× | — | 0.2 s | yes |
| Breeze-TTS-2 Q8 on audio.cpp, fast | 1.2× | 0.9× | 0.6 s | no |
| Breeze-TTS-2 Q8 on audio.cpp, expressive | 1.1× | 0.7× | 0.8 s | no |
| Kokoro 82M (MLX) | 32× | 27× | 0.2 s | no |

Voxtral spends most of its time in a flow-matching head that runs eight steps by
default. Fewer steps are faster (four reached 5× when idle) at some cost
in quality that is worth judging by ear. Breeze on
Metal is barely real time — audio.cpp describes its Metal backend as meant for
portability rather than speed.

For speech recognition, Whisper large-v3-turbo (q5_0) transcribed a 13-second
German request with 2.8% word error rate in about 0.4 s, against 16.7% for
Whisper base. Voxtral Mini 4B Realtime (4-bit MLX) was slower, misread the first
German words, and stalled intermittently when streamed, so it is not used.

::: warning Licences
Voxtral TTS and Breeze-TTS-2 weights are licensed for non-commercial use.
:::

## Not supported on macOS

- The managed **Voice** installer (NVIDIA only). Use the script above.
- `EXECUTOR=container`: the portal image has no Docker CLI.

## Updating

```bash
git pull
deploy/macos/setup.sh          # rebuilds and restarts the portal
deploy/macos-voice/setup.sh    # only when deploy/macos-voice changed
```
