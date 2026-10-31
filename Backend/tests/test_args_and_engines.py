from huz_subtitle.cli import (
    aligner_language_name,
    apply_punctuation,
    Cue,
    denoise_enabled,
    generation_kwargs_for_engine,
    keep_aux_models_requested,
    parse_args,
    punctuation_enabled,
    resolve_asr_engine,
    word_alignment_enabled,
)


def test_new_flags_default_off() -> None:
    args = parse_args(["in.mp4"])
    assert not word_alignment_enabled(args)
    assert not punctuation_enabled(args)
    assert args.asr_context == ""


def test_new_flags_enable() -> None:
    args = parse_args(["in.mp4", "--align-words", "--punctuate", "--context", "MLX, Apple Silicon"])
    assert word_alignment_enabled(args)
    assert punctuation_enabled(args)
    assert args.asr_context == "MLX, Apple Silicon"


def test_ass_format_accepted() -> None:
    args = parse_args(["in.mp4", "--format", "ass"])
    assert args.format == "ass"


def test_resolve_asr_engine() -> None:
    assert resolve_asr_engine("mlx-community/FireRedASR2-AED-mlx") == "fireredasr2"
    assert resolve_asr_engine("mlx-community/Mega-ASR-bf16") == "mega"
    assert resolve_asr_engine("anything", "sensevoice") == "sensevoice"


def test_mega_context_becomes_system_prompt() -> None:
    args = parse_args(
        ["in.mp4", "--asr-engine", "mega", "--model", "Mega-ASR", "--context", "术语A 术语B"]
    )
    kwargs = generation_kwargs_for_engine(args)
    assert kwargs["system_prompt"] == "术语A 术语B"


def test_mega_without_context_has_no_system_prompt() -> None:
    args = parse_args(["in.mp4", "--asr-engine", "mega", "--model", "Mega-ASR"])
    assert "system_prompt" not in generation_kwargs_for_engine(args)


def test_fireredasr2_ignores_context() -> None:
    args = parse_args(["in.mp4", "--asr-engine", "fireredasr2", "--context", "术语"])
    assert "system_prompt" not in generation_kwargs_for_engine(args)


def test_aligner_language_mapping() -> None:
    args = parse_args(["in.mp4"])
    assert aligner_language_name(args, "zh") == "Chinese"
    assert aligner_language_name(args, "yue") == "Chinese"
    assert aligner_language_name(args, "en") == "English"
    assert aligner_language_name(args, None) == "Chinese"
    ja_args = parse_args(["in.mp4", "--language", "ja"])
    assert aligner_language_name(ja_args, None) == "Japanese"


def test_denoise_flag() -> None:
    assert not denoise_enabled(parse_args(["in.mp4"]))
    assert denoise_enabled(parse_args(["in.mp4", "--denoise"]))


def test_keep_aux_models_requested() -> None:
    args = parse_args(["in.mp4"])
    assert not keep_aux_models_requested(args)
    args.keep_aux_models = True
    assert keep_aux_models_requested(args)
    args.keep_aux_models = lambda: True
    assert keep_aux_models_requested(args)
    args.keep_aux_models = lambda: False
    assert not keep_aux_models_requested(args)

    def broken() -> bool:
        raise RuntimeError("boom")

    args.keep_aux_models = broken
    assert not keep_aux_models_requested(args)


def test_apply_punctuation_disabled_is_noop() -> None:
    args = parse_args(["in.mp4"])
    cues = [Cue(index=1, start=0.0, end=1.0, text="你好世界")]
    assert apply_punctuation(cues, args) is cues
    assert cues[0].text == "你好世界"


def test_apply_punctuation_degrades_gracefully_without_deps() -> None:
    args = parse_args(["in.mp4", "--punctuate"])
    cues = [Cue(index=1, start=0.0, end=1.0, text="你好世界")]
    events: list[dict] = []
    result = apply_punctuation(cues, args, progress_callback=events.append)
    assert result[0].text == "你好世界"
    assert any(event["event"] == "punctuation_unavailable" for event in events)
