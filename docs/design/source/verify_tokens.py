"""Independent check: reads only docs/design/tokens.json and recomputes every contrast pair and account rule."""
import json, itertools, sys
import colorlib as c
t = json.load(open('/Users/rboo/Projects/supersparrow-macos/docs/design/tokens.json'))
H = c.hex2rgba
MODES = ['light', 'dark', 'lightHC', 'darkHC']
acc = {a['name']: a for a in t['accountPalette']}
av = {a['name']: a for a in t['avatarPalette']}
def hexof(tok, m):
    if tok.startswith('account:'): return acc[tok[8:]][m]
    if tok.startswith('avatarInk:'): return av[tok[10:]][m]['ink']
    if tok.startswith('avatarFace:'): return av[tok[11:]][m]['face']
    return t['color'][tok][m]
def bg(stack, m):
    if stack[0].startswith('accountFace:'):
        a = int(round(t['layout']['rail']['faceAlpha'] * 255))
        return c.over(H(acc[stack[0][12:]][m] + '%02X' % a), H(t['color']['sheet'][m]))
    cur = H(hexof(stack[0], m))
    for s in stack[1:]: cur = c.over(H(hexof(s, m)), cur)
    return cur
fails = 0; n = 0
for p in t['contrastPairs']:
    for m in MODES:
        b = bg(p['bg'], m); f = H(hexof(p['fg'], m))
        if f[3] < 1: f = c.over(f, b)
        r = c.contrast(f, b); n += 1
        if r < p['need'] - 1e-9:
            fails += 1; print('FAIL', p['use'], m, round(r, 2))
rules = t['accountRules']
for m in MODES:
    labs = [c.cvd_lab(H(a[m])) for a in t['accountPalette']]
    six = min(c.de2000(labs[i][k], labs[j][k]) for i, j in itertools.combinations(range(6), 2) for k in c.KINDS)
    ten = min(c.de2000(labs[i]['normal'], labs[j]['normal']) for i, j in itertools.combinations(range(10), 2))
    accn = min(c.de2000(c.rgb2lab(H(a[m])), c.rgb2lab(H(t['color']['accent'][m]))) for a in t['accountPalette'])
    dan = min(min(c.de_all(H(a[m]), H(t['color']['danger'][m])).values()) for a in t['accountPalette'])
    inf = min(c.de2000(c.rgb2lab(H(a[m])), c.rgb2lab(H(t['color']['info'][m]))) for a in t['accountPalette'])
    st = min(c.de2000(c.rgb2lab(H(a[m])), c.rgb2lab(H(t['color']['star'][m]))) for a in t['accountPalette'])
    ok = six >= rules['firstSixMinCVD'] and ten >= rules['allTenMinNormal'] and accn >= rules['minFromAccentNormal'] and dan >= rules['minFromDangerAnyVision'] and inf >= rules['minFromInfoNormal'] and st >= rules['minFromStarNormal']
    print('%-8s six %.1f ten %.1f accent %.1f danger(any) %.1f info %.1f star %.1f %s' % (m, six, ten, accn, dan, inf, st, 'ok' if ok else 'FAIL'))
    fails += 0 if ok else 1
print('%d checks, %d failures' % (n, fails))
sys.exit(1 if fails else 0)
