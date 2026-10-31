# Release pairing checkpoint — 2026-10-31

The app repository previously omitted the Python workspace. Backend now tracks
an explicit source-only snapshot, dependency lock and regression tests. A
content manifest binds every included file to one backend revision; the app's
Git commit binds that revision to frontend sources and Swift package locks.
Release preflight and package-backend reject live-workspace drift and ship the
manifest alongside the backend. CI adds a model-free Python contract job.

Existing development paths and Python CLI/WebUI entry points remain unchanged.
No models, videos, environment files, caches, or runtime binaries were added.
The accumulated native Qwen/VAD, timing, undo and model-support changes are
included in this checkpoint. See the dated implementation notes for their
bounded validation and remaining limitations.

Validation: 35 CPU backend tests against the snapshot passed; manifest/content
checks and shell syntax checks passed. This checkpoint does not claim a full
Archive/signing/notarization test, nor a completed remote CI run.
