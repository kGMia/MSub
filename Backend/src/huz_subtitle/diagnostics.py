"""Exclusive, monotonic job timings. Call under the owning job's lock."""

import time


class JobDiagnostics:
    STARTS = {
        "audio_extract_start": "audioPreparation", "vad_start": "segmentation",
        "model_loading": "modelLoading", "recognition_start": "recognition",
        "postprocessing_start": "postprocessing", "output_start": "export",
    }
    ENDS = {
        "audio_extract_done": "audioPreparation", "vad_done": "segmentation",
        "model_loaded": "modelLoading", "recognition_done": "recognition",
        "postprocessing_done": "postprocessing", "output_written": "export",
    }

    def __init__(self, clock=time.perf_counter):
        self.clock = clock
        self.started = self.last = clock()
        self.stack = ["queue"]
        self.timings = {}
        self.facts = {}
        self.paused = False
        self.finished = False

    def _tick(self):
        now = self.clock()
        if not self.finished:
            key = "paused" if self.paused else self.stack[-1]
            self.timings[key] = self.timings.get(key, 0.0) + max(0, now - self.last)
            self.last = now

    def running(self):
        self._tick()
        if self.stack == ["queue"]:
            self.stack = ["other"]

    def pause(self, paused):
        self._tick()
        self.paused = paused

    def event(self, event):
        self._tick()
        if self.finished:
            return
        name = event.get("event")
        if name in self.STARTS:
            stage = self.STARTS[name]
            if self.stack[-1] != stage:
                self.stack.append(stage)
        elif name in self.ENDS:
            stage = self.ENDS[name]
            if stage in self.stack[1:]:
                self.stack = self.stack[:self.stack.index(stage)]
        if name == "model_loaded" and event.get("cache") in {"hit", "miss"}:
            self.facts["modelCache"] = event["cache"]
        if name == "prepared_input":
            self.facts["preparedAudio"] = "reused"
            if event.get("segments"):
                self.facts["segmentation"] = "reused"
        if name in {"speaker_labeling_fallback", "rich_model_unavailable", "rich_metadata_unavailable"}:
            self.facts[name] = "fallback"

    def finish(self):
        self._tick()
        self.finished = True
        return self.snapshot()

    def snapshot(self):
        self._tick()
        return {"totalSeconds": round(max(0, self.last - self.started), 3),
                "stages": {key: round(value, 3) for key, value in self.timings.items()},
                "facts": dict(self.facts), "finished": self.finished}
