"""The five themes (§4.16), in the order Settings shows them: id, name, the caption under the tiles, and the seeds the
derivation (themes_lib.derive) turns into a full colour table. Study has no seeds: its table is `color` itself, so
nobody's app changes until they choose another theme.

Seeds: `nh` and `nk` are the paper ramp's LCh hue and chroma factor (the inks take 0.8 of it), `dfloor` the dark
surfaces' chroma floor, `depth` a declared luminance factor for the dark surfaces, `nightText` a declared night ink.
`acc` gives the ink per mode as (relative luminance Y, LCh chroma C[, LCh hue]); the hue defaults to `ah`. The values
are the quietest that clear the theme rules (theme_rules.py), so they sit near their floors by construction.
`inkless` (Gallery): the accent family is the theme's own Graphite substitution, so it writes in its text ink."""
THEMES = [
    {'id': 'study', 'name': 'Study',
     'caption': 'Warm paper and blue-black ink.',
     'spec': None},
    {'id': 'gallery', 'name': 'Gallery',
     'caption': 'Neutral grey paper and an ink with no colour.',
     'spec': dict(nh=0, nk=0.0, inkless=True)},
    {'id': 'rain', 'name': 'Rain',
     'caption': 'Cool blue-grey paper, for anyone who finds warm paper too yellow.',
     'spec': dict(nh=236, nk=1.3, dfloor=3.0, ah=212,
                  acc={'light': (0.040, 16), 'dark': (0.50, 30), 'lightHC': (0.026, 16, 226), 'darkHC': (0.583, 26)})},
    {'id': 'grove', 'name': 'Grove',
     'caption': 'Sage paper and a deep teal ink.',
     'spec': dict(nh=130, nk=1.5, dfloor=3.0, ah=198,
                  acc={'light': (0.034, 17, 202), 'dark': (0.5934, 26, 200), 'lightHC': (0.020, 14, 212), 'darkHC': (0.5834, 24)})},
    {'id': 'dusk', 'name': 'Dusk',
     'caption': 'Heather paper by day, and a dimmer window at night.',
     'spec': dict(nh=300, nk=1.5, dfloor=3.0, depth=0.7, nightText=True, ah=240,
                  acc={'light': (0.0762, 24), 'dark': (0.52, 32, 246), 'lightHC': (0.039, 18, 236), 'darkHC': (0.7292, 22, 234)})},
]
