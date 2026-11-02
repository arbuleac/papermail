# Quire source

`tokens.json`, `../../DESIGN-LANGUAGE.md` and `specimen.html` are generated from this folder. Edit the sources here, never the generated files.

- `tokens_def.py`: every token value (colours in four modes, type, space, motion, layout).
- `pairs_def.py`: the contrast pairs the build asserts.
- `DESIGN-LANGUAGE.template.md`, `spec_*.html`: the doc and specimen templates.

Rebuild with `sh make.sh` (python3 from the Xcode command line tools, no packages). The build fails if any contrast pair or account-palette rule fails. Re-render the PNGs with:

```
swift scripts/tools/html-snapshot.swift docs/design/specimen.html docs/design/specimen-light.png 1440 light
swift scripts/tools/html-snapshot.swift docs/design/specimen.html docs/design/specimen-dark.png 1440 dark
```
