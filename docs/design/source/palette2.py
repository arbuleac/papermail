import colorlib as c, itertools, math, json, sys
H = c.hex2rgba
exec(open('palette_search.py').read().split("def lum_ok")[0].split("MODES = ")[0])
MODES = ['light', 'dark', 'lightHC', 'darkHC']
src = open('palette_search.py').read()
exec(src[src.index("BG = {"):src.index("def lum_ok")])

def lum_ok(rgb, mode):
    return all(c.contrast(rgb, H(b)) >= NEED[mode] for b in BG[mode])

def options(h, C, mode, tiers=(0, 1, 2, 3)):
    light = mode.startswith('light')
    rng = [x / 2 for x in range(200, 0, -1)] if light else [x / 2 for x in range(0, 200)]
    base = None
    for L in rng:
        rgb, ok = c.lch2rgb(L, C, h)
        if ok and lum_ok(rgb, mode):
            base = L; break
    if base is None: return []
    out = []
    for t in tiers:
        L2 = base - 7 * t if light else base + 7 * t
        CC = C
        rgb2, ok2 = c.lch2rgb(L2, CC, h)
        while not ok2 and CC > 0:
            CC -= 2
            rgb2, ok2 = c.lch2rgb(L2, CC, h)
        if ok2 and lum_ok(rgb2, mode):
            out.append((t, rgb2))
    return out

def refs(rgb, mode):
    r = REF[mode]
    da = c.de_all(rgb, H(r['accent'])); dd = c.de_all(rgb, H(r['danger']))
    di = c.de2000(c.rgb2lab(rgb), c.rgb2lab(H(r['info']))); ds = c.de2000(c.rgb2lab(rgb), c.rgb2lab(H(r['star'])))
    return da, dd, di, ds

def refs_ok(rgb, mode, strict=True):
    da, dd, di, ds = refs(rgb, mode)
    if da['normal'] < 15 or min(da.values()) < 8: return False
    if min(dd.values()) < 10.5: return False
    if di < 10: return False
    if ds < 8: return False
    return True

if __name__ == '__main__':
    opts = []  # each: dict(h,C,lt,dt,light,dark)
    for h in range(0, 360, 5):
        for C in (10, 20, 30, 40, 50, 62, 75):
            lo = [o for o in options(h, C, 'light') if refs_ok(o[1], 'light')]
            do = [o for o in options(h, C, 'dark') if refs_ok(o[1], 'dark')]
            for (lt, lrgb) in lo:
                for (dt, drgb) in do:
                    opts.append({'h': h, 'C': C, 'lt': lt, 'dt': dt, 'light': lrgb, 'dark': drgb})
    print('options', len(opts), file=sys.stderr)
    for o in opts:
        o['lab'] = {m: c.cvd_lab(o[m]) for m in ('light', 'dark')}
    N = len(opts)
    def pm(i, j):
        a, b = opts[i], opts[j]
        return min(c.de2000(a['lab'][m][k], b['lab'][m][k]) for m in ('light', 'dark') for k in c.KINDS)
    def pn(i, j):
        a, b = opts[i], opts[j]
        return min(c.de2000(a['lab'][m]['normal'], b['lab'][m]['normal']) for m in ('light', 'dark'))
    cache = {}
    def PM(i, j):
        k = (i, j) if i < j else (j, i)
        if k not in cache: cache[k] = pm(i, j)
        return cache[k]
    cacheN = {}
    def PN(i, j):
        k = (i, j) if i < j else (j, i)
        if k not in cacheN: cacheN[k] = pn(i, j)
        return cacheN[k]
    # Seed: best pairs from a subsample, then beam.
    import random
    random.seed(3)
    sample = list(range(N))
    # first pair: maximize CVD min over sampled pairs
    sub = random.sample(sample, min(N, 900))
    pairs = []
    for a, b in itertools.combinations(sub, 2):
        if opts[a]['h'] == opts[b]['h']: continue
        pairs.append((PM(a, b), a, b))
    pairs.sort(reverse=True)
    beam = [([a, b], d) for d, a, b in pairs[:40]]
    print('pair best', round(pairs[0][0], 1), file=sys.stderr)
    def hue_far(x, seq):
        for y in seq:
            dh = abs(opts[x]['h'] - opts[y]['h']) % 360
            dh = min(dh, 360 - dh)
            if dh < 15 and opts[x]['C'] >= 20 and opts[y]['C'] >= 20: return False
            if opts[x]['C'] < 20 and opts[y]['C'] < 20: return False
        return True
    for k in range(3, 11):
        nb = []
        for seq, dmin in beam:
            for x in sample:
                if x in seq or not hue_far(x, seq): continue
                if k <= 6:
                    m = min(PM(x, y) for y in seq)
                    v = min(m, dmin)
                    nb.append((seq + [x], v, sum(PN(x, y) for y in seq)))
                else:
                    m = min(PN(x, y) for y in seq)
                    m2 = min(PM(x, y) for y in seq)
                    v = min(m, 2.0 * m2)
                    nb.append((seq + [x], min(dmin, v) if k == 7 else min(dmin, v), m2))
        nb.sort(key=lambda t: (-t[1], -t[2]))
        seen = set(); beam = []
        for s, d, _ in nb:
            key = tuple(sorted(s))
            if key in seen: continue
            seen.add(key); beam.append((s, d))
            if len(beam) >= (30 if k <= 6 else 12): break
        if k == 6:
            print('first6 best', round(beam[0][1], 2), file=sys.stderr)
            beam = [(s, 1e9) for s, d in beam]  # reset for normal-vision growth
    res = []
    for s, d in beam[:8]:
        prefix = [round(min(PM(a, b) for a, b in itertools.combinations(s[:k], 2)), 1) for k in range(2, 11)]
        prefixN = [round(min(PN(a, b) for a, b in itertools.combinations(s[:k], 2)), 1) for k in range(2, 11)]
        res.append({'cvd_prefix': prefix, 'normal_prefix': prefixN, 'seq': [{'h': opts[i]['h'], 'C': opts[i]['C'], 'lt': opts[i]['lt'], 'dt': opts[i]['dt'], 'light': c.rgb2hex(opts[i]['light']), 'dark': c.rgb2hex(opts[i]['dark'])} for i in s]})
    for r in res[:4]:
        print(r['cvd_prefix'], r['normal_prefix'])
        print('  ', [(x['h'], x['C'], x['light'], x['dark']) for x in r['seq']])
    json.dump(res, open('palette2.json', 'w'), indent=1)
