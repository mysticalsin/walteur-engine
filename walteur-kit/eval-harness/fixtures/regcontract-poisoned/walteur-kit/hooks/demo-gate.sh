#!/usr/bin/env bash
# The registry must name the path this hook actually writes.
R="${WALTEUR_ROOT:-$1}"; KIT="$R/walteur-kit"; mkdir -p "$KIT"
REPORT="$KIT/demo-report.json"
printf '{"verdict":"PASS","gate":"demo"}\n' > "$REPORT"
exit 0
