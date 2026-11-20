#!/usr/bin/env python3
"""Generates paper_faces.json for the "Scissor-cut" paper avatar set.

Every shape is a closed Catmull-Rom curve through a few control points,
converted to cubic Beziers, with a small seeded jitter so edges read as
hand-cut with scissors rather than drawn with a compass. Points flagged as
corners get zero tangents (sharp scissor turns). Holes are wound opposite to
their outer contour, so nonzero and even-odd fills give the same result.

Run: python3 paper_faces_gen.py  (writes paper_faces.json next to this file)
"""
import json
import math
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))


def fmt(v):
    s = f"{v:.1f}"
    if s.endswith(".0"):
        s = s[:-2]
    if s in ("-0", "-0.0"):
        s = "0"
    return s


class Cutter:
    """Seeded scissors: every shape cut by one Cutter shares a hand."""

    def __init__(self, seed, wobble=0.7, tension=0.15):
        self.r = random.Random(seed)
        self.wobble = wobble
        self.tension = tension
        self.xf = None  # (scale, ox, oy): scales the cut around a point (used to size heads)

    def jit(self, pts, amount=None):
        a = self.wobble if amount is None else amount
        return [(x + self.r.uniform(-a, a), y + self.r.uniform(-a, a)) for x, y in pts]

    def curve(self, pts, corners=(), wobble=None, tension=None, reverse=False):
        """Closed curve through pts; indices in corners are sharp."""
        if self.xf:
            k, ox, oy = self.xf
            pts = [(ox + (x - ox) * k, oy + (y - oy) * k) for x, y in pts]
        pts = self.jit(pts, wobble)
        corners = set(corners)
        if reverse:
            n = len(pts)
            pts = pts[::-1]
            corners = {n - 1 - i for i in corners}
        t = self.tension if tension is None else tension
        n = len(pts)

        def tan(i):
            if i in corners:
                return (0.0, 0.0)
            p0, p2 = pts[(i - 1) % n], pts[(i + 1) % n]
            return ((p2[0] - p0[0]) * t, (p2[1] - p0[1]) * t)

        d = [f"M{fmt(pts[0][0])} {fmt(pts[0][1])}"]
        for i in range(n):
            p1, p2 = pts[i], pts[(i + 1) % n]
            t1, t2 = tan(i), tan((i + 1) % n)
            c1 = (p1[0] + t1[0], p1[1] + t1[1])
            c2 = (p2[0] - t2[0], p2[1] - t2[1])
            d.append(
                f"C{fmt(c1[0])} {fmt(c1[1])} {fmt(c2[0])} {fmt(c2[1])} {fmt(p2[0])} {fmt(p2[1])}"
            )
        d.append("Z")
        return " ".join(d)

    def oval(self, cx, cy, rx, ry, n=9, rot=0.0, wobble=None, reverse=False, squash=0.0):
        """Hand-cut oval. squash > 0 narrows the lower half (egg / jaw)."""
        ph = self.r.uniform(0, 2 * math.pi / n)
        pts = []
        for i in range(n):
            a = ph + 2 * math.pi * i / n
            x, y = rx * math.cos(a), ry * math.sin(a)
            if squash and y > 0:
                x *= 1 - squash * (y / ry)
            c, s = math.cos(rot), math.sin(rot)
            pts.append((cx + x * c - y * s, cy + x * s + y * c))
        return self.curve(pts, wobble=wobble, reverse=reverse)

    def ring(self, cx, cy, r_out, r_in, n=9):
        return self.oval(cx, cy, r_out, r_out, n) + " " + self.oval(cx, cy, r_in, r_in, n, reverse=True)

    def lobed(self, pts, lobes, bulge=0.85, wobble=None, tension=None):
        """Closed outline where segments listed in `lobes` are cut as round bumps
        bulging outward (curls, scallops); the rest are smooth curves."""
        if self.xf:
            k, ox, oy = self.xf
            pts = [(ox + (x - ox) * k, oy + (y - oy) * k) for x, y in pts]
        pts = self.jit(pts, wobble)
        n = len(pts)
        lobes = set(lobes)
        area = sum(pts[i][0] * pts[(i + 1) % n][1] - pts[(i + 1) % n][0] * pts[i][1] for i in range(n))
        sgn = 1 if area > 0 else -1  # > 0: clockwise on screen (y down)
        corner = {i for i in range(n) if i in lobes or (i - 1) % n in lobes}
        t = self.tension if tension is None else tension

        def tan(i):
            if i in corner:
                return (0.0, 0.0)
            p0, p2 = pts[(i - 1) % n], pts[(i + 1) % n]
            return ((p2[0] - p0[0]) * t, (p2[1] - p0[1]) * t)

        d = [f"M{fmt(pts[0][0])} {fmt(pts[0][1])}"]
        for i in range(n):
            p1, p2 = pts[i], pts[(i + 1) % n]
            if i in lobes:
                dx, dy = p2[0] - p1[0], p2[1] - p1[1]
                s = math.hypot(dx, dy)
                nx, ny = sgn * dy / s, -sgn * dx / s
                h = s * 2 / 3 * bulge * self.r.uniform(0.9, 1.1)
                lean = self.r.uniform(-0.12, 0.12) * s
                c1 = (p1[0] + nx * h + dx / s * lean, p1[1] + ny * h + dy / s * lean)
                c2 = (p2[0] + nx * h + dx / s * lean, p2[1] + ny * h + dy / s * lean)
            else:
                t1, t2 = tan(i), tan((i + 1) % n)
                c1 = (p1[0] + t1[0], p1[1] + t1[1])
                c2 = (p2[0] - t2[0], p2[1] - t2[1])
            d.append(f"C{fmt(c1[0])} {fmt(c1[1])} {fmt(c2[0])} {fmt(c2[1])} {fmt(p2[0])} {fmt(p2[1])}")
        d.append("Z")
        return " ".join(d)


def mirror(pts, cx=50):
    return [(2 * cx - x, y) for x, y in pts]


def L(d, fill, lift):
    return {"d": d, "fill": fill, "lift": lift}


# ---------------------------------------------------------------- palette
# The papers are Quire tokens (tokens_def.PAPERS, §5.55): light is the paper in daylight, dark the same paper under a
# dimmer, warm lamp. The art only names them.
from tokens_def import PAPERS

PALETTE = {p["name"]: (p["light"], p["dark"]) for p in PAPERS}


# ---------------------------------------------------------------- people parts
def shirt(c, neckline="round", top=80, dip=8, width=1.0):
    """Shoulders cut as one sheet; extends below the circle."""
    w = width
    left = [
        (50 - 52 * w, 112),
        (50 - 47 * w, 92),
        (50 - 36 * w, top + 2),
        (50 - 13, top - 1),
    ]
    if neckline == "v":
        mid = [(50, top + dip + 4)]
        corners = [3, 4, 5]
    elif neckline == "high":
        mid = [(50, top - 2)]
        corners = []
    else:
        mid = [(50 - 6, top + dip * 0.8), (50 + 6, top + dip * 0.8)]
        corners = [3, 6]
    right = mirror(left)[::-1]
    pts = left + mid + right
    return c.curve(pts, corners=[0, len(pts) - 1] + corners)


def neck(c, w=8.5, top=56, bottom=96):
    pts = [(50 - w, top), (50 + w, top), (50 + w + 1, bottom), (50 - w - 1, bottom)]
    return c.curve(pts, corners=[2, 3], wobble=0.4)


def head(c, cx=50, cy=45, rx=20.5, ry=24.5, ears=False, squash=0.18, ear_y=47):
    """Head as an egg; optional ears cut into the same outline."""
    n = 14
    pts = []
    for i in range(n):
        a = -math.pi / 2 + 2 * math.pi * i / n
        x, y = rx * math.cos(a), ry * math.sin(a)
        if y > 0:
            x *= 1 - squash * (y / ry)
        pts.append((cx + x, cy + y))
    if ears:
        # insert ear bumps on both sides (index 3/4 is right flank, 10/11 left)
        out = []
        for i, p in enumerate(pts):
            out.append(p)
            if i == 3:
                out += [(cx + rx + 3.5, ear_y - 5), (cx + rx + 4.0, ear_y + 1), (cx + rx - 0.5, ear_y + 5)]
            if i == 10:
                out += [(cx - rx + 0.5, ear_y + 5), (cx - rx - 4.0, ear_y + 1), (cx - rx - 3.5, ear_y - 5)]
        pts = out
    return c.curve(pts, wobble=0.5)


def eyes(c, y=46, dx=8.5, rx=3.3, ry=3.9, cx=50):
    return c.oval(cx - dx, y, rx, ry, 7, wobble=0.25) + " " + c.oval(cx + dx, y, rx, ry, 7, wobble=0.25)


def smile(c, cx=50, y=57, w=11, h=4.5, lift=1.5):
    """Crescent smile: a deep lower arc and a shallow upper arc."""
    pts = [
        (cx - w / 2, y - lift),
        (cx - w / 4, y + h * 0.15),
        (cx + w / 4, y + h * 0.15),
        (cx + w / 2, y - lift),
        (cx + w / 3, y + h * 0.85),
        (cx, y + h * 1.15),
        (cx - w / 3, y + h * 0.85),
    ]
    return c.curve(pts, corners=[0, 3], wobble=0.25)


def cheeks(c, y=55, dx=13, r=3.6, cx=50):
    return c.oval(cx - dx, y, r, r * 0.85, 7, wobble=0.25) + " " + c.oval(cx + dx, y, r, r * 0.85, 7, wobble=0.25)


# ---------------------------------------------------------------- faces
HEAD = (1.13, 50, 47)  # people: heads, hair and features are cut 13% larger than the shoulders


def almond_eyes(c, y, dx=8.5, w=9.4, h=6.0, cx=50):
    """Eye whites: two lens shapes with sharp corners."""
    out = []
    for ex in (cx - dx, cx + dx):
        out.append(c.curve([(ex - w / 2, y + 0.3), (ex, y - h / 2), (ex + w / 2, y + 0.3), (ex, y + h / 2)],
                           corners=[0, 2], wobble=0.2, tension=0.22))
    return " ".join(out)


def pupils(c, y, dx=8.5, r=2.75, cx=50):
    return c.oval(cx - dx, y, r, r * 1.04, 7, wobble=0.15) + " " + c.oval(cx + dx, y, r, r * 1.04, 7, wobble=0.15)


def glasses_rims(c, y, dx=9.5, r_out=8.6, r_in=5.4):
    bridge_y = y - 2.2
    return (c.ring(50 - dx, y, r_out, r_in, 9) + " " + c.ring(50 + dx, y, r_out, r_in, 9)
            + " " + c.curve([(50 - dx + r_out - 0.6, bridge_y - 1.3), (50 + dx - r_out + 0.6, bridge_y - 1.3),
                             (50 + dx - r_out + 0.6, bridge_y + 1.3), (50 - dx + r_out - 0.6, bridge_y + 1.3)],
                            corners=[0, 1, 2, 3], wobble=0.1))


def face_curly():
    c = Cutter("curly")
    neck_ = neck(c, w=9.5, top=60)
    shirt_ = shirt(c, "round", top=83)
    c.xf = HEAD
    head_ = head(c, cy=48, rx=19.5, ry=23)
    # A horseshoe of curls laid over the head: round curls outside, a fringe of curls on the forehead.
    arc = [(50 + 30 * math.cos(math.radians(a)), 41 + 30 * 0.98 * math.sin(math.radians(a)))
           for a in [140 + 260 * i / 11 for i in range(12)]]
    right = [(69.5, 61.5), (70.5, 50), (68.5, 38)]
    fringe = [(62.5, 33.5), (56.3, 32.5), (50, 32.2), (43.7, 32.5), (37.5, 33.5), (31.5, 38)]
    left = [(29.5, 50), (30.5, 61.5)]
    pts = arc + right + fringe + left
    n_arc = len(arc)
    lobes = list(range(0, n_arc - 1)) + [n_arc - 1] + list(range(n_arc + 2, n_arc + 2 + 6)) + [len(pts) - 1]
    curls = c.lobed(pts, lobes, bulge=0.8, wobble=0.35)
    return {
        "id": "curly-hair",
        "name": "Person with curly hair",
        "background": "rose",
        "layers": [
            L(neck_, "umber", 0),
            L(shirt_, "ochre", 1),
            L(head_, "umber", 1),
            L(curls, "ink", 2),
            L(almond_eyes(c, 49.5), "cream", 1),
            L(pupils(c, 49.7), "ink", 0),
            L(smile(c, y=59.5, w=11), "rose", 1),
        ],
    }


def face_beard():
    c = Cutter("beard")
    sweater = shirt(c, "high", top=79)
    c.xf = HEAD
    hair = c.curve(
        [(29.5, 47), (28.5, 33), (33, 22), (43, 15.5), (54, 15), (66, 18.5), (72, 28), (71.5, 47),
         (68.5, 38), (63, 32), (52, 30.5), (40, 32), (32.5, 38)],
        corners=[0, 7],
        tension=0.17,
    )
    beard = c.curve(
        [(29.5, 46), (36.5, 56), (44, 57.5), (50, 56), (56, 57.5), (63.5, 56), (70.5, 46),
         (70.5, 57), (65, 70), (56, 78), (50, 79.5), (44, 78), (35, 70), (29.5, 57)],
        corners=[0, 3, 6],
        tension=0.16,
    )
    return {
        "id": "beard-glasses",
        "name": "Person with a red beard and glasses",
        "background": "ultramarine",
        "layers": [
            L(sweater, "ochre", 1),
            L(head(c, ears=True, ear_y=48), "porcelain", 2),
            L(beard, "terracotta", 1),
            L(hair, "terracotta", 2),
            L(almond_eyes(c, 46.3, dx=9.5, w=8.6, h=5.6), "cream", 0),
            L(glasses_rims(c, 46) + " " + pupils(c, 46.5, dx=9.5, r=2.6), "ink", 1),
            L(smile(c, y=64, w=9, h=3.6, lift=1.0), "rose", 1),
        ],
    }


def face_hijab():
    c = Cutter("hijab")
    face = c.oval(50, 51, 22.5, 27.5, 10, squash=0.16)
    band = c.curve([(27, 42), (30, 27), (40, 19), (60, 19), (70, 27), (73, 42), (63, 34.5), (50, 32.5), (37, 34.5)],
                   corners=[0, 5], tension=0.16)
    outer = [(50, 5), (71, 9), (84, 24), (87, 46), (83, 64), (91, 78), (100, 90), (100, 112), (0, 112),
             (0, 90), (9, 78), (17, 64), (13, 46), (16, 24), (29, 9)]
    hole_c = Cutter("hijab-hole", wobble=0.4)
    hole = []
    for i in range(12):
        a = -math.pi / 2 + 2 * math.pi * i / 12
        x, y = 20.0 * math.cos(a), 25.5 * math.sin(a)
        if y > 0:
            x *= 1 - 0.2 * (y / 25.5)
        hole.append((50 + x, 52 + y))
    hijab = c.curve(outer, corners=[7, 8], tension=0.16) + " " + hole_c.curve(hole, reverse=True)
    return {
        "id": "hijab",
        "name": "Person wearing a hijab",
        "background": "ochre",
        "layers": [
            L(face, "honey", 0),
            L(band, "cream", 1),
            L(hijab, "leaf", 2),
            L(almond_eyes(c, 50.5, dx=9, w=9.6, h=6.2), "cream", 1),
            L(pupils(c, 50.8, dx=9, r=2.85), "ink", 0),
            L(smile(c, y=62, w=11.5, h=4.2) + " " + cheeks(c, y=59.5, dx=14, r=3.4), "terracotta", 1),
        ],
    }


def face_elder():
    c = Cutter("elder")
    neck_ = neck(c, w=9.5, top=60)
    shirt_ = shirt(c, "round", top=83)
    c.xf = HEAD
    bun = c.oval(50, 17.5, 9.5, 8.5, 9)
    hair = c.curve(
        [(29, 49), (28, 34), (34, 23), (44, 18.5), (56, 18.5), (66, 23), (72, 34), (71, 49),
         (67, 40), (59, 33), (50, 31.5), (41, 33), (33, 40)],
        corners=[0, 7],
        tension=0.17,
    )
    return {
        "id": "silver-bun",
        "name": "Older person with a silver bun and glasses",
        "background": "sage",
        "layers": [
            L(neck_, "sienna", 0),
            L(shirt_, "ultramarine", 1),
            L(head(c, ears=True, ear_y=49), "sienna", 2),
            L(bun + " " + hair, "cream", 2),
            L(almond_eyes(c, 47.3, dx=9.5, w=8.4, h=5.4), "cream", 0),
            L(glasses_rims(c, 47, r_out=8.4, r_in=5.3) + " " + pupils(c, 47.5, dx=9.5, r=2.5), "ink", 1),
            L(smile(c, y=59, w=12, h=4.2), "rose", 1),
        ],
    }


def face_bob():
    c = Cutter("bob")
    neck_ = neck(c, w=9.5, top=60)
    shirt_ = shirt(c, "round", top=83)
    c.xf = HEAD
    pts = [(50, 12), (67, 15), (78, 27), (81, 45), (81.5, 70), (66, 70), (66, 37.5), (50, 36.5), (34, 37.5),
           (34, 70), (18.5, 70), (19, 45), (22, 27), (33, 15)]
    hair = c.curve(pts, corners=[4, 5, 6, 8, 9, 10], tension=0.16)
    lips = c.curve([(44.5, 59), (48, 57), (50, 58), (52, 57), (55.5, 59), (52.5, 62.5), (47.5, 62.5)],
                   corners=[0, 2, 4], wobble=0.2)
    return {
        "id": "black-bob",
        "name": "Person with a black bob",
        "background": "terracotta",
        "layers": [
            L(neck_, "peach", 0),
            L(shirt_, "cream", 1),
            L(head(c, cy=46), "peach", 1),
            L(hair, "ink", 2),
            L(almond_eyes(c, 47, dx=8, w=8.6, h=5.6), "cream", 0),
            L(pupils(c, 47.3, dx=8, r=2.6), "ink", 0),
            L(lips + " " + cheeks(c, y=54.5, dx=12, r=3.0), "vermilion", 1),
        ],
    }


def face_wrap():
    c = Cutter("wrap")
    top = shirt(c, "high", top=75)
    c.xf = HEAD
    head_ = head(c, cy=48, ry=23.5)
    # a tall wrap gathered into two lobes, with a twisted band of ochre cloth across the front
    wrap = c.curve([(27.5, 43), (23, 32), (21, 21), (24, 13), (32.5, 9.5), (41.5, 11), (47, 15), (52, 9.5),
                    (61, 6.5), (71, 7.5), (78, 14), (80, 25), (75.5, 36), (72.5, 43), (62, 37.5), (50, 36), (38, 37.5)],
                   corners=[0, 6, 13], tension=0.17)
    band = c.curve([(29, 41), (31.5, 30), (38.5, 20.5), (47, 15), (52.5, 18.5), (45, 27), (40.5, 39.5)],
                   corners=[0, 3, 6], tension=0.17)
    return {
        "id": "head-wrap",
        "name": "Person wearing a head wrap",
        "background": "cream",
        "layers": [
            L(top, "terracotta", 1),
            L(head_, "cocoa", 2),
            L(wrap, "ultramarine", 2),
            L(band, "ochre", 1),
            L(almond_eyes(c, 49.5), "cream", 1),
            L(pupils(c, 49.7), "ink", 0),
            L(smile(c, y=59.5, w=12, h=4.6), "rose", 1),
        ],
    }


def face_beanie():
    c = Cutter("beanie")
    scarf = shirt(c, "high", top=74, width=1.0)
    c.xf = HEAD
    hat = c.curve([(27, 41), (27, 28), (35, 18), (50, 14), (65, 18), (73, 28), (73, 41)],
                  corners=[0, 6], tension=0.17)
    cuff = c.curve([(25, 34), (50, 29.5), (75, 34), (75.5, 44), (50, 40), (24.5, 44)],
                   corners=[0, 2, 3, 5], tension=0.12)
    pom = c.oval(50, 14.5, 7.5, 7, 9, wobble=0.6)
    return {
        "id": "beanie",
        "name": "Child in a red beanie",
        "background": "ultramarine",
        "layers": [
            L(scarf, "sage", 1),
            L(head(c, cy=49, rx=21, ry=22.5, ears=True, ear_y=52), "honey", 2),
            L(hat, "vermilion", 1),
            L(cuff, "vermilion", 2),
            L(pom + " " + almond_eyes(c, 52.5, dx=8.7), "cream", 1),
            L(pupils(c, 52.8, dx=8.7), "ink", 0),
            L(smile(c, y=61.5, w=12, h=4.4) + " " + cheeks(c, y=59.5, dx=14, r=3.4), "terracotta", 1),
        ],
    }


# ---------------------------------------------------------------- animals
def face_fox():
    c = Cutter("fox")
    ears_l = [(21, 8), (39, 26), (25, 36)]
    ears = c.curve(ears_l, corners=[0, 1, 2], tension=0.1) + " " + c.curve(mirror(ears_l)[::-1], corners=[0, 1, 2], tension=0.1)
    inner_l = [(25, 17), (34, 28), (27, 33)]
    inner = c.curve(inner_l, corners=[0, 1, 2], wobble=0.3) + " " + c.curve(mirror(inner_l)[::-1], corners=[0, 1, 2], wobble=0.3)
    headp = [(50, 22), (66, 24), (78, 34), (85, 50), (76, 62), (60, 76), (50, 84), (40, 76), (24, 62), (15, 50), (22, 34), (34, 24)]
    head_ = c.curve(headp, corners=[3, 6, 9], tension=0.17)
    mask = [(15, 50), (30, 52), (42, 60), (50, 58), (58, 60), (70, 52), (85, 50), (76, 62), (60, 76), (50, 84), (40, 76), (24, 62)]
    mask_ = c.curve(mask, corners=[0, 3, 6, 9], tension=0.17)
    feats = (
        c.curve([(33, 46), (37, 41.5), (42, 44), (38, 49)], corners=[0, 2], wobble=0.2)
        + " " + c.curve(mirror([(33, 46), (37, 41.5), (42, 44), (38, 49)])[::-1], corners=[1, 3], wobble=0.2)
        + " " + c.curve([(44.5, 74), (55.5, 74), (50, 81)], corners=[0, 1, 2], wobble=0.2, tension=0.1)
    )
    return {
        "id": "fox",
        "name": "Fox",
        "background": "sage",
        "layers": [
            L(ears, "terracotta", 1),
            L(inner, "ink", 0),
            L(head_, "terracotta", 2),
            L(mask_, "cream", 1),
            L(feats, "ink", 1),
        ],
    }


def face_cat():
    c = Cutter("cat")
    pts = [(50, 28), (63, 29), (77, 10), (81, 38), (85, 56), (78, 76), (62, 88), (50, 90), (38, 88), (22, 76), (15, 56), (19, 38), (23, 10), (37, 29)]
    headp = c.curve(pts, corners=[2, 12], tension=0.16)
    inner_l = [(27, 19), (35, 31), (26, 35)]
    inner = c.curve(inner_l, corners=[0, 1, 2], wobble=0.3) + " " + c.curve(mirror(inner_l)[::-1], corners=[0, 1, 2], wobble=0.3)
    eye_l = [(30, 52), (36, 45), (44, 49), (40, 57), (33, 57)]
    eyes_ = c.curve(eye_l, corners=[0, 2], wobble=0.25) + " " + c.curve(mirror(eye_l)[::-1], corners=[2, 4], wobble=0.25)
    pup = c.oval(37.5, 51.5, 1.8, 4.6, 6, wobble=0.15) + " " + c.oval(62.5, 51.5, 1.8, 4.6, 6, wobble=0.15)
    nose = c.curve([(45, 64), (55, 64), (50, 70)], corners=[0, 1, 2], tension=0.1, wobble=0.2)
    return {
        "id": "black-cat",
        "name": "Black cat",
        "background": "cream",
        "layers": [
            L(headp, "ink", 2),
            L(inner + " " + nose, "rose", 1),
            L(eyes_, "ochre", 1),
            L(pup, "ink", 0),
        ],
    }


def face_owl():
    c = Cutter("owl")
    body = c.curve([(20, 14), (36, 25), (50, 23), (64, 25), (80, 14), (85, 44), (83, 72), (72, 104), (28, 104), (17, 72), (15, 44)],
                   corners=[0, 4, 7, 8], tension=0.17)
    # heart-shaped facial disc around both eyes
    mask = c.curve([(50, 34), (60, 29), (74, 31), (82, 44), (78, 59), (64, 66), (50, 76), (36, 66), (22, 59), (18, 44), (26, 31), (40, 29)],
                   corners=[0, 6], tension=0.17)
    discs = c.oval(37, 47, 11.5, 11.5, 10) + " " + c.oval(63, 47, 11.5, 11.5, 10)
    ink = (c.oval(38, 48, 5.6, 5.8, 8, wobble=0.3) + " " + c.oval(62, 48, 5.6, 5.8, 8, wobble=0.3)
           + " " + c.curve([(45.5, 59), (54.5, 59), (50, 70)], corners=[0, 1, 2], tension=0.1, wobble=0.3))
    return {
        "id": "owl",
        "name": "Owl",
        "background": "leaf",
        "layers": [
            L(body, "terracotta", 2),
            L(mask, "ochre", 1),
            L(discs, "cream", 1),
            L(ink, "ink", 1),
        ],
    }


def face_rabbit():
    c = Cutter("rabbit")
    ear = c.oval(38, 26, 8.5, 22, 9, rot=-0.18) + " " + c.oval(62, 26, 8.5, 22, 9, rot=0.18)
    inner = c.oval(38.5, 27, 3.8, 15, 7, rot=-0.18, wobble=0.3) + " " + c.oval(61.5, 27, 3.8, 15, 7, rot=0.18, wobble=0.3)
    headp = c.oval(50, 64, 27, 24, 11)
    eyes_ = c.oval(39.5, 60, 3.4, 4.0, 7, wobble=0.25) + " " + c.oval(60.5, 60, 3.4, 4.0, 7, wobble=0.25)
    nose = c.curve([(45.5, 68), (54.5, 68), (50, 73.5)], corners=[0, 1, 2], tension=0.12, wobble=0.2)
    return {
        "id": "rabbit",
        "name": "Rabbit",
        "background": "terracotta",
        "layers": [
            L(ear, "cream", 1),
            L(inner, "rose", 0),
            L(headp, "cream", 2),
            L(eyes_, "ink", 0),
            L(nose + " " + cheeks(c, y=70, dx=14, r=3.6), "rose", 1),
        ],
    }


def face_frog():
    c = Cutter("frog")
    headp = c.curve([(14, 62), (18, 46), (24, 36), (24, 24), (34, 16), (44, 24), (50, 36), (56, 24), (66, 16), (76, 24), (76, 36), (82, 46), (86, 62), (80, 80), (50, 90), (20, 80)],
                    tension=0.16)
    chin = c.curve([(15.5, 64.5), (50, 71), (84.5, 64.5), (80.5, 79), (50, 89.5), (19.5, 79)], corners=[0, 2], tension=0.17)
    whites = c.oval(34, 26, 9.8, 9.8, 8) + " " + c.oval(66, 26, 9.8, 9.8, 8)
    ink = (c.oval(35, 27, 4.6, 5.0, 7, wobble=0.25) + " " + c.oval(65, 27, 4.6, 5.0, 7, wobble=0.25)
           + " " + c.curve([(28, 54), (50, 62), (72, 54), (71, 58.5), (50, 66.5), (29, 58.5)], corners=[0, 2, 3, 5], tension=0.16, wobble=0.25))
    return {
        "id": "frog",
        "name": "Frog",
        "background": "rose",
        "layers": [
            L(headp, "leaf", 2),
            L(chin, "sage", 1),
            L(whites, "cream", 1),
            L(ink, "ink", 0),
        ],
    }


FACES = [face_curly, face_beard, face_hijab, face_elder, face_bob, face_wrap, face_beanie,
         face_fox, face_cat, face_owl, face_rabbit, face_frog]

DIRECTION = (
    "Scissor-cut: bold, flat Matisse-like paper cut-outs with gently irregular hand-cut edges, "
    "a warm limited paper palette (terracotta, ochre, ultramarine, sage, rose, cream, ink) plus six skin papers, "
    "big simple features, and a different ground paper per face."
)


def main():
    faces = [f() for f in FACES]
    for f in faces:
        for l in f["layers"]:
            assert l["fill"] in PALETTE, l["fill"]
        assert f["background"] in PALETTE
    out = {
        "direction": DIRECTION,
        "viewBox": [0, 0, 100, 100],
        "fillRule": "nonzero",
        "palette": {k: {"light": v[0], "dark": v[1]} for k, v in PALETTE.items()},
        "faces": faces,
    }
    with open(os.path.join(HERE, "paper_faces.json"), "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"{len(faces)} faces, {sum(len(f['layers']) for f in faces)} layers")


if __name__ == "__main__":
    main()
