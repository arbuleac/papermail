"""Theme derivation (§4.16): a theme is a few seeds plus one rule over Study's table, and the targeted adjustments are
rules too, so no hex value is set by hand and a change to Study's table re-derives every theme (build.py re-checks it).

The rule keeps every token's relative luminance and changes only its hue and chroma. WCAG contrast reads luminance
alone, so every pair the build asserts keeps Study's ratio in every theme, alpha washes included (they move only by
8-bit rounding). derive(spec) -> {token: {mode: hex}} for every token of `color`. Stdlib and colorlib only."""
import colorlib as c
import tokens_def as T

H = c.hex2rgba
MODES = ['light', 'dark', 'lightHC', 'darkHC']
ORDER = [r[0] for r in T.COLOR]
# Study: Quire's `color` table, the template every theme is derived from and measured against
Q = {n: dict(zip(MODES, (l, d, lh, dh))) for n, l, d, lh, dh, g, u in T.COLOR}
# The compiled AccentColor asset: quire-tokens.swift writes it from Study's accentFill, and macOS reads it once at
# launch, so native chrome cannot follow a theme switch; every coloured theme's fill stays near it instead (R3)
ASSET = {m: Q['accentFill'][m] for m in MODES}


# ---------------------------------------------------------------- colour helpers (CIELAB L* is a function of Y alone)
def rgb(h):
    return H(h[:7])


def lab(h):
    return c.rgb2lab(rgb(h))


def de(a, b):
    return c.de2000(lab(a), lab(b))


def de_min(a, b):
    """The smallest CIEDE2000 over normal vision and the three simulated dichromacies."""
    return min(c.de_all(rgb(a), rgb(b)).values())


def lch(h):
    return c.lab2lch(lab(h))


def Y(h):
    return c.luminance(rgb(h))


def cr(a, b):
    return c.contrast(rgb(a), rgb(b))


def L_of_Y(Yt):
    return 116 * Yt ** (1 / 3) - 16 if Yt > 0.008856 else 903.3 * Yt


def at(Yt, C, h):
    """In-gamut sRGB hex at relative luminance Yt, LCh hue h, chroma up to C (stepping down 0.1 until it fits)."""
    if Yt >= 0.99999:
        return '#FFFFFF'
    if Yt <= 0:
        return '#000000'
    L = L_of_Y(Yt)
    CC = C
    while CC >= 0:
        v, ok = c.lch2rgb(L, CC, h)
        if ok:
            return c.rgb2hex(v)
        CC -= 0.1
    return c.rgb2hex(c.lch2rgb(L, 0, 0)[0])


def split(hx):
    return (hx[:7], hx[7:]) if len(hx) == 9 else (hx, '')


def retint(hx, h, k, cap=7.0, yscale=1.0, floor=0.0):
    rgbhex, alpha = split(hx)
    # pure white and black carry no hue to move, and a theme without depth must not shift them by rounding
    if rgbhex.upper() in ('#FFFFFF', '#000000') and yscale == 1.0:
        return hx
    Y0 = Y(rgbhex)
    _, C, _ = lch(rgbhex)
    return at(Y0 * yscale, min(cap, max(floor, k * C)), h) + alpha


def mix_h(h1, h2, t):
    d = (h2 - h1 + 540) % 360 - 180
    return (h1 + d * t) % 360


def resolve(table, stack, m):
    """A stack of tokens composited left to right, as build.py's resolve_stack does."""
    cur = H(table[stack[0]][m])
    for s in stack[1:]:
        cur = c.over(H(table[s][m]), cur)
    return c.rgb2hex(cur)


# ---------------------------------------------------------------- token families
NEUTRAL = ['spine', 'paper', 'canvas', 'sheet', 'raised', 'slip', 'knob', 'ink', 'ink2', 'ink3', 'inkDisabled', 'onSlip',
           'onSlip2', 'rule', 'ruleStrong', 'onSlipEdge', 'hover', 'pressed', 'fill', 'slipHover', 'slipPressed', 'scrim',
           'selWashIdle', 'swipeRead', 'swipeArchiveNeutral']
FILLS = ['accentFill', 'accentFillHover', 'accentFillPressed', 'controlOnPressed']
WASHES = ['accentWash', 'accentWashHover', 'accentWashPressed', 'selWash']
MARKS = ['accent', 'focus', 'selRule']
# identical in every theme: a meaning must read the same whatever the paper
SEMANTIC = ['star', 'success', 'warning', 'danger', 'info', 'successWash', 'warningWash', 'dangerWash', 'infoWash',
            'findWash', 'findCurrent', 'dangerFill', 'dangerFillHover', 'dangerFillPressed', 'onDanger']
BANNER_WASHES = ['successWash', 'warningWash', 'dangerWash', 'infoWash']
SURF = ['spine', 'paper', 'canvas', 'sheet', 'raised', 'selWashIdle']
INKS = ['ink', 'ink2', 'ink3', 'inkDisabled', 'onSlip', 'onSlip2', 'onSlipEdge']
# luminance x `depth` in Dark and Dark IC when a theme declares one (Dusk): the surfaces, the idle selection, the hairline
# and the quiet-toggle washes; never `selWash` (the 1.25 scan cue) and never the slip (a slip is its own surface)
DEEP = ['spine', 'paper', 'canvas', 'sheet', 'raised', 'selWashIdle', 'rule', 'accentWash', 'accentWashHover', 'accentWashPressed']
# ...of which the structure tokens are not scaled but ratio-locked: each keeps Study's contrast ratio against the deepened
# surface it is drawn on, so a hairline, the idle selection and a quiet toggle's on state lose nothing to the depth
RATIO_LOCK = {'rule': 'sheet', 'selWashIdle': 'paper', 'accentWash': 'sheet', 'accentWashHover': 'sheet', 'accentWashPressed': 'sheet'}

# ---------------------------------------------------------------- rule constants (theme_rules.py asserts them)
SHEET_WHITE_DE = de(Q['sheet']['light'], '#FFFFFF') + 1e-6   # 1.53: Study's own light sheet
SHEET_CMAX = 1.6
ASSET_DE_MAX = 7.5            # accentFill vs the compiled AccentColor asset
SEL_KEY_IDLE_MIN = 6.0        # selWash vs selWashIdle, normal vision
BANNER_PAGE_MIN = 6.5         # banner washes vs sheet and paper (Study's closest: successWash on paper, 6.7)
NIGHT_FIND_MIN = 4.6          # a declared night ink stays >= this on findCurrent (asserted after 8-bit rounding)
RATIO_LOCK_TOL = 0.01         # a ratio-locked token keeps >= Study's ratio x (1 - this) on its deepened reference
AVATAR_MIN = 5.0              # avatar faces vs the surfaces they sit on: min(5, Study's own)
AV_SURF = ('paper', 'sheet', 'canvas', 'selWash', 'selWashIdle')


def declared(spec):
    """(token, mode) pairs a theme declares deeper than Study, which the luminance lock (R4) then leaves alone."""
    if not spec or spec.get('depth', 1.0) == 1.0:
        return set()
    out = {(t, m) for t in DEEP if t in NEUTRAL for m in ('dark', 'darkHC')}
    if spec.get('nightText'):
        out.add(('ink', 'dark'))
    return out


def locked_Y(tok, out, m):
    """The luminance that gives `tok` Study's contrast ratio against its reference surface in this theme (same side)."""
    ref = RATIO_LOCK[tok]
    r = cr(Q[tok][m], Q[ref][m])
    Yr = Y(out[ref][m])
    return r * (Yr + 0.05) - 0.05 if Y(Q[tok][m]) >= Y(Q[ref][m]) else (Yr + 0.05) / r - 0.05


def avatar_ok(out, m, surf):
    for a in T.AVATARS:
        face = a[m][0]
        if de(face, out[surf][m]) < min(AVATAR_MIN, de(face, Q[surf][m])) - 1e-9:
            return False
    return True


def study():
    return {t: dict(Q[t]) for t in ORDER}


def table(theme):
    """The theme's full colour table: Study's own for the default, the derivation for every other."""
    return study() if theme['spec'] is None else derive(theme['spec'])


def derive(spec):
    out = {t: {} for t in ORDER}
    for m in MODES:
        dark = m.startswith('dark')
        depth = spec.get('depth', 1.0) if dark else 1.0
        # 1. the neutral ramp: Study's luminance (x depth where declared), the theme's hue and chroma
        for t in NEUTRAL:
            ys = depth if t in DEEP else 1.0
            k = spec['nk'] * spec.get('ik', 0.8) if t in INKS else spec['nk']
            fl = spec.get('dfloor', 0.0) if (dark and t in SURF) else 0.0
            out[t][m] = retint(Q[t][m], spec['nh'], k, spec.get('ncap', 7.0), ys, fl)
            if depth != 1.0 and t in RATIO_LOCK:
                out[t][m] = at(locked_Y(t, out, m), min(spec.get('ncap', 7.0), max(fl, k * lch(Q[t][m])[1])), spec['nh'])
        # 1b. a declared night ink (Dark only): body text keeps Study's ratio on the theme's deeper sheet, so the night
        # is deeper without being brighter
        if m == 'dark' and spec.get('nightText'):
            r_study = cr(Q['ink'][m], Q['sheet'][m])
            Ys = Y(out['sheet'][m])
            Yt = r_study * (Ys + 0.05) - 0.05
            Yt = max(Yt, NIGHT_FIND_MIN * (Y(Q['findCurrent'][m]) + 0.05) - 0.05)
            _, C0, _ = lch(out['ink'][m])
            out['ink'][m] = at(Yt, C0, spec['nh'])
            # the floor must hold after 8-bit rounding: take the first value that meets it, not the nearest
            while cr(out['ink'][m], Q['findCurrent'][m]) < NIGHT_FIND_MIN:
                Yt += 0.0002
                out['ink'][m] = at(Yt, C0, spec['nh'])
        # 2. the light sheet stays the page under styled mail: no farther from white, and no more chroma, than Study's
        if not dark and spec['nk'] > 0:
            Ys, Creq = Y(out['sheet'][m]), lch(out['sheet'][m])[1]
            while (de(out['sheet'][m], '#FFFFFF') > SHEET_WHITE_DE or lch(out['sheet'][m])[1] > SHEET_CMAX) and Creq > 0:
                Creq = max(0.0, Creq - 0.1)
                out['sheet'][m] = at(Ys, Creq, spec['nh'])
        # 3. fixed and derived
        out['slipEdge'][m] = Q['slipEdge'][m]
        out['originalPage'][m] = '#FFFFFF'
        # AppKit draws a swipe button's title white whatever the fill (§5.7), so its token never moves
        out['onSwipe'][m] = Q['onSwipe'][m]
        out['selRuleIdle'][m] = out['ink3'][m]
        out['scrimSolid'][m] = c.rgb2hex(c.over(H(out['scrim'][m]), H(out['canvas'][m])))
        for t in SEMANTIC:
            out[t][m] = Q[t][m]
        if spec.get('inkless'):
            pass  # the accent family is the theme's own Graphite substitution, resolved below once the neutrals are final
        else:
            seed = spec['acc'][m]
            Ya, Ca = seed[0], seed[1]
            ah = seed[2] if len(seed) > 2 else spec['ah']
            # 4. the ink as a mark
            mark = at(Ya, Ca, ah)
            for t in MARKS:
                out[t][m] = mark
            f = Ca / lch(Q['accent'][m])[1]
            ff = min(f, spec.get('fillcap', 1.25))
            fw = min(f, spec.get('washcap', 1.3))
            # 5. fills: Study's luminance in the ink's hue; pulled toward Iron Gall (hue and chroma together, one step for
            # all four) until accentFill is within ASSET_DE_MAX of the compiled accent asset
            fh = ah
            t_pull = 0.0
            while True:
                fills = {}
                for t in FILLS:
                    q = Q[t][m]
                    Lq, Cq, hq = lch(q)
                    fills[t] = at(Y(q), Cq * (ff + (1 - ff) * t_pull), mix_h(fh, hq, t_pull))
                if de(fills['accentFill'], ASSET[m]) <= ASSET_DE_MAX or t_pull >= 1.0:
                    break
                t_pull = min(1.0, t_pull + 0.02)
            for t in FILLS:
                out[t][m] = fills[t]
            # 6. washes: Study's luminance (ratio-locked where depth is declared) in the ink's hue; the selection wash
            # never carries less chroma than Study's, because it is the scan cue for the selected row
            fsel = min(max(f, 1.0), spec.get('washcap', 1.3))
            for t in WASHES:
                q = Q[t][m]
                Yw = Y(q) if (t == 'selWash' or depth == 1.0) else locked_Y(t, out, m)
                out[t][m] = at(Yw, lch(q)[1] * (fsel if t == 'selWash' else fw), spec.get('wh', {}).get(m, ah))
            # ...and its hue steps toward Study's selection hue until no avatar face sinks into it (R9)
            hq = lch(Q['selWash'][m])[2]
            h_sel = spec.get('wh', {}).get(m, ah)
            t_sel = 0.0
            while not avatar_ok(out, m, 'selWash') and t_sel < 1.0:
                t_sel = min(1.0, t_sel + 0.05)
                q = Q['selWash'][m]
                out['selWash'][m] = at(Y(q), lch(q)[1] * fsel, mix_h(h_sel, hq, t_sel))
            out['onAccent'][m] = '#FFFFFF'
            if dark:
                # an on-state fill is the only mark of its state: >= 3.03:1 on sheet and canvas, white label >= 4.6:1
                for t in ('accentFill', 'accentFillHover', 'controlOnPressed'):
                    x = out[t][m]
                    Lx, Cx, hx = lch(x)
                    Yx = Y(x)
                    while min(cr(x, out['sheet'][m]), cr(x, out['canvas'][m])) < 3.03 and cr('#FFFFFF', x) > 4.6:
                        Yx *= 1.003
                        x = at(Yx, Cx, hx)
                    out[t][m] = x
            # the swipe's Archive wears the fill as finally lifted; only its Graphite value sets it apart (§5.7)
            out['swipeArchive'][m] = out['accentFill'][m]
        # 7. key and not-key selection stay apart: the idle wash gives up chroma (toward neutral) until it is
        # SEL_KEY_IDLE_MIN from the key wash and no avatar face sinks into it
        Yi, (L0, Creq, h0) = Y(out['selWashIdle'][m]), lch(out['selWashIdle'][m])
        while not spec.get('inkless') and (de(out['selWash'][m], out['selWashIdle'][m]) < SEL_KEY_IDLE_MIN or not avatar_ok(out, m, 'selWashIdle')) and Creq > 0:
            Creq = max(0.0, Creq - 0.1)
            out['selWashIdle'][m] = at(Yi, Creq, h0)
        out['selRuleIdle'][m] = out['ink3'][m]
        # 8. banners stay banners: a semantic wash closer than BANNER_PAGE_MIN to the theme's sheet or paper, or closer
        # to its canvas (where Settings draws banners) than min(6.5, Study's own), gains chroma at its own hue and
        # luminance until it clears; luminance is unchanged, so its text pairs keep their ratio
        for t in BANNER_WASHES:
            x = out[t][m]
            Lx, Cx, hx = lch(x)
            Yx = Y(x)
            fc = min(BANNER_PAGE_MIN, de(Q[t][m], Q['canvas'][m]))
            while (min(de(x, out['sheet'][m]), de(x, out['paper'][m])) < BANNER_PAGE_MIN or de(x, out['canvas'][m]) < fc - 1e-9) and Cx < 30:
                Cx += 0.2
                x = at(Yx, Cx, hx)
            out[t][m] = x
        # 9. an inkless theme writes in its own text ink: the accent family is T.GRAPHITE resolved against the theme's
        # final neutrals, exactly what the system Graphite accent gives it
        if spec.get('inkless'):
            for k, (v, use) in T.GRAPHITE.items():
                out[k][m] = resolve(out, v if isinstance(v, list) else [v], m)
            # ...except the key selection: it keeps Study's selection luminance in the theme's neutral, so the two 1.25
            # scan cues stay asserted pairs (system Graphite drops them; a theme may not)
            out['selWash'][m] = retint(Q['selWash'][m], spec['nh'], spec['nk'], spec.get('ncap', 7.0))
    return out
