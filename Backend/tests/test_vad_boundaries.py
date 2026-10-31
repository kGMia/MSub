"""Boundary scoring regressions; no model loading."""
from types import SimpleNamespace
import numpy as np
import pytest
from huz_subtitle import cli


def cut(values, target=2.0):
    return cli.find_low_energy_cut(np.asarray(values, dtype=np.float32), .01, target, 0, target, 2)


def test_long_pause_beats_single_frame_dip_and_uses_center():
    values = np.ones(200)
    values[30] = 0
    values[120:150] = .1
    assert cut(values) == pytest.approx(1.35)


def test_flat_or_short_search_preserves_target():
    assert cut(np.ones(200)) == 2
    assert cut(np.zeros(200)) == 2
    assert cut([.3] * 5, .05) == .05
    assert cut([np.nan] * 200) == 2


def test_equally_quiet_intervals_prefer_wider_then_later():
    values = np.ones(200)
    values[20:40] = .1
    values[130:160] = .1
    assert cut(values) == pytest.approx(1.45)
    values[20:50] = .1
    assert cut(values) == pytest.approx(1.45)


def test_pyannote_uses_low_not_high_speech_probability():
    values = np.full(800, .9, dtype=np.float32)
    values[250:270] = .1
    args = SimpleNamespace(firered_vad_smooth_window=1, vad_min_silence_seconds=.3,
        vad_min_speech_seconds=.1, vad_padding_seconds=0, vad_max_segment_seconds=3,
        vad_min_segment_seconds=.5, vad_split_search_seconds=1)
    ranges = cli.ranges_from_vad_probabilities(values, .5, .01, 8, args)
    assert ranges[0][1] == pytest.approx(2.5)
    assert ranges[1][0] == pytest.approx(2.7)
    assert all(0 < end - start <= 3.00001 for start, end in ranges)


def test_split_preserves_coverage_order_and_maximum():
    values = np.ones(5000)
    values[1800:1830] = .1
    ranges = cli.split_long_ranges([(0, 50)], 20, 1, values, .01, 2)
    assert ranges[0][0] == 0 and ranges[-1][1] == 50
    assert all(0 < end - start <= 20.00001 for start, end in ranges)
    assert all(left[1] == right[0] for left, right in zip(ranges, ranges[1:]))


def test_padding_and_short_merge_do_not_erase_confirmed_pause():
    values = np.zeros(120, dtype=np.float32)
    values[10:35] = 1
    values[85:110] = 1
    args = SimpleNamespace(firered_vad_smooth_window=1, vad_min_silence_seconds=.3,
        vad_min_speech_seconds=.2, vad_padding_seconds=.1, vad_max_segment_seconds=20,
        vad_min_segment_seconds=1, vad_split_search_seconds=2)
    assert cli.ranges_from_vad_probabilities(values, .5, .01, 1.2, args) == [(0, .45), (.75, 1.2)]
    # The 250 ms responses remain, even though min_segment is one second.
    assert cli.confirmed_silence_boundaries(values >= .5, .01, .3) == [.6]


def test_subthreshold_pause_can_still_bridge_and_edge_silence_is_not_a_boundary():
    mask = np.array([False] * 30 + [True] * 25 + [False] * 20 + [True] * 25 + [False] * 30)
    assert cli.confirmed_silence_boundaries(mask, .01, .3) == []
    assert cli.merge_ranges([(0, .5), (.6, 1)], .3, []) == [(0, 1)]
    mask[55:85] = False
    assert cli.confirmed_silence_boundaries(mask, .01, .3) == pytest.approx([.7])


def test_firered_coreml_cleanup_matches_native_short_reply_fixture(tmp_path, monkeypatch):
    values = np.zeros(120, dtype=np.float32)
    values[10:35] = 1
    values[85:110] = 1
    args = SimpleNamespace(firered_vad_model=str(tmp_path), firered_vad_threshold=.4,
        firered_vad_smooth_window=1, vad_min_silence_seconds=.3,
        vad_min_speech_seconds=.2, vad_padding_seconds=.1, vad_max_segment_seconds=20,
        vad_min_segment_seconds=1, vad_split_search_seconds=2)
    monkeypatch.setattr(cli, 'resolve_firered_vad_coreml_package', lambda _: tmp_path)
    monkeypatch.setattr(cli, 'resolve_firered_vad_cmvn_path', lambda _: tmp_path)
    monkeypatch.setattr(cli, 'firered_vad_coreml_available', lambda _: True)
    monkeypatch.setattr(cli, 'extract_firered_vad_features', lambda *_: (np.zeros((120, 80)), 1.2))
    monkeypatch.setattr(cli, 'predict_firered_vad_coreml_probs', lambda *_: values.tolist())
    assert cli.detect_firered_speech_ranges(tmp_path / 'unused.wav', 1.2, args) == [(0, .45), (.75, 1.2)]
