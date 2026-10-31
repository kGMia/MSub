"""Preview inference should occupy the bar and retain sub-percent progress."""
from argparse import Namespace
import pytest
from huz_subtitle import web


@pytest.mark.parametrize('events_enabled, vad_end', [(False, 95), (True, 68)])
def test_preview_progress_tracks_inference_without_backwards_steps(monkeypatch, tmp_path, events_enabled, vad_end):
    snapshots = []
    monkeypatch.setattr(web, 'preview_control_checkpoint', lambda _: None)
    monkeypatch.setattr(web, 'record_diagnostic_event', lambda *a: None)
    monkeypatch.setattr(web, 'append_job_log', lambda *a: None)
    monkeypatch.setattr(web, 'update_job', lambda _, **values: snapshots.append(values))
    monkeypatch.setattr(web, 'probe_media_info', lambda _: {'duration': 100})
    monkeypatch.setattr(web, 'probe_duration', lambda _: 100)
    def extract(*args, **kwargs):
        for fraction in [0, .5, 1]:
            kwargs['progress_callback'](fraction)
    monkeypatch.setattr(web, 'extract_audio', extract)
    def segments(*args, **kwargs):
        cb = kwargs['progress_callback']
        cb({'event': 'vad_start', 'engine': 'pyannote_mlx'})
        for fraction in [0, .1234, .5, 1]:
            cb({'event': 'vad_progress', 'fraction': fraction})
        cb({'event': 'vad_done', 'total': 0})
        return []
    monkeypatch.setattr(web, 'build_segments', segments)
    def mark(path, segments, args, callback=None):
        if callback:
            for name in ['audio_event_model_loading', 'audio_event_model_loaded', 'audio_event_segments']:
                callback({'event': name, 'current': 1, 'total': 1})
        return segments
    monkeypatch.setattr(web, 'mark_non_lexical_segments', mark)
    monkeypatch.setattr(web, 'write_preview_plan', lambda *a, **kw: None)
    monkeypatch.setattr(web, 'clear_aux_model_caches', lambda: None)
    monkeypatch.setattr(web, 'preview_result_payload', lambda *a, **kw: {})
    web.build_preview_payload('fixture', input_path=tmp_path/'input', wav_path=tmp_path/'wav',
                              settings_key='fixture', args=Namespace(audio_event_filter=events_enabled), job_id='fixture')
    progress = [s for s in snapshots if 'fractionalCurrent' in s]
    values = [s['fractionalCurrent'] for s in progress]
    assert values == sorted(values)
    midway = next(s for s in progress if s['progressText'] == 'Detecting speech 50%')
    assert midway['fractionalCurrent'] == 10 + (vad_end - 10) * .5
    fractional = next(s for s in progress if s['progressText'] == 'Detecting speech 12%')
    assert fractional['fractionalCurrent'] == pytest.approx(10 + (vad_end - 10) * .1234)
    assert isinstance(fractional['current'], int)
