"""Colour science helpers: WCAG contrast, sRGB compositing, Machado 2009 CVD, CIELAB, CIEDE2000."""
import math

def hex2rgba(h):
    h = h.lstrip('#')
    if len(h) == 6:
        return tuple(int(h[i:i+2], 16) / 255 for i in (0, 2, 4)) + (1.0,)
    if len(h) == 8:
        return tuple(int(h[i:i+2], 16) / 255 for i in (0, 2, 4, 6))
    raise ValueError(h)

def rgb2hex(rgb):
    return '#' + ''.join('%02X' % max(0, min(255, round(c * 255))) for c in rgb[:3])

def over(fg, bg):
    """Composite fg (rgba, sRGB-encoded) over an opaque bg in gamma space, as AppKit and CSS do."""
    a = fg[3]
    return tuple(fg[i] * a + bg[i] * (1 - a) for i in range(3)) + (1.0,)

def stack(*hexes):
    """First item is the opaque base; later items are composited over it in order."""
    c = hex2rgba(hexes[0])
    if c[3] < 1:
        raise ValueError('base must be opaque: %s' % hexes[0])
    for h in hexes[1:]:
        c = over(hex2rgba(h), c)
    return c

def lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4

def delin(c):
    c = max(0.0, min(1.0, c))
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055

def luminance(rgb):
    r, g, b = (lin(x) for x in rgb[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)

MACHADO = {
    'protan': ((0.152286, 1.052583, -0.204868), (0.114503, 0.786281, 0.099216), (-0.003882, -0.048116, 1.051998)),
    'deutan': ((0.367322, 0.860646, -0.227968), (0.280085, 0.672501, 0.047413), (-0.011820, 0.042940, 0.968881)),
    'tritan': ((1.255528, -0.076749, -0.178779), (-0.078411, 0.930809, 0.147602), (0.004733, 0.691367, 0.303900)),
}

def simulate(rgb, kind):
    if kind == 'normal':
        return rgb[:3]
    m = MACHADO[kind]
    l = [lin(x) for x in rgb[:3]]
    out = [max(0.0, min(1.0, sum(m[i][j] * l[j] for j in range(3)))) for i in range(3)]
    return tuple(delin(x) for x in out)

def rgb2lab(rgb):
    r, g, b = (lin(x) for x in rgb[:3])
    X = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
    Y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
    Z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
    def f(t):
        return t ** (1 / 3) if t > 216 / 24389 else (24389 / 27 * t + 16) / 116
    fx, fy, fz = f(X / 0.95047), f(Y / 1.0), f(Z / 1.08883)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))

def lab2rgb(L, a, b):
    fy = (L + 16) / 116
    fx = fy + a / 500
    fz = fy - b / 200
    def finv(t):
        return t ** 3 if t ** 3 > 216 / 24389 else (116 * t - 16) / (24389 / 27)
    X, Y, Z = finv(fx) * 0.95047, finv(fy), finv(fz) * 1.08883
    r = 3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z
    g = -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z
    bb = 0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z
    inside = all(-1e-4 <= v <= 1 + 1e-4 for v in (r, g, bb))
    return tuple(delin(v) for v in (r, g, bb)), inside

def lch2rgb(L, C, h):
    return lab2rgb(L, C * math.cos(math.radians(h)), C * math.sin(math.radians(h)))

def lab2lch(lab):
    L, a, b = lab
    return L, math.hypot(a, b), math.degrees(math.atan2(b, a)) % 360

def de2000(lab1, lab2):
    L1, a1, b1 = lab1
    L2, a2, b2 = lab2
    C1 = math.hypot(a1, b1); C2 = math.hypot(a2, b2)
    Cb = (C1 + C2) / 2
    G = 0.5 * (1 - math.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p = math.degrees(math.atan2(b1, a1p)) % 360 if C1p else 0
    h2p = math.degrees(math.atan2(b2, a2p)) % 360 if C2p else 0
    dLp = L2 - L1
    dCp = C2p - C1p
    if C1p * C2p == 0:
        dhp = 0
    else:
        dhp = h2p - h1p
        if dhp > 180: dhp -= 360
        elif dhp < -180: dhp += 360
    dHp = 2 * math.sqrt(C1p * C2p) * math.sin(math.radians(dhp / 2))
    Lbp = (L1 + L2) / 2
    Cbp = (C1p + C2p) / 2
    if C1p * C2p == 0:
        hbp = h1p + h2p
    elif abs(h1p - h2p) <= 180:
        hbp = (h1p + h2p) / 2
    elif h1p + h2p < 360:
        hbp = (h1p + h2p + 360) / 2
    else:
        hbp = (h1p + h2p - 360) / 2
    T = (1 - 0.17 * math.cos(math.radians(hbp - 30)) + 0.24 * math.cos(math.radians(2 * hbp))
         + 0.32 * math.cos(math.radians(3 * hbp + 6)) - 0.20 * math.cos(math.radians(4 * hbp - 63)))
    dth = 30 * math.exp(-(((hbp - 275) / 25) ** 2))
    Rc = 2 * math.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7))
    Sl = 1 + 0.015 * (Lbp - 50) ** 2 / math.sqrt(20 + (Lbp - 50) ** 2)
    Sc = 1 + 0.045 * Cbp
    Sh = 1 + 0.015 * Cbp * T
    Rt = -math.sin(math.radians(2 * dth)) * Rc
    return math.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh))

KINDS = ('normal', 'protan', 'deutan', 'tritan')

def cvd_lab(rgb):
    return {k: rgb2lab(simulate(rgb, k)) for k in KINDS}

def de_all(rgb1, rgb2):
    """Returns {kind: dE2000} between two colours as seen with normal vision and each dichromacy."""
    return {k: de2000(rgb2lab(simulate(rgb1, k)), rgb2lab(simulate(rgb2, k))) for k in KINDS}
