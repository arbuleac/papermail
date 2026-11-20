import json, re, sys, itertools, os
import colorlib as c
import tokens_def as T
from pairs_def import PAIRS, CUE
H = c.hex2rgba
REPO = os.environ.get('QUIRE_OUT', os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..')))
MODES = ['light', 'dark', 'lightHC', 'darkHC']
MODE_LABEL = {'light': 'Light', 'dark': 'Dark', 'lightHC': 'Light IC', 'darkHC': 'Dark IC'}

# ---------------------------------------------------------------- tokens.json
color = {}
for name, l, d, lh, dh, group, use in T.COLOR:
    color[name] = {'light': l, 'dark': d, 'lightHC': lh, 'darkHC': dh, 'group': group, 'use': use}
typography = {}
for role, fam, size, weight, lh, tr, extra in T.TYPE:
    r = {'family': fam, 'size': size, 'weight': weight, 'lineHeight': lh, 'tracking': tr}
    r.update(extra)
    typography[role] = r
tokens = {
    'name': T.NAME, 'version': T.VERSION,
    'color': color,
    'accountPalette': T.ACCOUNTS,
    'avatarPalette': [{'name': a['name'], **{m: {'face': a[m][0], 'ink': a[m][1]} for m in MODES}} for a in T.AVATARS],
    'typography': typography,
    'space': T.SPACE, 'radius': T.RADIUS, 'border': T.BORDER, 'elevation': T.ELEVATION,
    'motion': T.MOTION, 'layout': T.LAYOUT, 'icon': T.ICON,
    'customGlyphs': T.GLYPHS, 'readerSymbols': T.READER_SYMBOLS,
    'textSize': T.TEXT_SIZE,
    'platform': {'minTextSize': 11, 'graphiteSaturationMax': 0.1, 'readerSymbolPointSize': 20, 'readerSymbolScale': 3, 'readerSymbolCanvas': 1.3, 'avatarTintCount': len(T.AVATARS)},
}
# Text size (§4.15): a row gains one step per line and one above them (compact: one above and one below); Default is layout.
_ts = T.TEXT_SIZE
assert len(_ts['names']) == len(_ts['deltas']) == len(_ts['rowHeights']) == len(_ts['rowCompactHeights'])
assert _ts['rowHeights'] == [T.LAYOUT['row']['height'] + 4 * d for d in _ts['deltas']], 'textSize.rowHeights'
assert _ts['rowCompactHeights'] == [T.LAYOUT['rowCompact']['height'] + 4 * d for d in _ts['deltas']], 'textSize.rowCompactHeights'
# the default window (§3.2, §5.54): the macOS 26 rail, the default list, the narrowest reader that keeps its keycaps and
# the day column, so a new window's reader keeps its keycaps beside the column
assert T.LAYOUT['window']['defaultWidth'] == (T.LAYOUT['rail']['width26'] + T.LAYOUT['list']['defaultWidth'] +
                                              T.LAYOUT['window']['readerKeycapsMin'] + T.LAYOUT['calendarPane']['columnWidth']), 'window.defaultWidth'
assert T.LAYOUT['calendarPane']['readerMinWithColumn'] == T.LAYOUT['window']['readerMinWidth'], 'calendarPane.readerMinWithColumn'
# the swipe's Archive is accentFill by another name (§5.7): only its Graphite value sets it apart
assert all(color['swipeArchive'][m] == color['accentFill'][m] for m in MODES), 'swipeArchive is accentFill by another name'
# Paper faces (§5.55): the art (paper_faces.json, written by paper_faces_gen.py) names its papers; they are tokens
# (T.PAPERS), so the file must name exactly those, in that order, with those values. Increase Contrast keeps the art: its
# IC values are its own.
PAPER_ART = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'paper_faces.json')))
assert list(PAPER_ART['palette']) == [p['name'] for p in T.PAPERS], 'paper_faces.json papers are tokens_def.PAPERS, in order'
assert all(PAPER_ART['palette'][p['name']] == {'light': p['light'], 'dark': p['dark']} for p in T.PAPERS), 'paper values'
assert PAPER_ART['viewBox'] == [0, 0, T.LAYOUT['paperFaces']['artBox'], T.LAYOUT['paperFaces']['artBox']], 'paper art box'
assert PAPER_ART['fillRule'] == 'nonzero', 'the renderer fills paper with the nonzero rule'
_lifts = len(T.LAYOUT['paperFaces']['shadowY'])
assert len(T.LAYOUT['paperFaces']['shadowBlur']) == _lifts and T.LAYOUT['paperFaces']['shadowY'][0] == 0 == T.LAYOUT['paperFaces']['shadowBlur'][0]
assert len({f['id'] for f in PAPER_ART['faces']}) == len(PAPER_ART['faces']), 'paper face ids are unique'
for _f in PAPER_ART['faces']:
    assert re.fullmatch(r'[a-z][a-z0-9-]*', _f['id']), _f['id']
    assert _f['background'] in PAPER_ART['palette'], (_f['id'], _f['background'])
    for _l in _f['layers']:
        assert _l['fill'] in PAPER_ART['palette'], (_f['id'], _l['fill'])
        assert 0 <= _l['lift'] < _lifts, (_f['id'], _l['lift'])
# automatic faces go by ink slot (faces[slot % count]): ten slots, so every slot needs its own face
assert len(PAPER_ART['faces']) >= len(T.ACCOUNTS), 'one paper face per account ink at least'
tokens['paperPalette'] = [{'name': p['name'], 'light': p['light'], 'dark': p['dark'], 'lightHC': p['light'], 'darkHC': p['dark']} for p in T.PAPERS]
tokens['paperFaces'] = [{'id': f['id'], 'name': f['name'], 'ground': f['background'],
                         'layers': [{'d': l['d'], 'paper': l['fill'], 'lift': l['lift']} for l in f['layers']]} for f in PAPER_ART['faces']]
tokens['contrastPairs'] = None  # filled after ALL_PAIRS is built
tokens['cheatSheetContent'] = [{'section': sec, 'rows': [{'keys': k, 'label': l} for k, l in rows]} for sec, rows in T.CHEAT_SHEET]
tokens['cheatSheetSearch'] = {'title': T.CHEAT_SHEET_SEARCH[0], 'terms': T.CHEAT_SHEET_SEARCH[1]}
tokens['accountRules'] = {'standardMinContrast': 3.0, 'icMinContrast': 3.5, 'firstSixMinCVD': 13.0, 'firstSixTargetStandard': 14.0, 'allTenMinNormal': 13.0, 'minFromAccentNormal': 15.0,
                          'minFromDangerAnyVision': 10.0, 'minFromInfoNormal': 10.0, 'minFromStarNormal': 8.0, 'promisedDistinct': 6,
                          'simulation': 'Machado 2009, severity 1.0, linear sRGB; CIEDE2000'}

def get(path):
    cur = tokens
    for part in path.split('.'):
        if isinstance(cur, list):
            cur = cur[int(part)]
        else:
            cur = cur[part]
    return cur

# ---------------------------------------------------------------- colour resolution
ACC = {a['name']: a for a in T.ACCOUNTS}
AV = {a['name']: a for a in T.AVATARS}
def hexof(tok, mode, colors=None):
    """A token's value in `mode`, from `colors` (a theme's table) or Study's `color`."""
    if tok.startswith('account:'):
        return ACC[tok[8:]][mode]
    if tok.startswith('avatarInk:'):
        return AV[tok[10:]][mode][1]
    if tok.startswith('avatarFace:'):
        return AV[tok[11:]][mode][0]
    return (color if colors is None else colors)[tok][mode]
def resolve_stack(stack, mode, colors=None):
    base = stack[0]
    if base.startswith('accountFace:'):
        acct = ACC[base[12:]][mode]
        a = int(round(T.LAYOUT['rail']['faceAlpha'] * 255))
        cur = c.over(H(acct + '%02X' % a), H(hexof('sheet', mode, colors)))
    elif base.startswith('eventFace:'):
        # an event's face in the day column and the week (§5.54): its account's ink at calendarPane.eventTintAlpha over sheet
        acct = ACC[base[10:]][mode]
        a = int(round(T.LAYOUT['calendarPane']['eventTintAlpha'] * 255))
        cur = c.over(H(acct + '%02X' % a), H(hexof('sheet', mode, colors)))
    else:
        cur = H(hexof(base, mode, colors))
    for t in stack[1:]:
        cur = c.over(H(hexof(t, mode, colors)), cur)
    return cur
def ratio(fg, stack, mode, colors=None):
    bg = resolve_stack(stack, mode, colors)
    if isinstance(fg, list):  # a foreground that is itself a stack (a pressed knob face)
        f = resolve_stack(fg, mode, colors)
    else:
        f = H(hexof(fg, mode, colors))
    if f[3] < 1:
        f = c.over(f, bg)
    return c.contrast(f, bg)
IC_MODES = ('lightHC', 'darkHC')
def need_for(p, mode):
    """A pair is (use, fg, stack, need) or (use, fg, stack, need, needIC)."""
    return p[4] if len(p) > 4 and mode in IC_MODES else p[3]

# account and avatar pairs
ALL_PAIRS = list(PAIRS)
for a in T.ACCOUNTS:
    n = a['name']
    for stack, label in ((['paper'], 'list'), (['paper', 'hover'], 'hovered row'), (['selWash'], 'selected row'), (['selWashIdle'], 'idle selection'),
                         (['spine'], 'rail'), (['spine', 'hover'], 'hovered rail tile'), (['sheet'], 'sheet / Settings'), (['canvas'], 'reader desk'),
                         (['raised'], 'raised: popups at rest, and the %g pt raised halo that keeps the dot or swatch off a hovered or pressed popup face' % T.LAYOUT['popup']['inkHalo'])):
        ALL_PAIRS.append(('Account ink %s on %s' % (n, label), 'account:' + n, stack, 3.0, 3.5))
    ALL_PAIRS.append(('Rail monogram on %s face' % n, 'ink', ['accountFace:' + n], 4.5))
    ALL_PAIRS.append(('Rail monogram on %s face, pressed (the press wash stays inside the face)' % n, 'ink', ['accountFace:' + n, 'pressed'], 4.5))
for a in T.AVATARS:
    ALL_PAIRS.append(('Avatar initials, %s' % a['name'], 'avatarInk:' + a['name'], ['avatarFace:' + a['name']], 4.5))
# Day and week (§5.54): an event's face is its account's ink at calendarPane.eventTintAlpha over `sheet`, so each ink has
# its own pairs: the title and the time on the face at rest, the title and time on it hovered and pressed (the time and
# glyphs turn `ink` there, §5), the account edge and a tentative event's dashed outline, the selected conversation's
# margin rule in both key states, the overlap hatch and the failed glyph; then the ink itself on the surfaces only the
# calendar puts it on: a pressed day cell, and the folded strip hovered, pressed or open.
for a in T.ACCOUNTS:
    n = a['name']
    face = 'eventFace:' + n
    ALL_PAIRS += [
        ('Day and week: event title on its %s face' % n, 'ink', [face], 4.5),
        ('Day and week: event time, place and queued glyph on its %s face' % n, 'ink2', [face], 4.5),
        ('Day and week: event title and time on its %s face, hover' % n, 'ink', [face, 'hover'], 4.5),
        ('Day and week: event title and time on its %s face, pressed' % n, 'ink', [face, 'pressed'], 4.5),
        ('Account ink %s on its event face: the edge, a tentative event\'s dashed outline' % n, 'account:' + n, [face], 3.0, 3.5),
        ('Day and week: the selected conversation\'s margin rule on a %s face' % n, 'selRule', [face], 3.0),
        ('Day and week: the selected conversation\'s margin rule on a %s face, window not key' % n, 'selRuleIdle', [face], 3.0),
        ('Day and week: the overlap hatch on a %s face' % n, 'warning', [face], 3.0),
        ('Day and week: the failed glyph on a %s face' % n, 'danger', [face], 3.0),
        ('Account ink %s on a pressed day cell' % n, 'account:' + n, ['paper', 'pressed'], 3.0, 3.5),
        ('Account ink %s on the folded strip, hover' % n, 'account:' + n, ['canvas', 'hover'], 3.0, 3.5),
        ('Account ink %s on the folded strip, pressed or open' % n, 'account:' + n, ['canvas', 'pressed'], 3.0, 3.5),
    ]

def pair_json(p):
    o = {'use': p[0], 'fg': p[1], 'bg': p[2], 'need': p[3]}
    if len(p) > 4: o['needIC'] = p[4]
    return o
tokens['contrastPairs'] = [pair_json(p) for p in ALL_PAIRS if p[3] > 0]

# Graphite: regenerate every pair that touches an accent-family token, with the substitutions of T.GRAPHITE
GMAP = {k: v[0] for k, v in T.GRAPHITE.items()}
def g_sub_stack(stack):
    out = []
    for t in stack:
        r = GMAP.get(t, t)
        out.extend(r if isinstance(r, list) else [r])
    return out
def g_sub_fg(fg):
    if isinstance(fg, list):
        return g_sub_stack(fg)
    return GMAP.get(fg, fg)
def touches(fg, stack):
    toks = (fg if isinstance(fg, list) else [fg]) + list(stack)
    return any(t in GMAP for t in toks)
GRAPHITE_PAIRS = []
for p in ALL_PAIRS:
    # the 1.25 scan cues are not regenerated: under Graphite the selection wash is the idle wash and the ink rule is the cue
    if p[3] == CUE or not touches(p[1], p[2]):
        continue
    GRAPHITE_PAIRS.append(('Graphite · ' + p[0], g_sub_fg(p[1]), g_sub_stack(p[2])) + tuple(p[3:]))
tokens['graphite'] = {k: {'value': v[0], 'use': v[1]} for k, v in T.GRAPHITE.items()}
tokens['graphiteContrastPairs'] = [pair_json(p) for p in GRAPHITE_PAIRS]

def run(pairs, colors=None):
    res, bad = [], []
    for p in pairs:
        use, fg, stack, need = p[:4]
        vals = {m: ratio(fg, stack, m, colors) for m in MODES}
        ok = all(v >= need_for(p, m) - 1e-9 for m, v in vals.items())
        res.append((use, fg, stack, need, vals, ok, p[4] if len(p) > 4 else None))
        if not ok:
            bad.append((use, fg, stack, need, {m: round(v, 2) for m, v in vals.items()}))
    return res, bad
results, fails = run(ALL_PAIRS)
g_results, g_fails = run(GRAPHITE_PAIRS)
fails += g_fails

# ---------------------------------------------------------------- account palette analysis
from palette2 import BG as PAL_BG
def acct_analysis(colors=None):
    colors = color if colors is None else colors
    out = {}
    for m in MODES:
        labs = [c.cvd_lab(H(a[m])) for a in T.ACCOUNTS]
        prefix = []
        worst = []
        prefixN = []
        per_kind = {k: [] for k in c.KINDS}
        for k in range(2, 11):
            best = (1e9, None)
            bn = 1e9
            kinds = {kk: 1e9 for kk in c.KINDS}
            for i, j in itertools.combinations(range(k), 2):
                for kind in c.KINDS:
                    d = c.de2000(labs[i][kind], labs[j][kind])
                    kinds[kind] = min(kinds[kind], d)
                    if d < best[0]:
                        best = (d, '%s / %s (%s)' % (T.ACCOUNTS[i]['name'], T.ACCOUNTS[j]['name'], kind))
                bn = min(bn, c.de2000(labs[i]['normal'], labs[j]['normal']))
            prefix.append(best[0]); worst.append(best[1]); prefixN.append(bn)
            for kind in c.KINDS:
                per_kind[kind].append(kinds[kind])
        refs = {}
        for key in ('accent', 'danger', 'info', 'star', 'success', 'warning'):
            mins = {kind: (1e9, None) for kind in c.KINDS}
            for a in T.ACCOUNTS:
                d = c.de_all(H(a[m]), H(colors[key][m]))
                for kind in c.KINDS:
                    if d[kind] < mins[kind][0]:
                        mins[kind] = (d[kind], a['name'])
            refs[key] = mins
        out[m] = {'prefix': prefix, 'prefixN': prefixN, 'worst': worst, 'perKind': per_kind, 'refs': refs}
    return out
ACCT = acct_analysis()
# hard rules enforced by the build (mirrors DesignContrastTests)
def account_rule_fails(acct, inkless=False):
    out = []
    for m in MODES:
        a = acct[m]
        if a['prefix'][4] < 13.0: out.append('%s: first six accounts only %.1f dE under CVD' % (m, a['prefix'][4]))
        if a['prefixN'][8] < 13.0: out.append('%s: ten accounts only %.1f dE (normal vision)' % (m, a['prefixN'][8]))
        # an inkless theme's ink is its text ink: the rule is read as under the system Graphite accent, which the
        # account rules never measure; theme rule R5 holds the inks 13 from it instead
        if a['refs']['accent']['normal'][0] < 15 and not inkless: out.append('%s: account vs accent %.1f' % (m, a['refs']['accent']['normal'][0]))
        if min(v[0] for v in a['refs']['danger'].values()) < 10: out.append('%s: account vs danger under CVD %.1f' % (m, min(v[0] for v in a['refs']['danger'].values())))
        if a['refs']['info']['normal'][0] < 10: out.append('%s: account vs info %.1f' % (m, a['refs']['info']['normal'][0]))
        if a['refs']['star']['normal'][0] < 8: out.append('%s: account vs star %.1f' % (m, a['refs']['star']['normal'][0]))
    return out
rule_fail = account_rule_fails(ACCT)

# every radius metric in layout is a scale value, except the listed exceptions
SCALE = set(v for k, v in T.RADIUS.items() if k != 'pill')
def _radii(prefix, v):
    if isinstance(v, dict):
        for kk, vv in v.items():
            yield from _radii(prefix + [kk], vv)
    elif 'adius' in prefix[-1] and isinstance(v, (int, float)):
        yield '.'.join(prefix), v
for path, v in _radii([], T.LAYOUT):
    if path in T.RADIUS_EXCEPTIONS:
        continue
    if v not in SCALE and not path.endswith('pill'):
        rule_fail.append('radius off scale: layout.%s = %g' % (path, v))

# ---------------------------------------------------------------- themes (§4.16)
# Every theme is checked as Study is: the same pairs, the same Graphite pairs and the same account rules against its own
# table, plus the theme rules. A theme that fails anything fails the build, so the values are settled before any Swift.
import themes_def, themes_lib, theme_rules
def graphite_values(colors):
    out = {}
    for k, (v, _) in T.GRAPHITE.items():
        out[k] = {m: c.rgb2hex(resolve_stack(v if isinstance(v, list) else [v], m, colors)) for m in MODES}
    return out
def page_variables(colors, mode, graphite=None):
    """`--q-focusOnPage` and `--q-linkOnPage` in `mode` (§5.14): the original-colours page is white in both appearances,
    so its focus ring is the light (or Light IC) focus; a link its sender left uncoloured keeps Study's accent (R11).
    Under Graphite both are the theme's Graphite values, so Study under Graphite draws what it drew before themes."""
    light = 'lightHC' if mode.endswith('HC') else 'light'
    if graphite is not None:
        return [('focusOnPage', graphite['focus'][light]), ('linkOnPage', graphite['accent'][mode])]
    return [('focusOnPage', theme_rules.focus_on_page(colors, mode)), ('linkOnPage', theme_rules.link_on_page(mode))]
# a swipe's fills (§5.7): a pair's floor holds one fill beside one row, not the two apart, so Archive is also held to
# stand out from every row it can be uncovered beside more than Read does, in every mode and under Graphite. The neutral
# Archive is the slip by day, so Graphite and Gallery change only the night's fill.
SWIPE_ROWS = (['paper'], ['paper', 'hover'], ['selWash'], ['selWashIdle'])
def swipe_fails(colors):
    out = []
    for m in MODES:
        if not m.startswith('dark') and colors['swipeArchiveNeutral'][m] != colors['slip'][m]:
            out.append('%s: swipeArchiveNeutral is not the slip' % m)
        for graphite in (False, True):
            sub = g_sub_stack if graphite else list
            for row in SWIPE_ROWS:
                archive, read = (ratio(sub([t])[0], sub(row), m, colors) for t in ('swipeArchive', 'swipeRead'))
                if archive <= read:
                    out.append('%s: swipe Archive %.2f is no louder than Read %.2f on %s%s' % (
                        m, archive, read, ' + '.join(row), ' under Graphite' if graphite else ''))
    return out
def _passes(res, m):
    return sum(1 for r in res if r[3] > 0 and r[4][m] >= (r[6] if (r[6] is not None and m in IC_MODES) else r[3]) - 1e-9)
def _tightest(res, m):
    best = None
    for use, fg, stack, need, vals, ok, nic in res:
        if need < 3: continue
        nd = nic if (nic is not None and m in IC_MODES) else need
        if best is None or vals[m] - nd < best[0]:
            best = (vals[m] - nd, use, vals[m])
    return [best[1], round(best[2], 3), round(best[0], 3)]
theme_fail = []
THEME_RESULTS = []
for th in themes_def.THEMES:
    spec = th['spec'] or {}
    inkless = bool(spec.get('inkless'))
    tab = themes_lib.table(th)
    t_res, t_bad = run(ALL_PAIRS, tab)
    t_gres, t_gbad = run(GRAPHITE_PAIRS, tab)
    t_acct = acct_analysis(tab)
    t_rules = account_rule_fails(t_acct, inkless)
    waived = [r for r in account_rule_fails(t_acct) if r not in t_rules]
    t_theme, t_flags, t_vals = theme_rules.check(tab, spec, is_default=th['spec'] is None)
    t_theme += swipe_fails(tab)
    sheet_page = {m: theme_rules.sheet_is_page(tab, m) for m in MODES}
    # the reader offers original colours only in dark appearances, because the light sheet is the page (R1)
    t_theme += ['%s: sheetIsPage is %s' % (m, sheet_page[m]) for m in MODES if sheet_page[m] == m.startswith('dark')]
    for b in t_bad + t_gbad:
        theme_fail.append('%s: %s %s' % (th['name'], b[0], b[4]))
    theme_fail.extend('%s: %s' % (th['name'], r) for r in t_rules + t_theme)
    THEME_RESULTS.append({'theme': th, 'results': t_res, 'graphiteResults': t_gres, 'waived': waived, 'table': tab,
                          'values': t_vals, 'flags': t_flags})
    tokens.setdefault('themes', []).append({
        'id': th['id'], 'name': th['name'], 'caption': th['caption'], 'inkless': inkless,
        'color': {k: {m: tab[k][m] for m in MODES} for k in themes_lib.ORDER},
        'graphite': graphite_values(tab),
        'linkUnderlineAtRest': t_flags['links'],
        'quoteLinkUnderlineAtRest': t_flags['quoteLinks'],
        'focusOnPage': {m: theme_rules.focus_on_page(tab, m) for m in MODES},
        'sheetIsPage': sheet_page,
        'declaredDeeper': {m: [k for k in themes_lib.ORDER if (k, m) in themes_lib.declared(spec)] for m in MODES},
    })
    tokens.setdefault('themeChecks', {})[th['id']] = {m: {
        'pairs': '%d/%d' % (_passes(t_res, m), sum(1 for r in t_res if r[3] > 0)),
        'graphitePairs': '%d/%d' % (_passes(t_gres, m), len(t_gres)),
        'tightestPair': _tightest(t_res, m),
        'tightestGraphitePair': _tightest(t_gres, m),
        'accountRules': 'pass' if not any(w.startswith(m + ':') for w in waived) else
                        'pass; "no account ink within 15 of the ink" read as under Graphite (inkless): %s' % '; '.join(w for w in waived if w.startswith(m + ':')),
        'themeRules': 'pass' if not [r for r in t_theme if r.startswith('R0') or r.split(' ')[1:2] == [m] or r.startswith(m + ':')] else 'FAIL',
    } for m in MODES}
tokens['linkOnPage'] = {m: theme_rules.link_on_page(m) for m in MODES}
tokens['themeRules'] = dict(theme_rules.RULES, accentAsset=themes_lib.ASSET)
tokens['themeChecks'] = tokens.pop('themeChecks')
def themes_summary():
    n = sum(1 for r in results if r[3] > 0)
    k = len(THEME_RESULTS)
    return '%d themes × %d pairs × 4 modes = %s checks, plus %d × %d Graphite pairs × 4 = %s, plus the theme rules, %d failures' % (
        k, n, format(k * n * 4, ','), k, len(g_results), format(k * len(g_results) * 4, ','), len(theme_fail))

# ---------------------------------------------------------------- markdown tables
def md_table(header, rows):
    out = ['| ' + ' | '.join(header) + ' |', '|' + '|'.join('---' for _ in header) + '|']
    for r in rows:
        out.append('| ' + ' | '.join(str(x) for x in r) + ' |')
    return '\n'.join(out)
def fmt_hex(h):
    if len(h) == 9:
        return '`%s` @ %d%%' % (h[:7], round(int(h[7:9], 16) / 255 * 100))
    return '`%s`' % h
def table_colors(group):
    rows = []
    for name, l, d, lh, dh, g, use in T.COLOR:
        if g != group: continue
        rows.append(('`%s`' % name, fmt_hex(l), fmt_hex(d), fmt_hex(lh), fmt_hex(dh), use))
    return md_table(['Token', 'Light', 'Dark', 'Light IC', 'Dark IC', 'Use'], rows)
def table_accounts():
    rows = []
    for i, a in enumerate(T.ACCOUNTS, 1):
        rows.append((i, a['name'], fmt_hex(a['light']), fmt_hex(a['dark']), fmt_hex(a['lightHC']), fmt_hex(a['darkHC'])))
    return md_table(['#', 'Ink', 'Light', 'Dark', 'Light IC', 'Dark IC'], rows)
def table_cvd():
    rows = []
    for m in MODES:
        a = ACCT[m]
        rows.append((MODE_LABEL[m], '%.1f' % a['prefixN'][8], '%.1f' % a['perKind']['protan'][4], '%.1f' % a['perKind']['deutan'][4], '%.1f' % a['perKind']['tritan'][4],
                     '**%.1f**' % a['prefix'][4], a['worst'][4], ' · '.join('%.0f' % x for x in a['prefix']), a['worst'][8]))
    return md_table(['Mode', 'Normal, all 10', 'Protan, first 6', 'Deutan, first 6', 'Tritan, first 6', 'Min CVD, first 6', 'Closest pair in first 6',
                     'Min over all four visions for the first k = 2…10', 'Closest pair in all 10'], rows)
def table_refs():
    rows = []
    for m in MODES:
        r = ACCT[m]['refs']
        def mn(key, kinds):
            v = min((r[key][k] for k in kinds), key=lambda t: t[0])
            return '%.1f (%s)' % v
        rows.append((MODE_LABEL[m], mn('accent', ['normal']), mn('accent', ['protan', 'deutan', 'tritan']), mn('danger', ['normal']), mn('danger', ['protan', 'deutan', 'tritan']),
                     mn('info', ['normal']), mn('star', ['normal'])))
    return md_table(['Mode', 'vs accent, normal (≥ 15)', 'vs accent, any CVD', 'vs danger, normal (≥ 10)', 'vs danger, any CVD (≥ 10)', 'vs info, normal (≥ 10)', 'vs star, normal (≥ 8)'], rows)
def table_avatars():
    rows = []
    for a in T.AVATARS:
        rows.append((a['name'],) + tuple('%s / %s' % (fmt_hex(a[m][0]), fmt_hex(a[m][1])) for m in MODES))
    return md_table(['Tint', 'Light face / ink', 'Dark face / ink', 'Light IC face / ink', 'Dark IC face / ink'], rows)
def table_papers():
    return md_table(['Paper', 'Light', 'Dark'], [('`%s`' % p['name'], fmt_hex(p['light']), fmt_hex(p['dark'])) for p in T.PAPERS])
def table_paper_faces():
    rows = []
    for i, f in enumerate(tokens['paperFaces']):
        slots = ' · '.join(str(k) for k in range(len(T.ACCOUNTS)) if k % len(tokens['paperFaces']) == i) or '—'
        papers = []
        for l in f['layers']:
            if l['paper'] not in papers: papers.append(l['paper'])
        lifts = ' '.join(str(l['lift']) for l in f['layers'])
        rows.append((i + 1, '`%s`' % f['id'], f['name'], '`%s`' % f['ground'], len(f['layers']), lifts, ', '.join('`%s`' % p for p in papers), slots))
    return md_table(['#', 'Id', 'Name (VoiceOver, in the picker)', 'Ground', 'Layers', 'Lifts, bottom first', 'Papers', 'Automatic for ink slot'], rows)
FAMILY = {'sf': 'SF Pro', 'serif': 'New York', 'rounded': 'SF Pro Rounded', 'mono': 'SF Mono'}
def table_type(twins=False, variants=False):
    rows = []
    for role, fam, size, weight, lh, tr, extra in T.TYPE:
        if bool(extra.get('twinOf')) != twins: continue
        if bool(extra.get('variantOf')) != variants: continue
        notes = []
        if extra.get('style'): notes.append(extra['style'])
        if extra.get('case'): notes.append('uppercase')
        if extra.get('numeric'): notes.append('tabular digits')
        if extra.get('unreadWeight'): notes.append('%d when unread' % extra['unreadWeight'])
        if extra.get('twin'): notes.append('twin `%s`' % extra['twin'])
        if extra.get('twinOf'): notes.append('twin of `%s`' % extra['twinOf'])
        if extra.get('variantOf'): notes.append('variant of `%s`' % extra['variantOf'])
        sz = '%g' % size if size else '%g × d (min %d)' % (extra['sizeRatio'], extra['minSize'])
        lhs = '%g' % lh if lh else '1.0 × size'
        rows.append(('`%s`' % role, FAMILY[fam], sz, weight, lhs, '%+.1f' % tr if tr else '0', ', '.join(notes), extra.get('use', '')))
    return md_table(['Role', 'Family', 'Size (pt)', 'Weight', 'Line height (pt)', 'Tracking (pt)', 'Notes', 'Used for'], rows)
def table_space():
    return md_table(['Token'] + list(T.SPACE.keys()), [['pt'] + list(T.SPACE.values())])
def table_radius():
    use = {'xs': 'Tags, account initial tile, keycaps (18 / 16 pt), checkboxes, skeleton bars, the original-colours inset', 'sm': 'Small buttons, large keycaps, attachment type tiles, autocomplete rows, slip actions (toast and undo panel), small icon buttons, composer field-row focus ring',
           'md': 'Regular buttons, fields, search, popups, icon buttons, banners, quoted toggle, strip chips',
           'lg': 'Sheets, stack, attachment chips, toast, quick-reply field, large buttons, Settings groups, autocomplete, link popover', 'xl': 'Undo-send panel, HUD, cheat-sheet overlay',
           'tile': 'Rail tiles (38 pt near-squircle)', 'pill': 'Badges, tokens, avatars, toggles, pips'}
    return md_table(['Token', 'pt', 'Used for'], [('`r.%s`' % k, v if k != 'pill' else 'height / 2', use[k]) for k, v in T.RADIUS.items()])
def shadow_css(lst):
    if not lst: return 'none'
    return ', '.join('%gpx %gpx %gpx %s' % (s['x'], s['y'], s['blur'], fmt_rgba(s['color'])) for s in lst)
def fmt_rgba(h):
    r, g, b, a = H(h)
    return 'rgba(%d,%d,%d,%.2f)' % (round(r * 255), round(g * 255), round(b * 255), a)
def table_elevation():
    rows = []
    for k, v in T.ELEVATION.items():
        appkit = '—' if not v['light'] else 'key layer: opacity %.2f / %.2f, radius %g / %g, offset (0, %g / %g)' % (
            H(v['light'][0]['color'])[3], H(v['dark'][0]['color'])[3], v['light'][0]['blur'] / 2, v['dark'][0]['blur'] / 2, -v['light'][0]['y'], -v['dark'][0]['y'])
        rows.append(('`%s`' % k, '`%s`' % shadow_css(v['light']), '`%s`' % shadow_css(v['dark']), appkit, v['use']))
    return md_table(['Level', 'Light (CSS)', 'Dark (CSS)', 'AppKit', 'Used for'], rows)
def table_motion():
    d = T.MOTION['duration']; cv = T.MOTION['curve']
    rows = [('`dur.%s`' % k, ('%d ms' % v) if not isinstance(v, list) else ' / '.join('%d ms' % x for x in v)) for k, v in d.items()]
    r1 = md_table(['Duration token', 'Value'], rows)
    r2 = md_table(['Curve token', 'cubic-bezier', 'CAMediaTimingFunction'], [('`ease.%s`' % k, 'cubic-bezier(%g, %g, %g, %g)' % tuple(v), '(%g, %g, %g, %g)' % tuple(v)) for k, v in cv.items()])
    return r1 + '\n\n' + r2
def _fmt_tok(t):
    return ' + '.join('`%s`' % x for x in t) if isinstance(t, list) else '`%s`' % t
def table_contrast(res=None):
    rows = []
    for use, fg, stack, need, vals, ok, nic in (results if res is None else res):
        if need == 0: continue
        bg = ' + '.join('`%s`' % s for s in stack)
        nd = '%g' % need if nic is None else '%g (IC %g)' % (need, nic)
        rows.append((use, _fmt_tok(fg), bg, nd, *('%.2f' % vals[m] for m in MODES), 'pass' if ok else '**FAIL**'))
    return md_table(['Pair', 'Foreground', 'Background (composited left to right)', 'Need', 'Light', 'Dark', 'Light IC', 'Dark IC', ''], rows)
def _margins(res, k=6):
    out = []
    for use, fg, stack, need, vals, ok, nic in res:
        if need < 3: continue
        for m, v in vals.items():
            nd = nic if (nic is not None and m in IC_MODES) else need
            out.append((v - nd, use, m, v, nd))
    best = {}
    for t in sorted(out, key=lambda t: t[0]):
        best.setdefault(t[1], t)
    return sorted(best.values(), key=lambda t: t[0])[:k]
def contrast_summary():
    n = sum(1 for r in results if r[3] > 0)
    cue = sum(1 for r in results if r[3] == CUE)
    capsule = sum(1 for r in results if r[1] in ('swipeArchive', 'swipeRead'))
    ng = len(g_results)
    s = '%d pairs × 4 modes = %d checks, plus %d Graphite pairs × 4 = %d, %d failures (%d of the pairs are scan cues with a 1.25 floor; %d hold a swipe\'s fill beside its row, Archive\'s floors above Read\'s, §5.7; account inks need 3.0, or 3.5 in IC; the rest need 4.5 or 3.0). Smallest margins: ' % (
        n, n * 4, ng, ng * 4, len(fails), cue, capsule)
    s += '; '.join('%s %.2f (%s, needs %.1f)' % (u, v, MODE_LABEL[m], nd) for _, u, m, v, nd in _margins(results)) + '.'
    return s
def graphite_summary():
    s = '%d pairs × 4 modes = %d checks, %d failures. Smallest margins: ' % (len(g_results), 4 * len(g_results), len(g_fails))
    s += '; '.join('%s %.2f (%s, needs %.1f)' % (u, v, MODE_LABEL[m], nd) for _, u, m, v, nd in _margins(g_results, 4)) + '.'
    return s
def table_graphite_map():
    rows = []
    accent_group = [n for n, l, dk, lh, dh, g, u in T.COLOR if g == 'accent']
    for k in accent_group:
        if k in T.GRAPHITE:
            v, use = T.GRAPHITE[k]
            rows.append(('`%s`' % k, _fmt_tok(v), use))
        else:
            rows.append(('`%s`' % k, 'unchanged', color[k]['use']))
    for k, (v, use) in T.GRAPHITE.items():
        if k not in accent_group:
            rows.append(('`%s`' % k, _fmt_tok(v), use))
    rows.append(('account inks', 'unchanged', 'Identity, not accent: rings, the kicker dot, the From dot, swatches, the compact square and the initial tile'))
    return md_table(['Token', 'Under Graphite', 'Where it shows'], rows)
def table_icons():
    return md_table(['Action / meaning', 'Symbol'], [(k, '`%s`' % v) for k, v in T.ICON.items()])
def table_layout(comp):
    items = []
    def walk(prefix, v):
        if isinstance(v, dict):
            for kk, vv in v.items():
                walk(prefix + [kk], vv)
        else:
            if isinstance(v, list): v = ' / '.join('%g' % x for x in v)
            elif isinstance(v, float): v = '%g' % v
            items.append(('`%s`' % '.'.join(prefix[1:]), v))
    walk([comp], T.LAYOUT[comp])
    cols = 4
    rows = []
    for i in range(0, len(items), cols):
        chunk = items[i:i + cols]
        chunk += [('', '')] * (cols - len(chunk))
        rows.append([x for pair in chunk for x in pair])
    return '`layout.%s`\n\n' % comp + md_table(['Metric', 'pt'] * cols, rows)

# ---------------------------------------------------------------- themes in the doc (§4.16)
# Every number the doc gives about a theme is computed here from the checked tables, never typed into the template.
THEME_KEY = ['spine', 'canvas', 'paper', 'sheet', 'raised', 'slip', 'ink', 'ink2', 'ink3', 'ruleStrong', 'accent', 'accentFill',
             'accentWash', 'selWash', 'selWashIdle']
THEME_IDENTITY = ['spine', 'canvas', 'paper', 'sheet', 'slip', 'selWash', 'accent']
def _theme(tid):
    for r in THEME_RESULTS:
        if r['theme']['id'] == tid:
            return r
    raise KeyError(tid)
def table_theme_key(tid):
    tab = _theme(tid)['table']
    return md_table(['Token', 'Light', 'Dark', 'Light IC', 'Dark IC'], [('`%s`' % k,) + tuple(fmt_hex(tab[k][m]) for m in MODES) for k in THEME_KEY])
def theme_same(tid):
    """The tokens a theme keeps from Study in all four modes."""
    tab = _theme(tid)['table']
    same = [k for k in themes_lib.ORDER if all(tab[k][m] == color[k][m] for m in MODES)]
    return '(%d): %s' % (len(same), ', '.join('`%s`' % k for k in same))
def table_theme_seeds():
    rows = []
    for r in THEME_RESULTS:
        th, spec, tab = r['theme'], r['theme']['spec'], r['table']
        if spec is None:
            rows.append((th['name'], '— (it is `color`)', '—', '—', 'Iron Gall: ' + ', '.join('%s `%s`' % (MODE_LABEL[m], tab['accent'][m]) for m in MODES)))
            continue
        ramp = 'chroma 0' if not spec.get('nk') else 'hue %g, chroma × %g' % (spec['nh'], spec['nk'])
        floor = '%g' % spec['dfloor'] if spec.get('dfloor') else '—'
        depth = '—'
        if spec.get('depth'):
            depth = '%g × luminance for the surfaces in Dark and Dark IC; the ratio lock' % spec['depth']
            if spec.get('nightText'):
                depth += '; a night ink in Dark'
        if spec.get('inkless'):
            ink = 'none: **inkless** (the accent family is its own Graphite substitution; `selWash` a grey at Study\'s luminance)'
        else:
            parts = []
            for m in MODES:
                y, cc = spec['acc'][m][:2]
                h = spec['acc'][m][2] if len(spec['acc'][m]) > 2 else spec['ah']
                parts.append('%s (Y %g, C %g, h %g) `%s`' % (MODE_LABEL[m], y, cc, h, tab['accent'][m]))
            ink = '; '.join(parts)
        rows.append((th['name'], ramp, floor, depth, ink))
    return md_table(['Theme', 'Paper ramp (LCh hue, chroma factor; inks 0.8 of it)', 'Dark surface chroma floor', 'Declared depth',
                     'The ink per mode (seed → value)'], rows)
def table_theme_checks():
    rows = []
    for r in THEME_RESULTS:
        th = r['theme']
        for m in MODES:
            ck = tokens['themeChecks'][th['id']][m]
            tp, tg = ck['tightestPair'], ck['tightestGraphitePair']
            rows.append((th['name'], MODE_LABEL[m], ck['pairs'].replace('/', ' / '), '%s %.2f (+%.3f)' % (tp[0], tp[1], tp[2]),
                         ck['graphitePairs'].replace('/', ' / '), '%s %.2f (+%.3f)' % (tg[0].replace('Graphite · ', ''), tg[1], tg[2]),
                         'pass' if ck['accountRules'] == 'pass' else 'pass ¹', ck['themeRules']))
    return md_table(['Theme', 'Mode', 'Pairs', 'Tightest pair (ratio, margin)', 'Graphite pairs', 'Tightest Graphite pair', 'Account rules',
                     'Theme rules'], rows)
def table_theme_rules():
    rows = []
    for r in THEME_RESULTS:
        th, v_all = r['theme'], r['values']
        inkless = bool((th['spec'] or {}).get('inkless'))
        na = ' (n/a)' if inkless else ''
        for m in MODES:
            v = v_all[m]
            rows.append((th['name'], MODE_LABEL[m],
                         '%.2f / %.2f' % (v['sheetWhite'], v['sheetC']) if 'sheetWhite' in v else '—',
                         '%.1f' % v['focusOnPage'] if 'focusOnPage' in v else '—',
                         '%.1f%s' % (v['fillAsset'], na), '%.1f %%' % (100 * v['neutralLum'][0]),
                         '%.1f / %.1f' % (v['accentInfo'], v['accentInfoCVD']), '%.1f %s' % v['accentAcctCVD'],
                         '%.1f (%s, %s)' % v['textMeaningCVD'], '%.1f %s' % v['bannerPage'], '%.1f %s' % v['bannerCanvas'][:2],
                         '%.1f%s' % (v['selKeyIdle'], na), '%+.1f' % v['avatar'][0]))
    return md_table(['Theme', 'Mode', 'R1 sheet vs white ΔE / C*', 'R2 focus on the page', 'R3 fill vs asset', 'R4 largest neutral move',
                     'R5 ink vs info, normal / CVD', 'R5 ink vs nearest account, CVD', 'R6 text vs meanings, CVD',
                     'R7 nearest banner to sheet or paper', 'R7 nearest banner to canvas', 'R8 key vs idle wash', 'R9 avatar margin'], rows)
def table_theme_links():
    rows = []
    for r in THEME_RESULTS:
        for m in MODES:
            v, fl = r['values'][m], r['flags']
            rows.append((r['theme']['name'], MODE_LABEL[m], '%.1f / %.1f' % (v['accentInk'], v['accentInkCVD']), '**underline**' if fl['links'][m] else '—',
                         '%.1f / %.1f' % (v['accentInk2'], v['accentInk2CVD']), '**underline**' if fl['quoteLinks'][m] else '—'))
    return md_table(['Theme', 'Mode', 'ink vs `ink`, normal / worst CVD', 'Every link at rest (`ss-links`)', 'ink vs `ink2`, normal / worst CVD',
                     'Links in quotes at rest (`ss-qlinks`)'], rows)
def table_theme_distance(tok=None):
    pairs = list(itertools.combinations(THEME_RESULTS, 2))
    def d(a, b, m):
        keys = [tok] if tok else THEME_IDENTITY
        return sum(themes_lib.de(a['table'][k][m], b['table'][k][m]) for k in keys) / len(keys)
    rows = [(MODE_LABEL[m],) + tuple('%.1f' % d(a, b, m) for a, b in pairs) for m in MODES]
    return md_table(['Mode'] + ['%s–%s' % (a['theme']['name'], b['theme']['name']) for a, b in pairs], rows)
def table_theme_graphite():
    rows = []
    for th in tokens['themes']:
        for k in ('accent', 'onAccent', 'selWash', 'accentFillHover'):
            rows.append((th['name'], '`%s`' % k) + tuple(fmt_hex(th['graphite'][k][m]) for m in MODES))
    return md_table(['Theme', 'Token', 'Light', 'Dark', 'Light IC', 'Dark IC'], rows)
def table_theme_comfort():
    rows = []
    for r in THEME_RESULTS:
        t = r['table']
        for m in ('light', 'dark'):
            ys = lambda k: 100 * themes_lib.Y(t[k][m]) / themes_lib.Y(color[k][m])
            ink, ink2 = themes_lib.cr(t['ink'][m], t['sheet'][m]), themes_lib.cr(t['ink2'][m], t['sheet'][m])
            rows.append((r['theme']['name'], MODE_LABEL[m], '%.0f %%' % ys('sheet'), '%.0f %%' % ys('canvas'), '%.0f %%' % ys('ink'),
                         '%.1f' % ink, '%.1f' % ink2, '%.2f' % (ink / ink2)))
    return md_table(['Theme', 'Mode', 'Sheet luminance vs Study', 'Desk (`canvas`) vs Study', 'Body text luminance vs Study', '`ink` on `sheet`',
                     '`ink2` on `sheet`', 'ink / ink2'], rows)
def table_theme_ratio_lock():
    rows = []
    for r in THEME_RESULTS:
        if not (r['theme']['spec'] or {}).get('depth'):
            continue
        t = r['table']
        for m in ('dark', 'darkHC'):
            for tok, ref in list(themes_lib.RATIO_LOCK.items()) + [('rule', 'paper'), ('rule', 'canvas'), ('accentWash', 'canvas')]:
                rows.append((r['theme']['name'], MODE_LABEL[m], '`%s` on `%s`' % (tok, ref), '%.3f' % themes_lib.cr(color[tok][m], color[ref][m]),
                             '%.3f (%s)' % (themes_lib.cr(t[tok][m], t[ref][m]), fmt_hex(t[tok][m]))))
    return md_table(['Theme', 'Mode', 'Pair', 'Study', 'Theme (ratio-locked)'], rows)
def table_theme_banners():
    rows = []
    for r in THEME_RESULTS:
        t = r['table']
        for w in themes_lib.BANNER_WASHES:
            for m in MODES:
                if t[w][m] != color[w][m]:
                    a, b = themes_lib.lch(color[w][m]), themes_lib.lch(t[w][m])
                    rows.append((r['theme']['name'], '`%s`' % w, MODE_LABEL[m], '%s → %s' % (fmt_hex(color[w][m]), fmt_hex(t[w][m])),
                                 'C %.1f → %.1f, h %.0f → %.0f, L %.1f → %.1f' % (a[1], b[1], a[2], b[2], a[0], b[0])))
    return md_table(['Theme', 'Wash', 'Mode', 'Study → theme', 'LCh'], rows)
def table_theme_list():
    return md_table(['Theme', 'Caption (under the tiles)', 'Inkless'],
                    [('**%s**' % th['name'], '“%s”' % th['caption'], 'yes' if th['inkless'] else '—') for th in tokens['themes']])

# ---------------------------------------------------------------- CSS
def css_name(tok): return '--q-' + tok
def css_block(mode, colors=None):
    colors = color if colors is None else colors
    parts = []
    for name, *vals in T.COLOR:
        parts.append('%s:%s' % (css_name(name), colors[name][mode]))
    for name, value in page_variables(colors, mode):
        parts.append('%s:%s' % (css_name(name), value))
    for i, a in enumerate(T.ACCOUNTS, 1):
        parts.append('--q-acct-%d:%s' % (i, a[mode]))
        parts.append('--q-acct-%s:%s' % (a['name'].lower(), a[mode]))
    for a in T.AVATARS:
        parts.append('--q-av-%s-face:%s' % (a['name'].lower(), a[mode][0]))
        parts.append('--q-av-%s-ink:%s' % (a['name'].lower(), a[mode][1]))
    for k in ('e1', 'e2', 'e3'):
        parts.append('--q-%s:%s' % (k, shadow_css(T.ELEVATION[k]['dark' if 'dark' in mode else 'light'])))
    return ';'.join(parts) + ';'
def css_static():
    p = ['--q-sans:-apple-system,system-ui,sans-serif', '--q-serif:ui-serif,serif', '--q-rounded:ui-rounded,-apple-system,sans-serif', '--q-mono:ui-monospace,monospace']
    famvar = {'sf': 'var(--q-sans)', 'serif': 'var(--q-serif)', 'rounded': 'var(--q-rounded)', 'mono': 'var(--q-mono)'}
    for role, fam, size, weight, lh, tr, extra in T.TYPE:
        if not size: continue
        style = 'italic ' if extra.get('style') == 'italic' else ''
        p.append('--q-font-%s:%s%d %gpx/%gpx %s' % (role, style, weight, size, lh, famvar[fam]))
        p.append('--q-track-%s:%gpx' % (role, tr))
    for k, v in T.SPACE.items(): p.append('--q-%s:%gpx' % (k, v))
    for k, v in T.RADIUS.items(): p.append('--q-r-%s:%gpx' % (k, v))
    for k, v in T.MOTION['duration'].items():
        if not isinstance(v, list): p.append('--q-dur-%s:%dms' % (k, v))
    for k, v in T.MOTION['curve'].items(): p.append('--q-ease-%s:cubic-bezier(%g,%g,%g,%g)' % (k, *v))
    return ':root{' + ';'.join(p) + ';}'
def css_graphite_block(mode):
    parts = []
    for k, (v, _) in T.GRAPHITE.items():
        st = v if isinstance(v, list) else [v]
        parts.append('%s:%s' % (css_name(k), c.rgb2hex(resolve_stack(st, mode))))
    for name, value in page_variables(color, mode, graphite_values(color)):
        parts.append('%s:%s' % (css_name(name), value))
    return ';'.join(parts) + ';'
def css_all(scope_ic_class='html.ss-ic'):
    out = [css_static(),
           ':root{color-scheme:light dark;%s}' % css_block('light'),
           '@media (prefers-color-scheme:dark){:root{%s}}' % css_block('dark'),
           '@media (prefers-contrast:more){:root{%s}}' % css_block('lightHC'),
           '@media (prefers-color-scheme:dark) and (prefers-contrast:more){:root{%s}}' % css_block('darkHC'),
           '%s{%s}' % (scope_ic_class, css_block('lightHC')),
           '@media (prefers-color-scheme:dark){%s{%s}}' % (scope_ic_class, css_block('darkHC')),
           'html.ss-graphite{%s}' % css_graphite_block('light'),
           '@media (prefers-color-scheme:dark){html.ss-graphite{%s}}' % css_graphite_block('dark'),
           '@media (prefers-contrast:more){html.ss-graphite{%s}}' % css_graphite_block('lightHC'),
           '@media (prefers-color-scheme:dark) and (prefers-contrast:more){html.ss-graphite{%s}}' % css_graphite_block('darkHC'),
           'html.ss-ic.ss-graphite{%s}' % css_graphite_block('lightHC'),
           '@media (prefers-color-scheme:dark){html.ss-ic.ss-graphite{%s}}' % css_graphite_block('darkHC')]
    return '\n'.join(out)
def css_ic_scope(sel):
    return '%s{%s}\n@media (prefers-color-scheme:dark){%s{%s}}' % (sel, css_block('lightHC'), sel, css_block('darkHC'))
def css_light_scope(sel):
    return '%s{%s}' % (sel, css_block('light'))
def css_dark_scope(sel):
    return '%s{%s}' % (sel, css_block('dark'))
def css_theme_scopes(prefix):
    """The specimen's Themes band: every theme's Light and Dark variables under `<prefix>-<id>-<light|dark>`, so one page
    shows each theme in both appearances whatever the page's own."""
    return '\n'.join('%s-%s-%s{%s}' % (prefix, r['theme']['id'], m, css_block(m, r['table'])) for r in THEME_RESULTS for m in ('light', 'dark'))
def themes_band():
    """The main-window figure of section A once per theme and appearance, each scoped to that theme's variables."""
    text = open('specimen.template.html').read()
    start, end = '<!-- figure:main-window -->', '<!-- /figure:main-window -->'
    figure = render(text[text.index(start) + len(start):text.index(end)])
    out = []
    for th in tokens['themes']:
        cells = ''.join('<div class="tbcell"><div class="tbk">%s</div><div class="tbwin tb-%s-%s">%s</div></div>' % (
            label, th['id'], m, figure) for m, label in (('light', 'Light'), ('dark', 'Dark')))
        out.append('<div class="tbrow"><div class="tbname"><b>%s</b>%s</div><div class="tbcells">%s</div></div>' % (th['name'], th['caption'], cells))
    return '\n'.join(out)

# ---------------------------------------------------------------- templates
def render(text):
    def rep(mo):
        key = mo.group(1).strip()
        if key.startswith('TABLE:'):
            parts = key.split(':')
            kind = parts[1]
            if kind == 'colors': return table_colors(parts[2])
            if kind == 'accounts': return table_accounts()
            if kind == 'cvd': return table_cvd()
            if kind == 'refs': return table_refs()
            if kind == 'avatars': return table_avatars()
            if kind == 'papers': return table_papers()
            if kind == 'paperFaces': return table_paper_faces()
            if kind == 'type': return table_type(False)
            if kind == 'twins': return table_type(True)
            if kind == 'variants': return table_type(False, True)
            if kind == 'space': return table_space()
            if kind == 'radius': return table_radius()
            if kind == 'elevation': return table_elevation()
            if kind == 'motion': return table_motion()
            if kind == 'contrast': return table_contrast()
            if kind == 'graphite': return table_contrast(g_results)
            if kind == 'graphiteMap': return table_graphite_map()
            if kind == 'themes': return table_theme_list()
            if kind == 'themeKey': return table_theme_key(parts[2])
            if kind == 'themeSeeds': return table_theme_seeds()
            if kind == 'themeChecks': return table_theme_checks()
            if kind == 'themeRules': return table_theme_rules()
            if kind == 'themeLinks': return table_theme_links()
            if kind == 'themeDistance': return table_theme_distance(parts[2] if len(parts) > 2 else None)
            if kind == 'themeGraphite': return table_theme_graphite()
            if kind == 'themeComfort': return table_theme_comfort()
            if kind == 'themeRatioLock': return table_theme_ratio_lock()
            if kind == 'themeBanners': return table_theme_banners()
            if kind == 'cheatSheet':
                rows = []
                for bi in range(0, len(T.CHEAT_SHEET), 3):
                    band = T.CHEAT_SHEET[bi:bi + 3]
                    for col, (sec, items) in enumerate(band, 1):
                        for n, (k, l) in enumerate(items, 1):
                            rows.append((bi // 3 + 1, col, sec, n, '  '.join(x for x in k.split(' ')), l))
                return md_table(['Band', 'Column', 'Section', '#', 'Keycaps', 'Label'], rows)
            if kind == 'cheatSheetSearch':
                title, terms = T.CHEAT_SHEET_SEARCH
                return md_table(['Title', 'Terms, in order'], [(title, ' '.join('`%s`' % t for t in terms))])
            if kind == 'icons': return table_icons()
            if kind == 'layout': return table_layout(parts[2])
            if kind == 'avatarSizes':
                use = {24: 'collapsed stack rows, autocomplete', 30: 'list rows (inside the %d pt ring box)' % T.LAYOUT['row']['avatarBox'],
                       36: 'message header'}
                r = T.LAYOUT['avatar']['monogramRatio']
                sans = typography['monogramSans']
                return md_table(['Diameter', 'Use', 'Initials, New York (0.42 × d, min %d)' % typography['monogram']['minSize'],
                                 'Initials, SF Pro (`monogramSans`, %g × d, min %d)' % (sans['sizeRatio'], sans['minSize'])],
                                [(d, use[d], '%g pt' % max(typography['monogram']['minSize'], round(d * r * 2) / 2),
                                  '%g pt' % max(sans['minSize'], round(d * sans['sizeRatio'] * 2) / 2)) for d in T.LAYOUT['avatar']['sizes']])
            raise KeyError(key)
        if key == 'CONTRAST_SUMMARY': return contrast_summary()
        if key == 'THEMES_SUMMARY': return themes_summary()
        if key.startswith('THEME_SAME:'): return theme_same(key.split(':', 1)[1])
        if key.startswith('CSS_THEME_SCOPES:'): return css_theme_scopes(key.split(':', 1)[1])
        if key == 'THEMES_BAND': return themes_band()
        if key == 'GRAPHITE_SUMMARY': return graphite_summary()
        if key == 'NGPAIRS': return str(len(g_results))
        if key.startswith('PY:'):
            import specimen_parts
            return str(eval(key[3:].strip(), vars(specimen_parts)))
        if key.startswith('PART:'):
            import specimen_parts
            return specimen_parts.PARTS[key[5:].strip()]()
        if key == 'CSS_TOKENS': return css_all()
        if key.startswith('CSS_IC_SCOPE:'): return css_ic_scope(key.split(':', 1)[1])
        if key.startswith('CSS_LIGHT_SCOPE:'): return css_light_scope(key.split(':', 1)[1])
        if key.startswith('CSS_DARK_SCOPE:'): return css_dark_scope(key.split(':', 1)[1])
        if key.startswith('CVD:'):
            _, m, what = key.split(':')
            a = ACCT[m]
            if what == 'six': return '%.1f' % a['prefix'][4]
            if what == 'ten': return '%.1f' % a['prefixN'][8]
            if what == 'tencvd': return '%.1f' % a['prefix'][8]
            if what == 'five': return '%.1f' % a['prefix'][3]
            if what == 'two': return '%.1f' % a['prefix'][0]
        if key == 'NPAIRS': return str(sum(1 for r in results if r[3] > 0))
        if key == 'NCHECKS': return str(4 * sum(1 for r in results if r[3] > 0))
        if key.startswith('GLYPH:'):
            _, name, field = key.split(':')
            v = T.GLYPHS[name][field]
            return '%g' % v if isinstance(v, (int, float)) else str(v)
        if key.startswith('FILLS:'):
            fl = T.GLYPHS[key[6:]]['fills']
            return ', '.join('cx %g cy %g r %g' % tuple(f['circle']) for f in fl)
        if key.startswith('PATH:'):  # svg path list for a glyph
            g = T.GLYPHS[key[5:]]
            return ' '.join(g['paths'])
        v = get(key)
        if isinstance(v, float) and v.is_integer(): v = int(v)
        if isinstance(v, list) and all(isinstance(x, str) for x in v): return ', '.join('`%s`' % x for x in v)
        if isinstance(v, list): return ' / '.join('%g' % x for x in v)
        return str(v)
    return re.sub(r'\{\{([^{}]+)\}\}', rep, text)

if __name__ == '__main__':
    os.makedirs(REPO + '/docs/design', exist_ok=True)
    json.dump(tokens, open(REPO + '/docs/design/tokens.json', 'w'), indent=2)
    print('tokens.json written')
    for f in fails:
        print('FAIL', f)
    for r in rule_fail:
        print('RULE FAIL', r)
    print(contrast_summary())
    for f in theme_fail:
        print('THEME FAIL', f)
    print(themes_summary())
    for m in MODES:
        print(m, 'first6 CVD %.1f normal10 %.1f' % (ACCT[m]['prefix'][4], ACCT[m]['prefixN'][8]))
    if os.path.exists('DESIGN-LANGUAGE.template.md'):
        open(REPO + '/docs/DESIGN-LANGUAGE.md', 'w').write(render(open('DESIGN-LANGUAGE.template.md').read()))
        print('DESIGN-LANGUAGE.md written')
    if os.path.exists('specimen.template.html'):
        open(REPO + '/docs/design/specimen.html', 'w').write(render(open('specimen.template.html').read()))
        print('specimen.html written')
    if fails or rule_fail or theme_fail:
        sys.exit(1)
