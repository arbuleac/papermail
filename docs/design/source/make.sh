#!/bin/sh
cd "$(dirname "$0")"
cat spec_css.html spec_body1.html spec_body2.html spec_body3.html spec_body3b.html spec_body4.html > specimen.template.html
echo '</div></body></html>' >> specimen.template.html
python3 build.py
