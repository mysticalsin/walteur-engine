# 3 WORKED EXAMPLES — PRD acceptance-criterion -> ast-grep pattern -> proof object
# (front-matter `stories[]` block; each AC names an enforceable construct + pins its ast_proof)
#
# EXAMPLE 1 — AUTHZ CHECK (the route handler must call the policy guard)
# PRD-AC: "STORY-7 / AC2: every /admin route handler enforces requireRole('admin') before the body runs"
#   acceptance:
#     - text: "every /admin route enforces requireRole('admin')"
#       construct: authz-check
#       ast_proof:
#         lang: ts
#         glob: 'src/routes/admin/**/*.ts'
#         pattern: "requireRole('admin')"
#   PROOF COMMAND (what intent-trace.sh runs, verified flags):
#     ast-grep run -p "requireRole('admin')" -l ts --globs 'src/routes/admin/**/*.ts' --json=compact
#   -> proof object that lands in audit.json intent_vs_impl[]:
#       { "story":"STORY-7", "ac":"AC2", "construct":"authz-check",
#         "intent":"every /admin route enforces requireRole('admin')",
#         "ast_proof": { "pattern":"requireRole('admin')", "lang":"ts",
#                        "file":"src/routes/admin/users.ts", "line":42, "matched":true,
#                        "match_count":3, "tool":"ast-grep", "proves":"existence" } }
#
# EXAMPLE 2 — FAIL-CLOSED DEFAULT (the switch's default branch must DENY, not allow)
# PRD-AC: "STORY-3 / AC1: authorization decision defaults to deny on an unknown action"
#   This needs a RELATIONAL proof (a `default:` that is INSIDE the authorize switch AND returns DENY),
#   which a flat -p cannot express -> use a YAML rule file (scan -r), verified keys inside/has/all:
#     acceptance:
#       - text: "authorize() default branch returns DENY"
#         construct: fail-closed-default
#         ast_proof:
#           lang: ts
#           glob: 'src/authz/**/*.ts'
#           rule: walteur-kit/ast-rules/fail-closed-default.yml
#   ast-rules/fail-closed-default.yml (VERIFIED syntax — atomic kind + relational inside + composite all):
#     id: fail-closed-default
#     language: typescript
#     rule:
#       all:
#         - kind: switch_default
#         - has: { pattern: "return Decision.DENY", stopBy: end }
#         - inside: { pattern: "function authorize($$$ARGS) { $$$BODY }", stopBy: end }
#   PROOF COMMAND:
#     ast-grep scan -r walteur-kit/ast-rules/fail-closed-default.yml --json=compact
#   -> { "story":"STORY-3","ac":"AC1","construct":"fail-closed-default",
#        "intent":"authorize() default branch returns DENY",
#        "ast_proof":{"rule":"walteur-kit/ast-rules/fail-closed-default.yml","lang":"ts",
#                     "file":"src/authz/engine.ts","line":88,"matched":true,"match_count":1,
#                     "tool":"ast-grep","proves":"existence"} }
#   HONESTY MARKER (must ride with this object): matched:true proves a deny-returning default EXISTS inside
#   authorize(); it does NOT prove authorize() is actually CALLED on the live request path, nor that DENY is
#   reachable. That reachability/semantics check is PROTOCOL — §5.4 Logic-Correctness arm + policy-shadow.
#
# EXAMPLE 3 — INPUT-VALIDATION SINK (the handler validates body before use)
# PRD-AC: "STORY-5 / AC3: POST /payments validates the request body with the Zod schema before processing"
#     acceptance:
#       - text: "payments handler parses body through PaymentSchema before use"
#         construct: input-validation-sink
#         ast_proof:
#           lang: ts
#           glob: 'src/routes/payments/**/*.ts'
#           pattern: "PaymentSchema.parse($BODY)"
#   PROOF COMMAND:
#     ast-grep run -p 'PaymentSchema.parse($BODY)' -l ts --globs 'src/routes/payments/**/*.ts' --json=compact
#   -> { "story":"STORY-5","ac":"AC3","construct":"input-validation-sink",
#        "intent":"payments handler parses body through PaymentSchema before use",
#        "ast_proof":{"pattern":"PaymentSchema.parse($BODY)","lang":"ts",
#                     "file":"src/routes/payments/create.ts","line":17,"matched":true,"match_count":1,
#                     "tool":"ast-grep","proves":"existence",
#                     "metaVars":{"BODY":"req.body"}} }
#   (A 4th class — idempotency-key — pins e.g. pattern: 'Idempotency-Key' or kind: a header-read node.)
