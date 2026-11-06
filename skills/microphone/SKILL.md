---
name: microphone
description: Record and transcribe with the Codex subscription.
metadata:
  display-name: Microphone
  order: "3"
  expected-tools: '{"transcribe_audio":["path"]}'
---

Microphone recording and transcription through the ChatGPT/Codex subscription, exposed as one tool
and a Ctrl+R recording flow.

tool_schemas() must return exactly one function schema with "strict" => true,
"additionalProperties" => false: transcribe_audio with required parameter path (string, relative to
session.cwd or absolute). It transcribes an existing file and never uses or deletes the microphone.
run_tool routes transcribe_audio and returns "Error: Unknown live tool ..." for other names.

Transcription request:
- Require a regular file larger than 44 bytes and at most 25 MiB.
- POST multipart to "https://chatgpt.com/backend-api/transcribe" with header field name "file" and a
  neutral filename derived from the extension, an audio MIME type for wav, mp3, mp4, m4a, mpeg,
  mpga, webm, ogg or flac, and otherwise application/octet-stream. The service rejects aiff, so
  report "Error: Unsupported audio format." for it rather than uploading. Headers: Authorization
  Bearer, "originator" => "Codex Desktop", Accept application/json, plus ChatGPT-Account-ID when the
  credential has one. Prefer the Codex credential in joinpath(homedir(), ".codex", "auth.json"),
  else App.ChatGPTAuth.access_token(); never print tokens or account ids.
- Response JSON field "text" must be non-empty text. Use connect timeout 15, request timeout 180,
  redirect=false, retry=false, proxy=HTTP.ProxyConfig(), and cancel through an
  HTTP.RequestContext when the user cancels (HTTP.canceled(context) distinguishes cancellation).
- On 401 or 403 with the Codex credential, retry once with the app token when it differs. Sanitize
  every error: no bearer values, account ids, UUIDs, data URLs or long base64 runs.

capture (or the retry path) starts a Threads task that owns a job Dict with an events channel and an
atomic Int action (0 running, 1 stop requested, 2 cancel, 3 shutdown); the UI thread drains events in
on_frame!. Record on macOS only, with Sys.which("ffmpeg"); return a clear failure when ffmpeg or
avfoundation is missing. Write to a new .wav file in joinpath(App.ChatGPTAuth.ensure_dir(),
"recordings"), created with mode 0o700 and private files, using:
ffmpeg -hide_banner -loglevel error -nostdin -f avfoundation -i :default -t 600 -ac 1 -ar 16000
-c:a pcm_s16le -f wav -y FILE
Run it detached from stdin, keep stderr in a temporary log for diagnostics, cap the recording at 10
minutes, and stop with SIGINT so ffmpeg finalizes the WAV header; escalate to SIGKILL after 3 seconds.
A recording is usable when it is a file larger than 44 bytes.

UI behavior:
- Ctrl+R (event.key :ctrl, event.char 'r') starts recording when idle, stops when recording, retries
the upload when the previous attempt failed, and is ignored otherwise. Ignore key releases, and for
legacy terminals ignore repeated Ctrl+R bytes within 0.75 seconds.
- Escape cancels an active recording, upload or stop and keeps usable audio; Escape dismisses a
failed state while keeping the saved audio path.
- Insert the transcription into the composer at the cursor with App.save_edit! before splicing
  characters, replacing control characters with spaces and adding a separating space only when the
  neighbouring characters are not whitespace, then App.Tachikoma._run_validator!(menu.prompt).
- Keep usable recordings private on disk until text is actually inserted. A result that arrives after
  cancellation or for a different session is not inserted; report the saved path so Ctrl+R can retry.
- footer reports the phase concisely: starting, recording with the 10 minute cap and stop/cancel keys,
  stopping, transcribing, canceling with audio retained, saved audio with Ctrl+R retry and Escape
  dismiss, and otherwise the idle composer shortcuts shared with the host.
- on_frame! drains the job channel, applies those transitions, and must never block the UI thread.
  shutdown! cancels workers, signals the recorder with SIGINT then SIGKILL, and returns without
  waiting more than about 4 seconds total.

State is the persistent Dict{Symbol,Any} passed to every hook: keep the microphone phase, job, saved
path and last notice there so an active recording survives a feature reload. on_reload!
must preserve compatible active recording/upload workers and release only generation-specific
resources. shutdown! still cancels workers on removal or exit.
