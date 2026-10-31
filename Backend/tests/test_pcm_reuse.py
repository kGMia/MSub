import wave
import pytest
from huz_subtitle import cli


def make_pcm(path, rate=16000):
    data = b'\x01\x02\x03\x04' * 90000
    with wave.open(str(path), 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(rate)
        f.writeframes(data)
    return data


def test_native_pcm_avoids_ffmpeg_and_preserves_samples(tmp_path, monkeypatch):
    source, target = tmp_path/'source.wav', tmp_path/'target.wav'
    expected = make_pcm(source)
    monkeypatch.setattr(cli, 'require_ffmpeg', lambda: pytest.fail('PCM must not start ffmpeg'))
    progress = []
    cli.extract_audio(source, target, progress_callback=progress.append)
    with wave.open(str(target)) as f:
        assert f.readframes(f.getnframes()) == expected
    assert progress[0] == 0 and progress[-1] == 1
    assert progress == sorted(progress)


def test_cancel_copy_removes_partial_output(tmp_path):
    source, target = tmp_path/'source.wav', tmp_path/'target.wav'
    make_pcm(source)
    def checkpoint(fraction):
        if fraction > 0:
            raise RuntimeError('cancelled')
    with pytest.raises(RuntimeError, match='cancelled'):
        cli.copy_ready_pcm_audio(source, target, 16000, checkpoint)
    assert not target.exists()


def test_other_formats_retain_conversion(tmp_path):
    source, target = tmp_path/'source.wav', tmp_path/'target.wav'
    make_pcm(source, rate=44100)
    assert cli.copy_ready_pcm_audio(source, target, 16000) is False
    assert not target.exists()
