import colorlib as c, itertools, math, random, json, sys
H = c.hex2rgba
MODES = ['light', 'dark', 'lightHC', 'darkHC']
# Surfaces an account ink must clear (>= 3:1 standard, >= 4.5:1 increased contrast).
BG = {
 'light':   ['#FBFAF6', '#FFFEFB', '#F4F2EC', '#ECE9E1', '#FFFFFF', '#D0E0E5', '#EAE7DF', c.rgb2hex(c.stack('#FBFAF6', '#1D1B180C')), c.rgb2hex(c.stack('#ECE9E1', '#1D1B180C'))],
 'dark':    ['#1C1B18', '#24221F', '#171614', '#121110', '#2C2A26', '#213A41', '#2B2925', c.rgb2hex(c.stack('#1C1B18', '#EDE9E20E')), c.rgb2hex(c.stack('#24221F', '#EDE9E20E'))],
 'lightHC': ['#FDFCFA', '#FFFFFF', '#F1EFE9', '#E4E0D6', '#FFFFFF', '#C2D6DC', '#DCD8CE', c.rgb2hex(c.stack('#FDFCFA', '#1D1B1812'))],
 'darkHC':  ['#121110', '#1C1B19', '#0D0C0B', '#080807', '#252320', '#1A4049', '#302D29', c.rgb2hex(c.stack('#121110', '#FFFFFF17'))],
}
NEED = {'light': 3.15, 'dark': 3.15, 'lightHC': 4.6, 'darkHC': 4.6}
REF = {  # accent, danger, info, star, success, warning per mode
 'light':   {'accent': '#1E5468', 'danger': '#AE2A1F', 'info': '#365693', 'star': '#8F6400'},
 'dark':    {'accent': '#6DB6C9', 'danger': '#FF8B7B', 'info': '#97B0E6', 'star': '#E0B04A', 'accentFill': '#2F7B8E', 'dangerFill': '#C0392B'},
 'lightHC': {'accent': '#123E4D', 'danger': '#8C1C13', 'info': '#24417A', 'star': '#6E4C00'},
 'darkHC':  {'accent': '#93D3E3', 'danger': '#FFADA1', 'info': '#B8CBF2', 'star': '#F0C565', 'accentFill': '#226A7D'},
}
REF['light']['accentFill'] = REF['light']['accent']; REF['lightHC']['accentFill'] = REF['lightHC']['accent']
REF['light']['dangerFill'] = REF['light']['danger']; REF['lightHC']['dangerFill'] = REF['lightHC']['danger']; REF['darkHC']['dangerFill'] = '#C0392B'

def lum_ok(rgb, mode):
    return all(c.contrast(rgb, H(b)) >= NEED[mode] for b in BG[mode])

def solve(h, C, mode, tier):
    """Lightest (light modes) / darkest (dark modes) L that passes, then step tier*8 further for contrast headroom."""
    light = mode.startswith('light')
    rng = [x / 2 for x in range(200, 0, -1)] if light else [x / 2 for x in range(0, 200)]
    for L in rng:
        rgb, ok = c.lch2rgb(L, C, h)
        if not ok:
            continue
        if lum_ok(rgb, mode):
            L2 = L - 7 * tier if light else L + 7 * tier
            rgb2, ok2 = c.lch2rgb(L2, C, h)
            # shrink chroma until in gamut
            CC = C
            while not ok2 and CC > 0:
                CC -= 2
                rgb2, ok2 = c.lch2rgb(L2, CC, h)
            if ok2 and lum_ok(rgb2, mode):
                return rgb2
            return None
    return None

def refs_ok(rgb, mode):
    out = {}
    for k in ('accent', 'accentFill', 'danger', 'dangerFill', 'info', 'star'):
        d = c.de_all(rgb, H(REF[mode][k]))
        out[k] = d
    # accent/focus: >= 15 normal, >= 10 any CVD; danger: >= 12 normal, >= 10 any CVD; info >= 10 normal; star >= 8 normal
    if out['accent']['normal'] < 15 or min(out['accent'].values()) < 10: return False
    if out['accentFill']['normal'] < 12 or min(out['accentFill'].values()) < 8: return False
    for k in ('danger', 'dangerFill'):
        if out[k]['normal'] < 12 or min(out[k].values()) < 10: return False
    if out['info']['normal'] < 10: return False
    if out['star']['normal'] < 8: return False
    return True

cands = []
for h in range(0, 360, 6):
    for C in (14, 24, 34, 44, 56, 68):
        for tier in (0, 1, 2):
            fam = {}
            ok = True
            for m in MODES:
                rgb = solve(h, C, m, tier)
                if rgb is None or not refs_ok(rgb, m):
                    ok = False; break
                fam[m] = rgb
            if ok:
                cands.append({'h': h, 'C': C, 'tier': tier, 'rgb': fam})
print('families', len(cands), file=sys.stderr)
# Precompute CVD labs
for f in cands:
    f['lab'] = {m: c.cvd_lab(f['rgb'][m]) for m in MODES}

def pair_min(f, g, modes=('light', 'dark')):
    best = 1e9
    for m in modes:
        for k in c.KINDS:
            d = c.de2000(f['lab'][m][k], g['lab'][m][k])
            if d < best: best = d
    return best

N = len(cands)
print('computing pair matrix', file=sys.stderr)
PM = [[0.0] * N for _ in range(N)]
PN = [[0.0] * N for _ in range(N)]  # normal-vision min over light/dark
for i in range(N):
    for j in range(i + 1, N):
        d = pair_min(cands[i], cands[j])
        PM[i][j] = PM[j][i] = d
        dn = min(c.de2000(cands[i]['lab'][m]['normal'], cands[j]['lab'][m]['normal']) for m in ('light', 'dark'))
        PN[i][j] = PN[j][i] = dn

def score(seq):
    # lexicographic: min CVD dE for first 2..6, then min normal dE for all 10 and min CVD for 7..10
    s = []
    for k in range(2, 7):
        s.append(min(PM[a][b] for a, b in itertools.combinations(seq[:k], 2)))
    return s

best = None
random.seed(7)
idx = list(range(N))
# beam search on first 6 by maximizing min CVD distance (prefer first pair maximal)
beam = []
pairs = sorted(((PM[i][j], i, j) for i in range(N) for j in range(i + 1, N)), reverse=True)[:60]
beam = [([i, j], d) for d, i, j in pairs]
for k in range(3, 7):
    nb = []
    for seq, _ in beam:
        for x in idx:
            if x in seq: continue
            # avoid same hue family duplicates
            if any(abs(cands[x]['h'] - cands[y]['h']) % 360 < 12 or abs(cands[x]['h'] - cands[y]['h']) % 360 > 348 for y in seq if cands[x]['C'] > 20 and cands[y]['C'] > 20):
                continue
            m = min(PM[x][y] for y in seq)
            nb.append((seq + [x], min(m, min(PM[a][b] for a, b in itertools.combinations(seq, 2)))))
    nb.sort(key=lambda t: (-t[1], -sum(PN[a][b] for a, b in itertools.combinations(t[0], 2))))
    # dedupe by set
    seen = set(); beam = []
    for s, d in nb:
        key = tuple(sorted(s))
        if key in seen: continue
        seen.add(key); beam.append((s, d))
        if len(beam) >= 80: break
    print('k', k, 'best min', round(beam[0][1], 2), file=sys.stderr)

results = []
for seq, d6 in beam[:20]:
    s = seq[:]
    for k in range(7, 11):
        bx, bv = None, -1
        for x in idx:
            if x in s: continue
            v = min(min(PN[x][y] for y in s), 2.2 * min(PM[x][y] for y in s))
            if v > bv: bv, bx = v, x
        s.append(bx)
    sc = score(s)
    normal_min = min(PN[a][b] for a, b in itertools.combinations(s, 2))
    cvd10 = min(PM[a][b] for a, b in itertools.combinations(s, 2))
    results.append((sc, normal_min, cvd10, s))
results.sort(key=lambda r: (r[0][4], r[1], r[2]), reverse=True)
out = []
for sc, nm, cv, s in results[:5]:
    print([round(x, 1) for x in sc], 'normal10', round(nm, 1), 'cvd10', round(cv, 1))
    print('  ', [(cands[i]['h'], cands[i]['C'], cands[i]['tier'], c.rgb2hex(cands[i]['rgb']['light']), c.rgb2hex(cands[i]['rgb']['dark'])) for i in s])
    out.append([{'h': cands[i]['h'], 'C': cands[i]['C'], 'tier': cands[i]['tier'], **{m: c.rgb2hex(cands[i]['rgb'][m]) for m in MODES}} for i in s])
json.dump(out, open('palette_results.json', 'w'), indent=1)
