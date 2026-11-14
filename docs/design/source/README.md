# Quire source

`tokens.json`, `../../DESIGN-LANGUAGE.md` and `specimen.html` are generated from this folder. Edit the sources here, never the generated files.

- `tokens_def.py`: every token value (colours in four modes, type, space, motion, layout).
- `pairs_def.py`: the contrast pairs the build asserts.
- `themes_def.py`: the themes and their seeds; `themes_lib.py` derives each theme's table from Study's; `theme_rules.py` asserts the theme rules R0–R11. The build checks every pair, Graphite pair and account rule in every theme.
- `DESIGN-LANGUAGE.template.md`, `spec_*.html`: the doc and specimen templates.

Rebuild with `sh make.sh` (python3 from the Xcode command line tools, no packages). The build fails if any contrast pair, account-palette rule or theme rule fails in any theme. `python3 verify_tokens.py` re-checks them all from `tokens.json` alone. Re-render the PNGs with:

```
swift scripts/tools/html-snapshot.swift docs/design/specimen.html docs/design/specimen-light.png 1440 light
swift scripts/tools/html-snapshot.swift docs/design/specimen.html docs/design/specimen-dark.png 1440 dark
```
