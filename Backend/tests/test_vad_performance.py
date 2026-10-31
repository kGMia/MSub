"""Numerical and progress regressions for VAD execution changes."""
import numpy as np
import pytest
from huz_subtitle import cli


@pytest.mark.parametrize('reverse', [False, True])
def test_batched_lstm_projection_matches_stepwise_reference(reverse):
    rng = np.random.default_rng(42)
    values = rng.normal(0, .2, (27, 12)).astype(np.float32)
    wx = rng.normal(0, .2, (32, 12)).astype(np.float32)
    wh = rng.normal(0, .2, (32, 8)).astype(np.float32)
    bias = rng.normal(0, .2, 32).astype(np.float32)
    hidden = np.zeros(8, dtype=np.float32)
    cell = hidden.copy()
    expected = np.empty((27, 8), dtype=np.float32)
    for index in (range(26, -1, -1) if reverse else range(27)):
        gates = values[index] @ wx.T + hidden @ wh.T + bias
        i, f, g, o = np.split(gates, 4)
        cell = cli.sigmoid(f) * cell + cli.sigmoid(i) * np.tanh(g)
        hidden = cli.sigmoid(o) * np.tanh(cell)
        expected[index] = hidden
    np.testing.assert_allclose(cli.lstm_direction(values, wx, wh, bias, reverse), expected, atol=1e-6, rtol=1e-6)


def test_firered_reports_chunk_progress_and_preserves_state(monkeypatch):
    calls = []
    class Model:
        def predict(self, inputs):
            calls.append(inputs)
            return {'probs': np.ones(inputs['feat'].shape[1], dtype=np.float32),
                    **{f'new_cache_{i}': inputs[f'cache_{i}'] + 1 for i in range(8)}}
    monkeypatch.setattr(cli, 'load_firered_vad_coreml_model', lambda _: Model())
    monkeypatch.setenv('MSUB_FIRERED_VAD_COREML_BATCH_FRAMES', '4')
    events = []
    result = cli.predict_firered_vad_coreml_probs('unused', np.zeros((10, 80)), events.append)
    assert len(result) == 10
    assert [e['current'] for e in events] == [4, 8, 10]
    assert events[-1]['fraction'] == 1
    assert np.all(calls[2]['cache_0'] == 2)


def test_sigmoid_saturated_gates_are_stable():
    values = np.array([-np.inf, -1000, -100, -10, -1, 0, 1, 10, 100, 1000, np.inf], np.float32)
    reference = np.empty(values.shape, np.float64)
    positive = values >= 0
    reference[positive] = 1 / (1 + np.exp(-values[positive].astype(np.float64)))
    exponent = np.exp(values[~positive].astype(np.float64))
    reference[~positive] = exponent / (1 + exponent)
    with np.errstate(over='raise', invalid='raise', divide='raise'):
        actual = cli.sigmoid(values)
    assert actual.dtype == np.float32
    np.testing.assert_allclose(actual, reference, atol=1e-7, rtol=1e-6)
