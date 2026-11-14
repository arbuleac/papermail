"""The theme rules R0-R11 (§4.16), asserted for every theme beside the contrast pairs, the Graphite pairs and the
account rules. Study is the reference: a rule holds a theme to Study's own value wherever Study sits under the floor.

check(table, spec, is_default) -> (failures, flags, values). flags is {'links': {mode: bool}, 'quoteLinks': {mode: bool}}
(R10). An inkless theme (Gallery) is read the way the build reads the system Graphite accent: its ink is its text ink by
design, so R3 and R8 do not apply, R5 holds the account inks to the palette's own floor (13) instead of 15, and R9
measures its selected row against Study's selection under Graphite."""
import tokens_def as T
import themes_lib as D
from themes_lib import MODES, Q, ASSET, de, de_min, lch, Y, cr

NEUTRAL_LUM_TOL = 0.03
ACCENT_INFO_MIN, ACCENT_INFO_MIN_CVD = 12.0, 3.0
ACCENT_ACCOUNT_MIN_CVD = 3.0
INKLESS_ACCENT_ACCOUNT_MIN = 13.0
ACCENT_MEANING_MIN = 15.0
TEXT_MEANING_MIN_CVD = 5.0
FOCUS_ON_PAGE_MIN = 3.0
LINK_DE, LINK_CVD = 15.0, 10.0
MEANINGS = ('success', 'warning', 'star', 'danger')

AVF = {a['name']: {m: a[m][0] for m in MODES} for a in T.AVATARS}
STUDY_ACCT_CVD = {m: min(de_min(Q['accent'][m], a[m]) for a in T.ACCOUNTS) for m in MODES}
STUDY_AV = {(n, s, m): de(AVF[n][m], Q[s][m]) for n in AVF for s in D.AV_SURF for m in MODES}
# R11: the text colours a sender's styled page commonly sets (light pages), and the text a dark page gets from the system
PAGE_TEXT = {'light': ('#000000', '#222222', '#333333', '#444444'), 'lightHC': ('#000000', '#222222', '#333333', '#444444'),
             'dark': ('#FFFFFF', '#EEEEEE', '#DDDDDD', '#CCCCCC'), 'darkHC': ('#FFFFFF', '#EEEEEE', '#DDDDDD', '#CCCCCC')}


def link_on_page(m):
    """`--q-linkOnPage`: a link its sender left uncoloured, in a body that is neither Quire-set nor adapted, sits beside
    the sender's text, not the theme's ink, so it keeps Study's accent in every theme (under Graphite: the ink, as today)."""
    return Q['accent'][m]


def focus_on_page(table, m):
    """`--q-focusOnPage`: the original-colours page is white in both appearances, so its focus ring is the theme's light
    focus (Light IC's under Increase Contrast) whatever the mode."""
    return table['focus']['lightHC' if m.endswith('HC') else 'light']


def sheet_is_page(table, m):
    """The sheet is the white page a sender designed for (R1): the reader shows styled mail on it as sent."""
    s = table['sheet'][m]
    return de(s, '#FFFFFF') <= D.SHEET_WHITE_DE and lch(s)[1] <= D.SHEET_CMAX


def page_link_distance(hx, m):
    return (min(de(hx, x) for x in PAGE_TEXT[m]), min(de_min(hx, x) for x in PAGE_TEXT[m]))


STUDY_PAGE_LINK = {m: page_link_distance(Q['accent'][m], m) for m in MODES}


def check(t, spec=None, is_default=False):
    spec = spec or {}
    inkless = bool(spec.get('inkless'))
    deep = spec.get('depth', 1.0) != 1.0
    declared_depth = D.declared(spec)
    fails, vals = [], {}
    flags = {'links': {}, 'quoteLinks': {}}

    def need(cond, msg):
        if not cond:
            fails.append(msg)
    # R0 every token, every mode, a valid hex; the default theme is `color` byte for byte
    for tok in D.ORDER:
        for m in MODES:
            v = t.get(tok, {}).get(m)
            need(isinstance(v, str) and len(v) in (7, 9) and v.startswith('#'), 'R0 missing %s %s' % (tok, m))
    if fails:
        return fails, flags, vals
    if is_default:
        need(all(t[tok][m] == Q[tok][m] for tok in D.ORDER for m in MODES), 'R0 the default theme differs from color')
    for m in MODES:
        g = lambda k: t[k][m]
        v = {}
        # R1 the light sheet is the page; raised and originalPage are white
        if m in ('light', 'lightHC'):
            v['sheetWhite'] = de(g('sheet'), '#FFFFFF')
            v['sheetC'] = lch(g('sheet'))[1]
            need(v['sheetWhite'] <= D.SHEET_WHITE_DE and v['sheetC'] <= D.SHEET_CMAX, 'R1 %s sheet is not the page' % m)
            need(g('raised').upper() == '#FFFFFF', 'R1 %s raised not white' % m)
            # R2 the focus ring on the white original-colours page (the generated --q-focusOnPage)
            v['focusOnPage'] = cr(g('focus'), '#FFFFFF')
            need(v['focusOnPage'] >= FOCUS_ON_PAGE_MIN, 'R2 %s focus on the white page %.2f' % (m, v['focusOnPage']))
        need(g('originalPage').upper() == '#FFFFFF', 'R1 %s originalPage not white' % m)
        # R3 the fill stays near the compiled accent asset, which native chrome reads once at launch
        v['fillAsset'] = de(g('accentFill'), ASSET[m])
        if not inkless:
            need(v['fillAsset'] <= D.ASSET_DE_MAX + 1e-9, 'R3 %s fill %.1f from the asset' % (m, v['fillAsset']))
        # R4 neutral luminance within 3 % of Study, unless the theme declares that token deeper in that mode
        worst = (0, None)
        for tok in D.NEUTRAL:
            if (tok, m) in declared_depth or (inkless and tok in T.GRAPHITE):
                continue  # declared depth; or, in an inkless theme, `knob`, which is accent family under Graphite
            # luminance as contrast reads it (Y + 0.05), so 8-bit rounding of a near-black ink is not a move
            a, b = Y(g(tok)) + 0.05, Y(Q[tok][m]) + 0.05
            d = abs(a - b) / b
            if d > worst[0]:
                worst = (d, tok)
        v['neutralLum'] = worst
        need(worst[0] <= NEUTRAL_LUM_TOL, 'R4 %s %s luminance moved %.1f %%' % (m, worst[1], 100 * worst[0]))
        # R4b declared depth never weakens structure: the ratio-locked tokens keep Study's ratio on their reference
        if deep and m.startswith('dark'):
            lock = []
            for tok, ref in D.RATIO_LOCK.items():
                rt, rs = cr(g(tok), g(ref)), cr(Q[tok][m], Q[ref][m])
                lock.append((rt / rs - 1, tok, ref, rt, rs))
                need(rt >= rs * (1 - D.RATIO_LOCK_TOL) - 1e-9, 'R4b %s %s on %s %.3f < Study %.3f' % (m, tok, ref, rt, rs))
            v['ratioLock'] = min(lock)
        # ...and a declared night ink keeps its floor on findCurrent after 8-bit rounding
        if spec.get('nightText') and m == 'dark':
            v['nightFind'] = cr(g('ink'), g('findCurrent'))
            need(v['nightFind'] >= D.NIGHT_FIND_MIN - 1e-9, 'R4b night ink on findCurrent %.3f' % v['nightFind'])
        # R5 the ink against info and the account inks, every vision
        v['accentInfo'] = de(g('accent'), g('info'))
        v['accentInfoCVD'] = de_min(g('accent'), g('info'))
        need(v['accentInfo'] >= ACCENT_INFO_MIN, 'R5 %s accent vs info %.1f' % (m, v['accentInfo']))
        need(v['accentInfoCVD'] >= ACCENT_INFO_MIN_CVD, 'R5 %s accent vs info under CVD %.1f' % (m, v['accentInfoCVD']))
        v['accentAcctCVD'] = min((de_min(g('accent'), a[m]), a['name']) for a in T.ACCOUNTS)
        need(v['accentAcctCVD'][0] >= min(ACCENT_ACCOUNT_MIN_CVD, STUDY_ACCT_CVD[m]) - 1e-9,
             'R5 %s accent vs %s under CVD %.2f' % (m, v['accentAcctCVD'][1], v['accentAcctCVD'][0]))
        v['accentAcct'] = min((de(g('accent'), a[m]), a['name']) for a in T.ACCOUNTS)
        if inkless:
            # the build's ">= 15 from the ink" is read as under Graphite; an inkless theme keeps the account palette's
            # own floor between inks from its text ink instead
            need(v['accentAcct'][0] >= INKLESS_ACCENT_ACCOUNT_MIN, 'R5 %s inkless ink vs %s %.1f' % (m, v['accentAcct'][1], v['accentAcct'][0]))
        v['accentMeaning'] = min((de(g('accent'), g(s)), s) for s in MEANINGS)
        need(v['accentMeaning'][0] >= ACCENT_MEANING_MIN, 'R5 %s accent vs %s %.1f' % (m, v['accentMeaning'][1], v['accentMeaning'][0]))
        # R6 text inks against success, warning, star and danger, every vision: a meaning never reads as text
        v['textMeaningCVD'] = min((de_min(g(i), g(s)), i, s) for i in ('ink', 'ink2', 'ink3') for s in MEANINGS)
        need(v['textMeaningCVD'][0] >= TEXT_MEANING_MIN_CVD, 'R6 %s %s vs %s %.1f' % ((m,) + v['textMeaningCVD'][1:] + v['textMeaningCVD'][:1]))
        # R7 banners stay banners on the theme's page and on the desk, where Settings draws its banners
        bp = []
        for w in D.BANNER_WASHES:
            for s in ('sheet', 'paper', 'canvas'):
                floor = D.BANNER_PAGE_MIN if s != 'canvas' else min(D.BANNER_PAGE_MIN, de(Q[w][m], Q['canvas'][m]))
                d = de(g(w), g(s))
                bp.append((d - floor, d, w, s, floor))
                need(d >= floor - 1e-9, 'R7 %s %s on %s %.2f < %.2f' % (m, w, s, d, floor))
        v['bannerPage'] = min((x[1], x[2]) for x in bp if x[3] != 'canvas')
        v['bannerCanvas'] = min((x[1], x[2], x[4]) for x in bp if x[3] == 'canvas')
        # R8 key and not-key selection washes stay apart (an inkless theme tells them apart by the rule, as Graphite does)
        v['selKeyIdle'] = de(g('selWash'), g('selWashIdle'))
        if not inkless:
            need(v['selKeyIdle'] >= D.SEL_KEY_IDLE_MIN - 1e-9, 'R8 %s selWash vs selWashIdle %.1f' % (m, v['selKeyIdle']))
        # R9 no avatar face sinks into a surface it sits on further than it does in Study, nor below 5 where Study is farther
        worst = (99, None)
        for n in AVF:
            for s in D.AV_SURF:
                d = de(AVF[n][m], g(s))
                floor = min(D.AVATAR_MIN, STUDY_AV[(n, s, m)])
                if inkless and s == 'selWash':
                    floor = min(D.AVATAR_MIN, STUDY_AV[(n, 'selWashIdle', m)])
                if d - floor < worst[0]:
                    worst = (d - floor, '%s on %s %.1f (floor %.1f)' % (n, s, d, floor))
        v['avatar'] = worst
        need(worst[0] >= -0.05, 'R9 %s avatar %s' % (m, worst[1]))
        # R10 the link flags: underline at rest wherever colour alone may not tell a link from the text beside it.
        # links: against `ink` (link buttons, invitation links, every link in adapted and Quire-set bodies);
        # quoteLinks: against `ink2` (links inside quoted text in Quire-set bodies)
        v['accentInk'] = de(g('accent'), g('ink'))
        v['accentInkCVD'] = de_min(g('accent'), g('ink'))
        v['accentInk2'] = de(g('accent'), g('ink2'))
        v['accentInk2CVD'] = de_min(g('accent'), g('ink2'))
        flags['links'][m] = v['accentInk'] < LINK_DE or v['accentInkCVD'] < LINK_CVD
        flags['quoteLinks'][m] = v['accentInk2'] < LINK_DE or v['accentInk2CVD'] < LINK_CVD
        # R11 a link the sender left uncoloured on a styled page is never closer to the page's text than Study's is
        lp = link_on_page(m)
        v['linkOnPageDist'] = page_link_distance(lp, m)
        s0 = STUDY_PAGE_LINK[m]
        need(v['linkOnPageDist'][0] >= s0[0] - 1e-9 and v['linkOnPageDist'][1] >= s0[1] - 1e-9, 'R11 %s link on page' % m)
        vals[m] = v
    return fails, flags, vals


# The constants above, as tokens.json carries them (themeRules), for the doc and for verify_tokens.py.
RULES = {
    'sheetWhiteMaxDE00': round(D.SHEET_WHITE_DE, 6), 'sheetMaxChroma': D.SHEET_CMAX,
    'focusOnPageMinContrast': FOCUS_ON_PAGE_MIN,
    'fillVsAccentAssetMaxDE00': D.ASSET_DE_MAX,
    'neutralLuminanceTolerance': NEUTRAL_LUM_TOL,
    'ratioLockTolerance': D.RATIO_LOCK_TOL, 'nightInkMinOnFindCurrent': D.NIGHT_FIND_MIN,
    'accentVsInfoMinDE00': ACCENT_INFO_MIN, 'accentVsInfoMinAnyVision': ACCENT_INFO_MIN_CVD,
    'accentVsAccountMinAnyVision': ACCENT_ACCOUNT_MIN_CVD, 'inklessAccentVsAccountMinDE00': INKLESS_ACCENT_ACCOUNT_MIN,
    'accentVsMeaningMinDE00': ACCENT_MEANING_MIN, 'textVsMeaningMinAnyVision': TEXT_MEANING_MIN_CVD,
    'bannerVsPageMinDE00': D.BANNER_PAGE_MIN, 'selectionKeyVsIdleMinDE00': D.SEL_KEY_IDLE_MIN,
    'avatarFaceVsSurfaceMinDE00': D.AVATAR_MIN,
    'linkUnderlineMinDE00': LINK_DE, 'linkUnderlineMinAnyVision': LINK_CVD,
    'neutralTokens': D.NEUTRAL, 'ratioLock': dict(D.RATIO_LOCK), 'bannerWashes': D.BANNER_WASHES,
    'avatarSurfaces': list(D.AV_SURF), 'pageText': {m: list(v) for m, v in PAGE_TEXT.items()},
}
