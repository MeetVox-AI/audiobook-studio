"""Chinese number reader (num2words cannot do Chinese).

Standard mainland reading of integers up to 10^16 - 1 (万亿 is 10^12). `two_form=True` reads a 2 as 两
where Chinese does: the leading digit of a group before 百 or 千 (两百, 两千, 一万两千) and a group that is
exactly 2 before 万 or 亿 (两万, 两亿). Ordinals and digit sequences (年份, 第二章) use 二 everywhere.
"""

from __future__ import annotations

DIGITS = "零一二三四五六七八九"
_GROUP_NAMES = ("", "万", "亿", "万亿")
MAX_VALUE = 10 ** 16 - 1


def _group(n: int, two_form: bool) -> str:
    """Read 1 <= n <= 9999, with 零 for internal zeros and no leading 零."""
    digits = (n // 1000 % 10, n // 100 % 10, n // 10 % 10, n % 10)
    units = ("千", "百", "十", "")
    out = ""
    started = pending_zero = False
    for d, u in zip(digits, units):
        if d == 0:
            pending_zero = started
            continue
        if pending_zero:
            out += "零"
            pending_zero = False
        leading = not started
        started = True
        out += "两" if d == 2 and two_form and u in ("千", "百") and leading else DIGITS[d]
        out += u
    return out


def cardinal(n: int, two_form: bool = True) -> str:
    """0 -> 零, 2024 -> 两千零二十四, 10^12 -> 一万亿. Raises ValueError outside 0..MAX_VALUE."""
    if not 0 <= n <= MAX_VALUE:
        raise ValueError(n)
    if n == 0:
        return DIGITS[0]
    groups = []
    for _ in range(4):
        groups.append(n % 10000)
        n //= 10000
    out = ""
    gap = False  # a zero group was skipped since the last spoken one
    for i in range(3, -1, -1):
        g = groups[i]
        if g == 0:
            gap = bool(out)
            continue
        if out and (gap or g < 1000):
            out += "零"
        gap = False
        if g == 2 and i > 0 and two_form:
            text = "两"
        else:
            text = _group(g, two_form)
        out += text + _GROUP_NAMES[i]
    if out.startswith("一十"):  # 10..19 at the head of the number: 十, 十一, 十万
        out = out[1:]
    return out


def ordinal_number(n: int) -> str:
    """The number in 第N: 二 rather than 两."""
    return cardinal(n, two_form=False)


def digits(s: str) -> str:
    """Digit by digit: '2024' -> '二零二四'."""
    return "".join(DIGITS[int(c)] for c in s)


def decimal(int_part: str, frac: str, two_form: bool = True) -> str:
    """'3', '14' -> '三点一四'. The integer part is read as a cardinal."""
    whole = cardinal(int(int_part.lstrip("0") or "0"), two_form)
    return whole + "点" + digits(frac)
