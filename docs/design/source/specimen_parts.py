import json, re, html
import colorlib as c
import tokens_def as T
SYM = json.load(open('symbols.json'))
def sn(name): return re.sub(r'[^a-z0-9]+', '-', name.lower())
def symbol_css():
    out = [':root{' + ';'.join('--sym-%s:url(%s)' % (sn(k), v) for k, v in sorted(SYM.items())) + '}']
    out += ['.s-%s{-webkit-mask-image:var(--sym-%s);mask-image:var(--sym-%s)}' % (sn(k), sn(k), sn(k)) for k in sorted(SYM)]
    return '\n'.join(out)
def s(name, pt=15, cls=''):
    """An SF Symbol rendered through the template-mask pipeline. pt is the symbol point size."""
    return '<i class="sym s-%s %s" style="--pt:%gpx"></i>' % (sn(name), cls, pt)
def g(name, pt=15, cls=''):
    """A custom glyph from the token file as inline SVG."""
    gl = T.GLYPHS[name]
    grid = gl['grid']
    sw = gl['stroke']
    paths = ''.join('<path d="%s"/>' % p for p in gl['paths'])
    fills = ''.join('<circle cx="%g" cy="%g" r="%g"/>' % tuple(f['circle']) for f in gl.get('fills', []))
    if sw:
        body = '<g fill="none" stroke="currentColor" stroke-width="%g" stroke-linecap="round" stroke-linejoin="round">%s</g><g fill="currentColor">%s</g>' % (sw, paths, fills)
    else:
        body = '<g fill="currentColor" fill-rule="%s">%s</g>' % (gl.get('fillRule', 'nonzero'), paths)
    return '<svg class="glyph %s" viewBox="0 0 %d %d" style="width:%gpx;height:%gpx">%s</svg>' % (cls, grid, grid, pt, pt, body)
_icons = [0]
def app_icon(px, appearance='default'):
    """The app icon (spec §5.42) as inline SVG over its 824 body: the ground's gradient, then the brand mark's front and flap,
    each with its gradient top to bottom over its own bounds (as Icon Composer maps a layer's fill), placed as on the 1024
    template. `.appicon` rounds the corners. Tinted is a stand-in for the system's ground with the parts in white at their
    mono opacities."""
    A = T.LAYOUT['appIcon']
    gl = T.GLYPHS[T.ICON['brand']]
    if appearance == 'dark':
        ground, parts = A['groundDark'], ((A['frontDark'], 1), (A['flapDark'], 1))
    elif appearance == 'tinted':
        ground, parts = ('#4A4E57', '#2C2F36'), ((('#FFFFFF', '#FFFFFF'), A['monoFront']), (('#FFFFFF', '#FFFFFF'), A['monoFlap']))
    else:
        ground, parts = A['ground'], ((A['front'], 1), (A['flap'], 1))
    _icons[0] += 1
    gid = 'appicon-%d-' % _icons[0]
    def lg(name, stops):
        return ('<linearGradient id="%s%s" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="%s"/>'
                '<stop offset="1" stop-color="%s"/></linearGradient>') % (gid, name, stops[0], stops[1])
    inset = (A['canvas'] - A['body']) / 2
    scale = A['markSize'] / gl['grid']
    shapes = ''.join('<path d="%s" fill="url(#%s%d)" fill-opacity="%g"/>' % (d, gid, i, o) for i, (d, (_, o)) in enumerate(zip(gl['paths'], parts)))
    defs = lg('g', ground) + ''.join(lg(str(i), stops) for i, (stops, _) in enumerate(parts))
    return ('<span class="appicon" style="--s:%gpx"><svg viewBox="0 0 %g %g" aria-hidden="true"><defs>%s</defs>'
            '<rect width="%g" height="%g" fill="url(#%sg)"/><g transform="translate(%g %g) scale(%g)">%s</g></svg></span>') % (
        px, A['body'], A['body'], defs, A['body'], A['body'], gid, A['markX'] - inset, A['markY'] - inset, scale, shapes)

ACCT_IDX = {'C': 1, 'G': 2, 'F': 3}
FOLDERS = [('tray', 'Inbox  G I'), ('star', 'Starred  G S'), ('paperplane', 'Sent  G T'), ('doc', 'Drafts  G D'), ('trash', 'Trash  G #'),
           ('archivebox', 'All Mail  G A')]
def rail_folders(selected=0, badge=None, later=False):
    """The rail's folder tiles (spec §5.2): Inbox to Trash at the folder pitch, a hairline, All Mail. The selected
    folder is a raised tile with no margin rule; Inbox carries the scope's unread count. With `later` (something in the
    scope is snoozed) the Later tile shows below Inbox and everything below it moves down one pitch."""
    R = T.LAYOUT['rail']
    shift = R['folderPitch'] if later else 0
    out = []
    for i, (sym, tip) in enumerate(FOLDERS):
        top = R['allMailTop'] + shift if i == 5 else R['folderTop'] + i * R['folderPitch'] + (shift if i > 0 else 0)
        b = '<span class="badge">%s</span>' % badge if i == 0 and badge else ''
        out.append('<span class="rt%s" style="top:%dpx" title="%s">%s%s</span>' % (' sel' if i == selected else '', top, tip, s(sym, R['folderGlyph']), b))
        if i == 0 and later:
            out.append('<span class="rt" style="top:%dpx" title="Later  G L">%s</span>' % (R['folderTop'] + R['folderPitch'], s(T.ICON['viewLater'], R['folderGlyph'])))
        if i == 4:
            out.append('<i class="rdiv" style="top:%dpx"></i>' % (R['folderDividerY'] + shift))
    return ''.join(out)
def rail_accounts(height, tiles, unified='sel', unified_badge=None, scroll_end=False, later=False):
    """The account group anchored above Add in a window `height` tall (spec §5.2): All Inboxes, its hairline, then
    `tiles` (each a (classes, inner html, title) triple). Where the group would come closer than groupGap to All Mail
    it stops there and the tiles scroll in their own clip; scroll_end shows the clip scrolled to its end."""
    R = T.LAYOUT['rail']
    tile, pitch, inset = R['tile'], R['accountPitch'], R['stackInset']
    clip_bottom = height - R['addTopFromBottom'] - R['stackBottomGap']
    n = len(tiles)
    natural_first = clip_bottom - inset - tile - (n - 1) * pitch
    all_mail = R['allMailTop'] + (R['folderPitch'] if later else 0)
    unified_top = max(all_mail + tile + R['groupGap'], natural_first - R['accountGap'] - R['dividerGap'] - tile)
    divider = unified_top + tile + R['dividerGap']
    first = divider + R['accountGap']
    clip_top = first - inset
    content = inset + (n - 1) * pitch + tile + inset
    visible = clip_bottom - clip_top
    offset = max(0, content - visible) if scroll_end else 0
    edges = (' edge-top' if offset > 0 else '') + (' edge-bottom' if content - offset > visible + 0.5 else '')
    mr = '<i class="mr%s"></i>' % (' idle' if unified == 'idle' else '') if unified in ('sel', 'idle') else ''
    b = '<span class="badge">%s</span>' % unified_badge if unified_badge else ''
    out = ['<span class="rt%s" style="top:%dpx" title="All Inboxes  ⌘0">%s%s%s</span>' % (' sel' if unified in ('sel', 'idle') else '', unified_top, mr, g('ss.quire', R['unifiedGlyph']), b),
           '<i class="rdiv" style="top:%dpx"></i>' % divider,
           '<div class="rclip%s" style="top:%dpx;height:%dpx">' % (edges, clip_top, visible)]
    for i, (cls, inner, title) in enumerate(tiles):
        out.append('<span class="rt %s" style="top:%dpx" title="%s">%s</span>' % (cls, inset + i * pitch - offset, title, inner))
    out.append('</div>')
    return ''.join(out)
def row(sender, subject, snippet, time, av, initials, acct=None, unread=False, state='', star=False, clip=False, count=0, tag=None,
        pending=False, failed=False, initial_tile=False, cls='', sender_html=None, subject_cls=''):
    st = {'sel': 'sel', 'idle': 'idle', 'hover': 'hov', '': ''}[state]
    ring = 'var(--q-acct-%d)' % ACCT_IDX[acct] if acct else 'transparent'
    tm = ''
    if failed:
        tm += '<span class="rg fail" title="Couldn\'t archive. Restored.">%s</span>' % s('exclamationmark.triangle.fill', 12)
    elif pending:
        tm += '<span class="rg queued" title="Waiting to sync">%s</span>' % g('ss.queued', 12)
    if tag:
        tm += '<span class="tag">%s</span>' % tag
    if initial_tile and acct:
        tm += '<span class="atile" style="--a:%s">%s</span>' % (ring, acct)
    tm += '<span class="t">%s</span>' % time
    cl = ''
    if count >= 2:
        cl += '<span class="cnt">%d</span>' % count
    if clip:
        cl += '<span class="rg clip">%s</span>' % s('paperclip', 12)
    if star:
        cl += '<span class="rg starred">%s</span>' % s('star.fill', 12)
    return ('<div class="row %s %s %s" style="--ring:%s">'
            '<i class="mrule"></i>%s'
            '<span class="av" style="--face:var(--q-av-%s-face);--avink:var(--q-av-%s-ink)">%s</span>'
            '<div class="l1"><span class="snd">%s</span><span class="tm">%s</span></div>'
            '<div class="l2"><span class="sub %s">%s</span><span class="cl">%s</span></div>'
            '<div class="l3">%s</div></div>') % (
        'unread' if unread else '', st, cls, ring, '<i class="pip"></i>' if unread else '', av, av, initials,
        sender_html or html.escape(sender), tm, subject_cls, html.escape(subject), cl, html.escape(snippet))
def row_compact(sender, subject, snippet, time, acct=None, unread=False, state='', star=False, count=0, clip=False, initial_tile=False):
    st = {'sel': 'sel', 'idle': 'idle', 'hover': 'hov', '': ''}[state]
    ring = 'var(--q-acct-%d)' % ACCT_IDX[acct] if acct else 'transparent'
    cl = ''
    if count >= 2: cl += '<span class="cnt">%d</span>' % count
    if clip: cl += '<span class="rg clip">%s</span>' % s('paperclip', 12)
    if star: cl += '<span class="rg starred">%s</span>' % s('star.fill', 12)
    return ('<div class="row compact %s %s" style="--ring:%s"><i class="mrule"></i>%s'
            '<div class="l1"><span class="snd">%s</span><span class="tm">%s<span class="t">%s</span></span></div>'
            '<div class="l2"><span class="sub">%s</span><span class="sn">\u00a0— %s</span><span class="cl">%s</span></div></div>') % (
        'unread' if unread else '', st, ring, '<i class="pip"></i>' if unread else '', html.escape(sender),
        (('<span class="atile" style="--a:%s">%s</span>' % (ring, acct)) if initial_tile else '<i class="asq"></i>') if acct else '', time, html.escape(subject), html.escape(snippet), cl)
def theme_tiles(chosen='study'):
    """Settings › Appearance › Theme (§5.40): the five tiles, each picture the main window drawn in its theme's variables
    (the Themes band's scopes) for the page's appearance; both sets are written and one is shown. The edge is the
    window's `ruleStrong`, not the pictured theme's. The chosen name is `labelStrong` `ink` with the `selRule` bar."""
    import themes_def as TD
    S = T.LAYOUT['settings']
    w, h = S['themeTile']
    inset, pip, line = S['themeTileInset'], S['themeTilePip'], S['themeTileLine']
    list_x, paper = S['themeTileSpine'], S['themeTilePaper']
    list_line_x = list_x + inset / 2 + pip + inset / 2
    list_line_w = list_x + paper - inset / 2 - list_line_x
    sheet_x = list_x + paper + inset
    sheet_w = w - sheet_x - inset
    text_x, text_w = sheet_x + inset, sheet_w - 2 * inset
    first = inset + inset + line / 2
    def bar(colour, x, centre, width):
        return '<i style="left:%gpx;top:%gpx;width:%gpx;background:var(--q-%s)"></i>' % (x, centre - line / 2, width, colour)
    picture = ('<b class="tts" style="width:%gpx"></b><b class="ttl" style="left:%gpx;width:%gpx"></b>' % (list_x, list_x, paper)
               + '<b class="ttpip" style="left:%gpx;top:%gpx;width:%gpx;height:%gpx"></b>' % (list_x + inset / 2, inset, pip, pip)
               + bar('ink3', list_line_x, inset + pip / 2, list_line_w) + bar('ink3', list_line_x, inset + pip / 2 + 2 * pip, list_line_w * 0.75)
               + '<b class="ttsh" style="left:%gpx;top:%gpx;width:%gpx;height:%gpx"></b>' % (sheet_x, inset, sheet_w, h)
               + bar('ink', text_x, first, text_w) + bar('ink', text_x, first + pip, text_w * 0.75) + bar('accent', text_x, first + 3 * pip, text_w * 0.5))
    sets = []
    for mode in ('light', 'dark'):
        tiles = ''.join('<span class="tt"><span class="tte"><span class="ttp tb-%s-%s">%s</span></span><span class="ttn%s">%s</span></span>' % (
            th['id'], mode, picture, ' on' if th['id'] == chosen else '', th['name']) for th in TD.THEMES)
        sets.append('<span class="ttiles %s">%s</span>' % (mode, tiles))
    caption = next(th['caption'] for th in TD.THEMES if th['id'] == chosen)
    return ''.join(sets) + '<span class="ttcap">%s</span>' % html.escape(caption)

def running_head(label):
    return '<div class="rhead"><span>%s</span><i></i></div>' % label

def swatch_table():
    groups = []
    order = ['surface', 'ink', 'line', 'wash', 'accent', 'semantic']
    names = {'surface': 'Surfaces', 'ink': 'Ink', 'line': 'Lines', 'wash': 'Washes (alpha over the surface)', 'accent': 'Iron Gall: accent, selection, focus', 'semantic': 'Marks and semantics'}
    for grp in order:
        rows = []
        for name, l, d, lh, dh, gg, use in T.COLOR:
            if gg != grp: continue
            cells = ''
            for mode, val, base in (('L', l, '#FBFAF6'), ('D', d, '#1C1B18'), ('LIC', lh, '#FDFCFA'), ('DIC', dh, '#121110')):
                cells += '<td><span class="chip" style="--b:%s;--v:%s"></span><code>%s</code></td>' % (base, val, val)
            rows.append('<tr><th><code>%s</code></th>%s<td class="use">%s</td></tr>' % (name, cells, html.escape(use)))
        groups.append('<tbody><tr class="grp"><td colspan="6">%s</td></tr>%s</tbody>' % (names[grp], ''.join(rows)))
    return '<table class="swatches"><thead><tr><th>Token</th><th>Light</th><th>Dark</th><th>Light IC</th><th>Dark IC</th><th>Use</th></tr></thead>%s</table>' % ''.join(groups)

def account_strips():
    out = []
    labels = {'light': 'Light', 'dark': 'Dark', 'lightHC': 'Light IC', 'darkHC': 'Dark IC'}
    bases = {'light': '#FBFAF6', 'dark': '#1C1B18', 'lightHC': '#FDFCFA', 'darkHC': '#121110'}
    for m in ('light', 'dark', 'lightHC', 'darkHC'):
        for kind in c.KINDS:
            cells = ''
            for i, a in enumerate(T.ACCOUNTS, 1):
                hexv = c.rgb2hex(c.simulate(c.hex2rgba(a[m]), kind))
                cells += '<span class="ak%s" style="background:%s" title="%s"></span>' % (' six' if i == 6 else '', hexv, a['name'])
            out.append('<div class="astrip" style="--b:%s"><b>%s</b><em>%s</em>%s</div>' % (bases[m], labels[m] if kind == 'normal' else '', kind, cells))
    names = ''.join('<span>%d %s</span>' % (i, a['name']) for i, a in enumerate(T.ACCOUNTS, 1))
    return '<div class="anames">%s</div>%s' % (names, ''.join(out))

def avatar_tints():
    out = ''
    for a in T.AVATARS:
        n = a['name'].lower()
        out += '<div class="tint"><span class="avx" style="--face:var(--q-av-%s-face);--avink:var(--q-av-%s-ink)">%s</span><b>%s</b></div>' % (n, n, a['name'][:2], a['name'])
    return out

FAM = {'sf': 'var(--q-sans)', 'serif': 'var(--q-serif)', 'rounded': 'var(--q-rounded)', 'mono': 'var(--q-mono)'}
SAMPLE = {'display': 'SuperSparrow', 'headline': 'Contoso rollout: go-live checklist', 'masthead': 'Inbox', 'title': 'Keyboard Shortcuts',
          'reading': 'Tested with three accounts this afternoon, all good.', 'subject': 'Lisbon in March?', 'composeSubject': 'Re: Contoso rollout',
          'aside': 'Nothing left to read.', 'writing': 'Thanks Ben, I will forward it to IT.', 'body': 'Alex Morgan <alex@contoso.test>',
          'sender': 'Priya Raman, Alex Morgan', 'label': 'Show quoted text', 'snippet': 'Booked the flat near Príncipe Real.', 'meta': '23:39 · 240 KB',
          'runningHead': 'Yesterday', 'tag': 'Gmail', 'badge': '128', 'kbd': '⌘↩', 'mono': '1084-ab3f.apps.googleusercontent.com', 'buttonLarge': 'Add Gmail account', 'metaMedium': 'Up to date · 3 accounts', 'metaStrong': '22:10 · Retry', 'senderMedium': 'Ben Carter', 'bodyMedium': 'Archived 3 conversations', 'bodyStrong': 'Ben Carter · Go to…', 'labelStrong': 'All · Reply', 'buttonLargeStrong': 'Send'}
def type_scale():
    out = ''
    for role, fam, size, weight, lh, tr, ex in T.TYPE:
        if not size or ex.get('twinOf'): continue
        style = 'font-style:italic;' if ex.get('style') == 'italic' else ''
        case = 'text-transform:uppercase;' if ex.get('case') else ''
        num = 'font-variant-numeric:tabular-nums;' if ex.get('numeric') else ''
        txt = SAMPLE.get(role, role)
        sz = min(size, 34)
        spec = '%s %g/%g · %d%s' % ({'sf': 'SF Pro', 'serif': 'New York', 'rounded': 'SF Rounded', 'mono': 'SF Mono'}[fam], size, lh, weight, (' · %+gpt' % tr) if tr else '')
        out += '<div class="ts"><code>%s</code><span class="spec">%s</span><span class="smp" style="font:%d %gpx/%gpx %s;letter-spacing:%gpx;%s%s%s">%s</span></div>' % (
            role, spec, weight, sz, lh, FAM[fam], tr, style, case, num, html.escape(txt))
    return out
def icon_grid():
    out = ''
    for k, v in T.ICON.items():
        if v.startswith('ss.'):
            ic = g(v, 18)
        elif v in SYM:
            ic = s(v, 16)
        else:
            continue
        out += '<div class="ig">%s<b>%s</b><code>%s</code></div>' % (ic, k, v)
    return out
def glyph_specimens():
    out = ''
    for k, gl in T.GLYPHS.items():
        out += '<div class="gs"><div class="gsz">%s%s%s</div><code>%s</code><p>%s</p></div>' % (g(k, 12), g(k, 16), g(k, 32), k, html.escape(gl['meaning']))
    return out
def motion_curves():
    out = ''
    for k, (x1, y1, x2, y2) in T.MOTION['curve'].items():
        p = 'M4 76 C%g %g %g %g 76 4' % (4 + 72 * x1, 76 - 72 * y1, 4 + 72 * x2, 76 - 72 * y2)
        out += '<div class="mc"><svg viewBox="0 0 80 80"><rect x="4" y="4" width="72" height="72" fill="none" stroke="var(--studio-rule)"/><path d="%s" fill="none" stroke="var(--q-accent)" stroke-width="2"/></svg><b>ease.%s</b><code>(%g, %g, %g, %g)</code></div>' % (p, k, x1, y1, x2, y2)
    return out
PARTS = {'SYMBOL_CSS': symbol_css, 'SWATCHES': swatch_table, 'ACCOUNT_STRIPS': account_strips, 'AVATAR_TINTS': avatar_tints,
         'TYPE_SCALE': type_scale, 'ICON_GRID': icon_grid, 'GLYPHS': glyph_specimens, 'MOTION_CURVES': motion_curves}

def _caps(keys, lg=True):
    out = []
    for k in keys.split(' '):
        if k in ('then', '…'):
            out.append('<span class="then">%s</span>' % k)
        else:
            out.append('<span class="kbd%s">%s</span>' % (' lg' if lg else '', html.escape(k)))
    return ''.join(out)

def cheat_sheet_band_rows(band):
    """Rows in a cheat-sheet band: its longest section's."""
    n = T.LAYOUT['cheatSheet']['columns']
    return max(len(rows) for _, rows in T.CHEAT_SHEET[band * n:(band + 1) * n])

def cheat_sheet_height():
    """The panel's natural height, as QuireCheatSheetPanel.naturalHeight() adds it up: the padding, the title row and the
    gap under it, every band (section title and its longest section's rows) sectionGap apart, then the search line."""
    L = T.LAYOUT['cheatSheet']
    count = -(-len(T.CHEAT_SHEET) // L['columns'])
    bands = sum(L['sectionTitle'] + cheat_sheet_band_rows(b) * L['row'] for b in range(count)) + (count - 1) * L['sectionGap']
    search = L['sectionGap'] + L['row'] if T.CHEAT_SHEET_SEARCH[1] else 0
    return 2 * L['pad'] + L['titleRow'] + L['headerGap'] + bands + search

def cheat_sheet_window():
    """The window height the cheat sheet fits whole in: its top, the panel, the bottom margin."""
    L = T.LAYOUT['cheatSheet']
    return L['top'] + cheat_sheet_height() + L['minMargin']

def cheat_sheet():
    """The cheat-sheet overlay panel: two bands of three sections (layout.cheatSheet), content from T.CHEAT_SHEET, and the
    search operators' line from T.CHEAT_SHEET_SEARCH."""
    L = T.LAYOUT['cheatSheet']
    sections = T.CHEAT_SHEET
    def sec(title, rows):
        r = ''.join('<div style="display:grid;grid-template-columns:%dpx 1fr;align-items:center;height:%dpx"><span style="display:flex;gap:%dpx;align-items:center">%s</span><span style="font:var(--q-font-snippet);color:var(--q-ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">%s</span></div>'
                    % (L['keyColumn'], L['row'], L['keycapGap'], _caps(k), html.escape(lbl)) for k, lbl in rows)
        return ('<div><div style="height:%dpx;display:flex;align-items:flex-end;font:var(--q-font-runningHead);letter-spacing:var(--q-track-runningHead);text-transform:uppercase;color:var(--q-ink3)">%s</div>%s</div>' % (L['sectionTitle'], title, r))
    bands = []
    n = L['columns']
    for i in range(0, len(sections), n):
        bands.append('<div style="display:grid;grid-template-columns:repeat(%d,%dpx);column-gap:%dpx;align-items:start">%s</div>' % (n, L['columnWidth'], L['columnGap'], ''.join(sec(*x) for x in sections[i:i + n])))
    # The search operators' line: its title in the key column, the terms after it, one row under the bands.
    title, terms = T.CHEAT_SHEET_SEARCH
    bands.append('<div style="display:grid;grid-template-columns:%dpx 1fr;align-items:center;height:%dpx">'
                 '<span style="font:var(--q-font-runningHead);letter-spacing:var(--q-track-runningHead);text-transform:uppercase;color:var(--q-ink3)">%s</span>'
                 '<span style="display:flex;gap:%dpx;font:var(--q-font-snippet);color:var(--q-ink);white-space:nowrap;overflow:hidden">%s</span></div>'
                 % (L['keyColumn'], L['row'], title, L['searchTermGap'], ''.join('<span>%s</span>' % html.escape(t) for t in terms)))
    return ('<div style="position:relative;width:%dpx;padding:%dpx;border-radius:%dpx;background:var(--q-raised);box-shadow:var(--q-e3);color:var(--q-ink)">'
            '<div style="height:%dpx;display:flex;align-items:center;font:var(--q-font-title)">Keyboard Shortcuts</div>'
            '<span class="ib" style="position:absolute;right:%dpx;top:%dpx;width:%dpx;height:%dpx">%s</span>'
            '<div style="margin-top:%dpx;display:grid;row-gap:%dpx">%s</div></div>') % (
        L['width'], L['pad'], L['radius'], L['titleRow'], L['closeInset'], L['closeInset'], L['close'], L['close'], s('xmark', 12),
        L['headerGap'] - 8, L['sectionGap'], ''.join(bands))

def chain(items):
    """A precedence chain: numbered steps separated by arrows."""
    out = []
    for i, t in enumerate(items, 1):
        out.append('<span style="display:inline-flex;align-items:center;gap:6px;height:24px;padding:0 8px;border-radius:6px;background:var(--q-fill);font:var(--q-font-snippet);color:var(--q-ink);white-space:nowrap"><b style="font:var(--q-font-badge);color:var(--q-ink3)">%d</b>%s</span>' % (i, t))
    return '<span style="color:var(--q-ink3);font:var(--q-font-meta)"> › </span>'.join(out)
