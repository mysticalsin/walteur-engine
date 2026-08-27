# Typosquatting Package Detection (npm / PyPI)

**Source:** `mukul975/Anthropic-Cybersecurity-Skills` @ 7eebca88 — Apache 2.0
**Upstream skill:** `detecting-typosquatting-packages-in-npm-pypi`
**NIST CSF:** GV.SC-06, DE.CM-04 | **MITRE ATT&CK:** T1195.001, T1554

## Purpose

Detect typosquatting attacks in npm and PyPI package registries — malicious packages named to look like popular legitimate packages (e.g., `lodahs` for `lodash`, `reqeusts` for `requests`). Extends WALTEUR's `guarddog` + `osv-gate` with proactive name-similarity checks before `npm install`.

## How Typosquatting Works

1. Attacker publishes `cross-env2` (popular: `cross-env`)
2. Developer mistyped in `package.json` or CI job
3. Package installs and executes `postinstall` script → steals env vars, SSH keys, npm tokens
4. Attack is silent — build succeeds, no obvious error

Common techniques:
- **Character swap:** `lodahs`, `reqeusts`
- **Adjacent key typo:** `reeact` (r→e), `exprees`
- **Prefix/suffix addition:** `react-native2`, `flask-utils`
- **Dependency confusion:** `@company/internal-package` on public registry (before org scope locked)

## Detection Methods

### 1. Guarddog (WALTEUR existing gate — extends here)

```bash
# guarddog already in WALTEUR — scan before install
guarddog scan --package-manager npm --output-format json > walteur-kit/guarddog-report.json

# Scan a specific package
guarddog scan lodahs --package-manager npm
```

### 2. Pre-install Name Similarity Check

```python
import difflib
import subprocess
import json

KNOWN_SAFE = [
    "react", "lodash", "express", "axios", "moment", "webpack",
    "typescript", "eslint", "jest", "babel", "cross-env",
    "requests", "flask", "django", "numpy", "pandas", "boto3"
]

def check_typosquatting(package_name: str, threshold: float = 0.85) -> list[str]:
    """Return similar safe package names if package_name looks like a typosquat"""
    suspects = []
    for known in KNOWN_SAFE:
        ratio = difflib.SequenceMatcher(None, package_name.lower(), known.lower()).ratio()
        if threshold <= ratio < 1.0:  # Similar but not exact
            suspects.append((known, round(ratio, 2)))
    return sorted(suspects, key=lambda x: -x[1])

# Check all packages in package.json
import json
with open("package.json") as f:
    pkg = json.load(f)

all_deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
for dep_name in all_deps:
    suspects = check_typosquatting(dep_name)
    if suspects:
        print(f"WARNING: '{dep_name}' is similar to known packages: {suspects}")
```

### 3. Package Metadata Red Flags

Check before installing unknown packages:

```bash
# npm — check publish date, download count, maintainers
package_name="${PACKAGE_NAME:-example-package}"
npm info "$package_name" | grep -E "created|modified|maintainers|weekly downloads"

# PyPI — check package metadata
curl -s "https://pypi.org/pypi/${package_name}/json" | \
  python3 -c "import sys,json; d=json.load(sys.stdin)['info']; print(f\"Author: {d['author']}, Release: {d['version']}, Downloads: check pypistats\")"
```

Red flags:
- Published within the last 7 days
- Very low download count (<100/week) for a package with a familiar-sounding name
- Single maintainer, no GitHub repo, no homepage
- `postinstall` script that runs a shell command

### 4. Dependency Confusion Detection

```bash
# Check if internal package names exist on public registry
# (dependency confusion: attacker publishes a package matching your internal name)
INTERNAL_PACKAGES=("@mycompany/auth" "@mycompany/api-client" "internal-utils")
for pkg in "${INTERNAL_PACKAGES[@]}"; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "https://registry.npmjs.org/$pkg")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "WARNING: Internal package '$pkg' exists on public npm registry!"
  fi
done
```

## Prevention Controls

1. **npm:** Use `.npmrc` with `@company:registry=https://your-private-registry` to prevent dependency confusion
2. **Lock files:** Always commit `package-lock.json` / `yarn.lock` / `poetry.lock` — prevents drift
3. **Scope all internal packages:** `@company/...` scoped packages can be locked to private registry
4. **`--ignore-scripts`:** Run `npm install --ignore-scripts` in CI to disable postinstall scripts
5. **Guarddog in CI:** Already gated in WALTEUR — catches most malicious patterns

## WALTEUR Integration

This playbook supplements `osv-gate.sh` (which checks MAL-* advisories after install).
Pre-install check via `guarddog` + name similarity = shift-left on supply chain.

> **Attack path [T1195.001]:** Developer installs `reqeusts` (typo of `requests`) in Python project → malicious `setup.py` postinstall exfiltrates `~/.aws/credentials` to attacker server. WALTEUR guarddog-gate would catch this if the package is indexed in guarddog's rules; name-similarity check catches it before install.
