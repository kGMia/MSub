from types import SimpleNamespace
import pytest
import huz_subtitle.cli as cli
from huz_subtitle.qwen_repetition import has_phrase_loop, accept_retry

@pytest.mark.parametrize('text', [
    'これは同じ文章です。' * 4,
    '前置きです。' + 'ありがとうございます。' * 5 + 'ありが',
    'This is the same sentence. ' * 4,
    '这是同一个句子。' * 4,
])
def test_phrase_loops(text):
    assert has_phrase_loop(text)

@pytest.mark.parametrize('text', ['', 'うんうんうん', 'はい、はい。', 'ありがとうございます。' * 2,
    '猫が来ました。犬も来ました。それから鳥も来ました。', 'abcde' * 4])
def test_normal_short_repetition_is_not_a_loop(text):
    assert not has_phrase_loop(text)

@pytest.mark.parametrize('retry', ['明日は晴れです。', '', '同じ文章の繰り返しです。' * 4])
def test_pipeline_retries_once_same_range(tmp_path, monkeypatch, retry):
    args = cli.parse_args([str(tmp_path / 'input.wav'), '--asr-engine', 'qwen3'])
    args.resolved_vad_engine = 'energy'
    original = '同じ文章の繰り返しです。' * 4
    calls = []
    def transcribe(model, path, options, segment, total, callback):
        calls.append((segment.start, segment.end, options))
        return SimpleNamespace(text=original if len(calls) == 1 else retry)
    monkeypatch.setattr(cli, 'transcribe_one_streaming', transcribe)
    monkeypatch.setattr(cli, 'extract_chunk', lambda *a: None)
    monkeypatch.setattr(cli, 'release_inference_memory_after_chunk', lambda *a: None)
    events = []
    cues = cli._transcribe_prepared_segments(None, tmp_path/'input.wav', 10, args,
        [cli.Segment(index=1,start=2,end=4)], lambda _:tmp_path/'chunk.wav', lambda _:None, {}, events.append, None)
    assert len(calls) == 2
    assert [(x[0],x[1]) for x in calls] == [(2,4),(2,4)]
    assert calls[1][2].gen_kwargs['repetition_penalty'] >= 1.15
    assert cues[0].text == (retry if accept_retry(retry) else original)
    assert (cues[0].start,cues[0].end) == (2,4)
    assert len([e for e in events if e['event']=='chunk_retry']) == 1


def test_cancellation_propagates_from_retry(tmp_path, monkeypatch):
    args = cli.parse_args([str(tmp_path/'input.wav'),'--asr-engine','qwen3'])
    calls = 0
    class Cancelled(RuntimeError): pass
    def transcribe(*a):
        nonlocal calls
        calls += 1
        if calls == 2: raise Cancelled()
        return SimpleNamespace(text='同じ文章の繰り返しです。'*4)
    monkeypatch.setattr(cli,'transcribe_one_streaming',transcribe)
    monkeypatch.setattr(cli,'extract_chunk',lambda *a:None)
    monkeypatch.setattr(cli,'release_inference_memory_after_chunk',lambda *a:None)
    with pytest.raises(Cancelled):
        cli._transcribe_prepared_segments(None,tmp_path/'input.wav',10,args,
            [cli.Segment(index=1,start=2,end=4)],lambda _:tmp_path/'chunk.wav',lambda _:None,{},None,None)
    assert calls == 2
