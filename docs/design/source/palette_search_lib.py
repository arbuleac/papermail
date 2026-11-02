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

for h in range(0, 360, 6):
