#!/usr/bin/env python3
"""
Itinerary day-palette solver & verifier.

Carry gives each itinerary day a distinct muted hue (see ItineraryDayPalette in
Carry/Models/AppearanceMode.swift, decisions.md 2026-06-13 / 2026-06-20). The palette is
cycled by `sortOrder % N`, so for trips longer than N days colours repeat. The design
constraint is: any 5 CONSECUTIVE days must be mutually distinct — long trips must never
place look-alike hues near each other.

This script:
  1. converts each candidate colour (light + dark variant) to CIELAB,
  2. measures perceptual distance with CIEDE2000 (taking the WORSE of light/dark — both
     appearance modes must separate),
  3. brute-forces the slot ORDER (Day 1 pinned to the brand blue) that maximises the
     minimum pairwise ΔE over every 5-day window, INCLUDING the cyclic wrap,
  4. prints the winning order, per-window report, and the guaranteed floor.

Run it whenever you add/reorder/retune a day colour, and copy the resulting order +
RGB tuples back into `ItineraryDayPalette.palette`. Pure stdlib; no dependencies.
"""
import math
import itertools

# Final palette in slot order (slot 0 = Day 1). Edit here, re-run, copy back to Swift.
#   name, light rgb (0-1), dark rgb (0-1)
# Current order is PRODUCT-FIXED (Day 1 green / Day 2 marigold / Day 3 brand blue, by request);
# VERIFY_ONLY keeps it as-listed and just reports the floor. Flip VERIFY_ONLY off to brute-force
# a max-floor order instead (e.g. when adding colours and the order is free to choose).
PALETTE = [
    ("palm_green",         (0.455, 0.675, 0.333), (0.573, 0.757, 0.475)),
    ("marigold",           (0.863, 0.549, 0.235), (0.910, 0.659, 0.404)),
    ("smoky_blue (brand)", (0.357, 0.478, 0.588), (0.478, 0.612, 0.722)),
    ("amethyst",           (0.561, 0.420, 0.733), (0.675, 0.561, 0.812)),
    ("raspberry",          (0.780, 0.314, 0.431), (0.859, 0.471, 0.569)),
    ("teal",               (0.176, 0.659, 0.620), (0.357, 0.745, 0.706)),
    ("clay",               (0.773, 0.420, 0.290), (0.855, 0.549, 0.451)),
]
WINDOW = 5          # "no look-alike hues within N consecutive days"
PIN_FIRST = True    # (when solving) keep slot 0 fixed
VERIFY_ONLY = True  # report the PALETTE order as-listed instead of brute-forcing a new one
# Note: with N=7 every pair shares some 5-day window (max cyclic gap 3 ≤ 4), so the floor is just
# the global min ΔE — the order can't change it; it only affects which days sit adjacent.


def _srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def rgb_to_lab(rgb):
    r, g, b = (_srgb_to_lin(x) for x in rgb)
    x = r * 0.4124 + g * 0.3576 + b * 0.1805
    y = r * 0.2126 + g * 0.7152 + b * 0.0722
    z = r * 0.0193 + g * 0.1192 + b * 0.9505
    xn, yn, zn = 0.95047, 1.0, 1.08883

    def f(t):
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116

    fx, fy, fz = f(x / xn), f(y / yn), f(z / zn)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


def ciede2000(lab1, lab2):
    l1, a1, b1 = lab1
    l2, a2, b2 = lab2
    avg_lp = (l1 + l2) / 2
    c1, c2 = math.hypot(a1, b1), math.hypot(a2, b2)
    avg_c = (c1 + c2) / 2
    g = 0.5 * (1 - math.sqrt(avg_c ** 7 / (avg_c ** 7 + 25 ** 7)))
    a1p, a2p = (1 + g) * a1, (1 + g) * a2
    c1p, c2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    avg_cp = (c1p + c2p) / 2

    def hp(ap, b):
        if ap == 0 and b == 0:
            return 0
        h = math.degrees(math.atan2(b, ap))
        return h + 360 if h < 0 else h

    h1p, h2p = hp(a1p, b1), hp(a2p, b2)
    dlp = l2 - l1
    dcp = c2p - c1p
    dhp = h2p - h1p
    if abs(dhp) > 180:
        dhp -= 360 if dhp > 0 else -360
    dHp = 2 * math.sqrt(c1p * c2p) * math.sin(math.radians(dhp) / 2)
    if c1p * c2p == 0:
        avg_hp = h1p + h2p
    elif abs(h1p - h2p) <= 180:
        avg_hp = (h1p + h2p) / 2
    else:
        avg_hp = (h1p + h2p + 360) / 2 if (h1p + h2p) < 360 else (h1p + h2p - 360) / 2
    t = (1 - 0.17 * math.cos(math.radians(avg_hp - 30))
         + 0.24 * math.cos(math.radians(2 * avg_hp))
         + 0.32 * math.cos(math.radians(3 * avg_hp + 6))
         - 0.20 * math.cos(math.radians(4 * avg_hp - 63)))
    d_ro = 30 * math.exp(-(((avg_hp - 275) / 25) ** 2))
    rc = 2 * math.sqrt(avg_cp ** 7 / (avg_cp ** 7 + 25 ** 7))
    sl = 1 + (0.015 * (avg_lp - 50) ** 2) / math.sqrt(20 + (avg_lp - 50) ** 2)
    sc = 1 + 0.045 * avg_cp
    sh = 1 + 0.015 * avg_cp * t
    rt = -math.sin(math.radians(2 * d_ro)) * rc
    return math.sqrt((dlp / sl) ** 2 + (dcp / sc) ** 2 + (dHp / sh) ** 2
                     + rt * (dcp / sc) * (dHp / sh))


def hex_of(rgb):
    return "#" + "".join(f"{round(c * 255):02X}" for c in rgb)


def main():
    n = len(PALETTE)
    names = [p[0] for p in PALETTE]
    lab_l = [rgb_to_lab(p[1]) for p in PALETTE]
    lab_d = [rgb_to_lab(p[2]) for p in PALETTE]
    # worse of the two modes — both must separate
    d = [[min(ciede2000(lab_l[i], lab_l[j]), ciede2000(lab_d[i], lab_d[j]))
          for j in range(n)] for i in range(n)]

    wins = [tuple((s + k) % n for k in range(WINDOW)) for s in range(n)]
    pairs = [list(itertools.combinations(w, 2)) for w in wins]

    def floor_of(order):
        worst = 1e9
        for win in pairs:
            for a, b in win:
                worst = min(worst, d[order[a]][order[b]])
        return worst

    if VERIFY_ONLY:
        best = tuple(range(n))
        best_score = floor_of(best)
    else:
        movable = list(range(1, n)) if PIN_FIRST else list(range(n))
        head = (0,) if PIN_FIRST else ()
        best_score, best = -1.0, None
        for perm in itertools.permutations(movable):
            order = head + perm
            s = floor_of(order)
            if s > best_score:
                best_score, best = s, order

    print(f"slot  name                 light    dark")
    for i, idx in enumerate(best):
        nm, l, dk = PALETTE[idx]
        print(f" {i:>2}   {nm:<18s}  {hex_of(l)}  {hex_of(dk)}")
    print(f"\nPer {WINDOW}-day window (incl. wrap) — min ΔE and binding pair:")
    for s in range(n):
        win = [(s + k) % n for k in range(WINDOW)]
        m, bp = 1e9, None
        for a, b in itertools.combinations(win, 2):
            if d[best[a]][best[b]] < m:
                m = d[best[a]][best[b]]
                bp = (PALETTE[best[a]][0], PALETTE[best[b]][0])
        days = "-".join(str(w + 1) for w in win)
        print(f"  days {days:<16s} minΔE={m:5.1f}  ({bp[0]} / {bp[1]})")
    print(f"\nGUARANTEED min ΔE over ANY {WINDOW} consecutive days = {best_score:.1f}")


if __name__ == "__main__":
    main()
