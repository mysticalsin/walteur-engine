# walteur-kit/recipes — the recipe contract (portable, runnable, NO goose)

A **recipe** is a build/QA/ops workflow pinned as **data**: params + a prompt + a
structured-output contract + opt-in MCP extensions + a sub-recipe DAG. It is the
declarative, parameterized, RUNNABLE artifact lifted from goose's recipe system —
**the interface, not the runtime.** WALTEUR keeps NO goose. The sole interpreter is
**`walteur.js`** (the §5.7 orchestrator in the canonical kit). Same recipe, different
operator, same flow.

> **Heads-up (runnability):** `walteur.js` lives in the canonical runnable kit
> (`~/walteur/starter`), NOT in this folder. This is a SPEC distribution — recipes here
> are valid, schema-checkable data, but you cannot RUN them from this folder alone.

## Shape (HARD vs PROTOCOL)

- **HARD** — the recipe SHAPE. `recipe.yaml` must validate against
  `walteur-kit/schemas/recipe.schema.json`. A recipe that fails the schema does not run.
- **PROTOCOL** — whether the recipe does the RIGHT thing. The `prompt` / `instructions` /
  `response` contract are LLM-driven judgment. The schema proves the recipe is well-formed,
  never that it is correct. Absence of a field = NOT-FOUND, never proven-absent of intent.

## How params bind

The per-field mechanics (`key` / `type` / `requirement`, `{{ key }}` substitution,
`select`/`file` behavior, `extensions[]`, `sub_recipes[]`) live in the `description`
fields of `walteur-kit/schemas/recipe.schema.json` — read it there, not here. Two things
the schema can't say on its own: `walteur.js` is the actor that does the binding (abort on
missing `required`, prompt on `user_prompt`, inline `file` CONTENT not the path); and a
`response.json_schema` turns the run into a typed function — the final answer validates or
the run fails.

## The one-brain note

graphify is the user's **ONE retrieval brain.** A recipe that needs to read the
surrounding code/corpus wires a **graphify EXTENSION** — it does NOT build a second
knowledge graph or vector index. Standing-infra-in-the-repo is forbidden (anti-bloat);
the operator brings infra only if they opt in.

## Validate

Schema is valid JSON; the example parses as YAML and conforms to the schema:

```bash
# 1. schema is valid JSON
jq -e . walteur-kit/schemas/recipe.schema.json >/dev/null && echo "schema: valid JSON"

# 2. example parses as YAML AND validates against the schema (draft-07)
python3 - <<'PY'
import json, yaml, sys
schema = json.load(open("walteur-kit/schemas/recipe.schema.json"))
doc    = yaml.safe_load(open("walteur-kit/recipes/example.recipe.yaml"))
try:
    import jsonschema
    jsonschema.validate(doc, schema)          # full draft-07 validation
    print("example: valid YAML + conforms to recipe.schema.json")
except ImportError:
    assert doc["version"] and doc["title"] and doc["description"]
    assert doc.get("prompt") or doc.get("instructions")
    print("example: valid YAML (jsonschema absent — ran structural floor only)")
PY
```

`jsonschema` is not in the mandated zero-dep set; absent ⇒ the check falls back to a LOUD
structural floor (and says so), never a silent green.
