"""Bounded repetition suspicion for retrying Qwen audio, never text deduplication."""


def has_phrase_loop(text: str) -> bool:
    # Ignore formatting but require a substantial run: >=4 copies, >=24 letters.
    # Compare lagged characters in linear time per candidate period; no regex
    # backtracking and no matching against neighboring subtitle cues.
    chars = [c.lower() for c in text[-8192:] if c.isalnum()][-4096:]
    for width in range(4, min(80, len(chars) // 4) + 1):
        run = 0
        needed = max(3 * width, 24 - width)
        for index in range(width, len(chars)):
            run = run + 1 if chars[index] == chars[index - width] else 0
            if run >= needed:
                return True
    return False


def accept_retry(text: str) -> bool:
    return bool(text.strip()) and not has_phrase_loop(text)
