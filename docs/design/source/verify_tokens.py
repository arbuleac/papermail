"""Independent check: reads only docs/design/tokens.json (or the path given as the first argument) and, for every theme,
recomputes every contrast pair, every Graphite pair, every account rule and every theme rule from the values the file
carries, without build.py's derivation. Usage: python3 verify_tokens.py [tokens.json]"""
import json, itertools, os, sys
import colorlib as c
PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tokens.json')
t = json.load(open(PATH))
H = c.hex2rgba
MODES = ['light', 'dark', 'lightHC', 'darkHC']
IC = ('lightHC', 'darkHC')
acc = {a['name']: a for a in t['accountPalette']}
av = {a['name']: a for a in t['avatarPalette']}
study = t['color']
R = t['themeRules']


def lab(h): return c.rgb2lab(H(h[:7]))
def de(a, b): return c.de2000(lab(a), lab(b))
def de_min(a, b): return min(c.de_all(H(a[:7]), H(b[:7])).values())
def lum(h): return c.luminance(H(h[:7]))
def cr(a, b): return c.contrast(H(a[:7]), H(b[:7]))
def chroma(h):
    L, a, b = lab(h)
    return (a * a + b * b) ** 0.5


def checker(colors):
    def hexof(tok, m):
        if tok.startswith('account:'): return acc[tok[8:]][m]
        if tok.startswith('avatarInk:'): return av[tok[10:]][m]['ink']
        if tok.startswith('avatarFace:'): return av[tok[11:]][m]['face']
        return colors[tok][m]

    def bg(stack, m):
        # an account ink's face over sheet: the rail's (accountFace) or an event's in the day column and the week (eventFace)
        if stack[0].startswith('accountFace:'):
            a = int(round(t['layout']['rail']['faceAlpha'] * 255))
            cur = c.over(H(acc[stack[0][12:]][m] + '%02X' % a), H(colors['sheet'][m]))
        elif stack[0].startswith('eventFace:'):
            a = int(round(t['layout']['calendarPane']['eventTintAlpha'] * 255))
            cur = c.over(H(acc[stack[0][10:]][m] + '%02X' % a), H(colors['sheet'][m]))
        else:
            cur = H(hexof(stack[0], m))
        for s in stack[1:]: cur = c.over(H(hexof(s, m)), cur)
        return cur

    def fgval(fg, m, b):
        f = bg(fg, m) if isinstance(fg, list) else H(hexof(fg, m))
        return c.over(f, b) if f[3] < 1 else f
    return hexof, bg, fgval


def pairs(colors, key, label):
    _, bg, fgval = checker(colors)
    n = fails = 0
    for p in t[key]:
        for m in MODES:
            b = bg(p['bg'], m)
            r = c.contrast(fgval(p['fg'], m, b), b)
            need = p.get('needIC', p['need']) if m in IC else p['need']
            n += 1
            if r < need - 1e-9:
                fails += 1; print('FAIL', label, p['use'], m, round(r, 2))
    return n, fails


def account_rules(colors, label, inkless):
    rules = t['accountRules']
    fails = 0
    for m in MODES:
        labs = [c.cvd_lab(H(a[m])) for a in t['accountPalette']]
        six = min(c.de2000(labs[i][k], labs[j][k]) for i, j in itertools.combinations(range(6), 2) for k in c.KINDS)
        ten = min(c.de2000(labs[i]['normal'], labs[j]['normal']) for i, j in itertools.combinations(range(10), 2))
        accn = min(de(a[m], colors['accent'][m]) for a in t['accountPalette'])
        dan = min(de_min(a[m], colors['danger'][m]) for a in t['accountPalette'])
        inf = min(de(a[m], colors['info'][m]) for a in t['accountPalette'])
        st = min(de(a[m], colors['star'][m]) for a in t['accountPalette'])
        # an inkless theme's ink is its text ink, read as under Graphite: the inks keep the palette's own floor from it
        acc_floor = R['inklessAccentVsAccountMinDE00'] if inkless else rules['minFromAccentNormal']
        ok = six >= rules['firstSixMinCVD'] and ten >= rules['allTenMinNormal'] and accn >= acc_floor and dan >= rules['minFromDangerAnyVision'] and inf >= rules['minFromInfoNormal'] and st >= rules['minFromStarNormal']
        if not ok:
            fails += 1
        print('%-8s %-8s six %.1f ten %.1f accent %.1f danger(any) %.1f info %.1f star %.1f %s' % (label, m, six, ten, accn, dan, inf, st, 'ok' if ok else 'FAIL'))
    return fails


def theme_rules(th):
    """R0-R11 from the file's own values and constants (themeRules), measured against Study's `color`."""
    T = th['color']
    inkless = th['inkless']
    out = []
    def need(cond, msg):
        if not cond: out.append(msg)
    need(set(T) == set(study) and all(set(T[k]) >= set(MODES) for k in T), 'R0 incomplete')
    faces = {a['name']: {m: a[m]['face'] for m in MODES} for a in t['avatarPalette']}
    white_de = R['sheetWhiteMaxDE00'] + 1e-9
    for m in MODES:
        g = lambda k: T[k][m]
        light = m in ('light', 'lightHC')
        page = de(g('sheet'), '#FFFFFF') <= white_de and chroma(g('sheet')) <= R['sheetMaxChroma']
        need(th['sheetIsPage'][m] == page, '%s sheetIsPage' % m)
        need(page == light, '%s sheetIsPage is not "not dark"' % m)
        if light:
            need(g('raised').upper() == '#FFFFFF', 'R1 %s raised' % m)
            need(cr(g('focus'), '#FFFFFF') >= R['focusOnPageMinContrast'], 'R2 %s focus on page' % m)
        need(g('originalPage').upper() == '#FFFFFF', 'R1 %s originalPage' % m)
        need(th['focusOnPage'][m] == T['focus']['lightHC' if m in IC else 'light'], '%s focusOnPage' % m)
        if not inkless:
            need(de(g('accentFill'), R['accentAsset'][m]) <= R['fillVsAccentAssetMaxDE00'] + 1e-9, 'R3 %s fill vs asset' % m)
        for tok in R['neutralTokens']:
            if tok in th['declaredDeeper'][m] or (inkless and tok in t['graphite']):
                continue
            a, b = lum(g(tok)) + 0.05, lum(study[tok][m]) + 0.05
            need(abs(a - b) / b <= R['neutralLuminanceTolerance'], 'R4 %s %s' % (m, tok))
        if th['declaredDeeper'][m]:
            for tok, ref in R['ratioLock'].items():
                need(cr(g(tok), g(ref)) >= cr(study[tok][m], study[ref][m]) * (1 - R['ratioLockTolerance']) - 1e-9, 'R4b %s %s' % (m, tok))
            if 'ink' in th['declaredDeeper'][m]:
                need(cr(g('ink'), g('findCurrent')) >= R['nightInkMinOnFindCurrent'] - 1e-9, 'R4b %s night ink' % m)
        need(de(g('accent'), g('info')) >= R['accentVsInfoMinDE00'] and de_min(g('accent'), g('info')) >= R['accentVsInfoMinAnyVision'], 'R5 %s info' % m)
        study_floor = min(de_min(study['accent'][m], a[m]) for a in t['accountPalette'])
        need(min(de_min(g('accent'), a[m]) for a in t['accountPalette']) >= min(R['accentVsAccountMinAnyVision'], study_floor) - 1e-9, 'R5 %s accounts' % m)
        need(min(de(g('accent'), g(s)) for s in ('success', 'warning', 'star', 'danger')) >= R['accentVsMeaningMinDE00'], 'R5 %s meanings' % m)
        need(min(de_min(g(i), g(s)) for i in ('ink', 'ink2', 'ink3') for s in ('success', 'warning', 'star', 'danger')) >= R['textVsMeaningMinAnyVision'], 'R6 %s' % m)
        for w in R['bannerWashes']:
            need(min(de(g(w), g('sheet')), de(g(w), g('paper'))) >= R['bannerVsPageMinDE00'] - 1e-9, 'R7 %s %s' % (m, w))
            need(de(g(w), g('canvas')) >= min(R['bannerVsPageMinDE00'], de(study[w][m], study['canvas'][m])) - 1e-9, 'R7 %s %s on canvas' % (m, w))
        if not inkless:
            need(de(g('selWash'), g('selWashIdle')) >= R['selectionKeyVsIdleMinDE00'] - 1e-9, 'R8 %s' % m)
        for n, f in faces.items():
            for s in R['avatarSurfaces']:
                ref = 'selWashIdle' if (inkless and s == 'selWash') else s
                need(de(f[m], g(s)) >= min(R['avatarFaceVsSurfaceMinDE00'], de(f[m], study[ref][m])) - 0.05, 'R9 %s %s on %s' % (m, n, s))
        for flag, ink in (('linkUnderlineAtRest', 'ink'), ('quoteLinkUnderlineAtRest', 'ink2')):
            want = de(g('accent'), g(ink)) < R['linkUnderlineMinDE00'] or de_min(g('accent'), g(ink)) < R['linkUnderlineMinAnyVision']
            need(th[flag][m] == want, 'R10 %s %s' % (m, flag))
        lp = t['linkOnPage'][m]
        d = (min(de(lp, x) for x in R['pageText'][m]), min(de_min(lp, x) for x in R['pageText'][m]))
        s0 = (min(de(study['accent'][m], x) for x in R['pageText'][m]), min(de_min(study['accent'][m], x) for x in R['pageText'][m]))
        need(d[0] >= s0[0] - 1e-9 and d[1] >= s0[1] - 1e-9, 'R11 %s' % m)
        # the Graphite values are the build's substitution resolved against this theme's own table
        _, bg, _ = checker(T)
        for k, v in t['graphite'].items():
            stack = v['value'] if isinstance(v['value'], list) else [v['value']]
            need(c.rgb2hex(bg(stack, m)) == th['graphite'][k][m], 'graphite %s %s' % (m, k))
    return out


fails = 0; n = 0
themes = t['themes']
if not themes or themes[0]['color'] != {k: {m: v[m] for m in MODES} for k, v in study.items()}:
    fails += 1; print('FAIL R0: the default theme is not `color`')
for th in themes:
    k, f = pairs(th['color'], 'contrastPairs', th['name']); n += k; fails += f
    k, f = pairs(th['color'], 'graphiteContrastPairs', th['name'] + ' Graphite'); n += k; fails += f
    fails += account_rules(th['color'], th['name'], th['inkless'])
    for r in theme_rules(th):
        fails += 1; print('FAIL', th['name'], r)
# Paper faces (§5.55): every ground and fill is a paper of the palette, every lift has a shadow, ids are unique, and the
# papers keep their values under Increase Contrast.
papers = {p['name']: p for p in t['paperPalette']}
lifts = len(t['layout']['paperFaces']['shadowY'])
ids = [f['id'] for f in t['paperFaces']]
if len(set(ids)) != len(ids):
    fails += 1; print('FAIL paper face ids are not unique')
for p in t['paperPalette']:
    if p['lightHC'] != p['light'] or p['darkHC'] != p['dark']:
        fails += 1; print('FAIL paper %s changes under Increase Contrast' % p['name'])
for f in t['paperFaces']:
    if f['ground'] not in papers:
        fails += 1; print('FAIL paper face %s: ground %s is not a paper' % (f['id'], f['ground']))
    for l in f['layers']:
        n += 1
        if l['paper'] not in papers or not 0 <= l['lift'] < lifts:
            fails += 1; print('FAIL paper face %s: %s, lift %s' % (f['id'], l['paper'], l['lift']))
print('%d themes, %d checks, %d failures' % (len(themes), n, fails))
sys.exit(1 if fails else 0)
