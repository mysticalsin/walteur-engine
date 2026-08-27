# WALTEUR Product Standard

> Template. Required for user-facing, commercial, venture-grade, or full-product builds. This does not promise a valuation. It forces the product/company completeness expected when the user asks WALTEUR to build something serious.

Fill the JSON block during DISCOVER or PLAN. Every `planned` item needs a PLAN task ref. Every `out_of_scope` item needs a reason, owner, and review trigger.

```json
{
  "schema_version": 1,
  "product": "<product name>",
  "category": "<market/category/job category>",
  "date": "<YYYY-MM-DD>",
  "ambition": {
    "stage": "commercial_product",
    "target_scale": "<target scale and usage class, e.g. 100000 users or enterprise internal use>",
    "value_thesis": "<why this is worth building, in business terms>",
    "differentiation_thesis": "<the wedge that makes this better or meaningfully different>"
  },
  "evidence": {
    "prd_ref": "walteur-kit/PRD.md",
    "benchmark_ref": "walteur-kit/benchmark.md",
    "plan_ref": "PLAN.md",
    "design_ref": "DESIGN.md"
  },
  "core_value_loop": {
    "pain": "<pain the product removes>",
    "promise": "<specific user promise>",
    "activation_event": "<first moment of value>",
    "habit_loop": "<why the user returns>",
    "retention_mechanism": "<data, workflow, network, habit, switching-cost, or trust loop>",
    "north_star_metric": {
      "name": "<metric>",
      "target": "<number+unit>",
      "check": "<how to verify it>"
    }
  },
  "users": {
    "primary": "<daily user / job>",
    "buyer": "<buyer or economic owner, or internal sponsor>",
    "admin": "<admin/operator role>",
    "support_operator": "<who handles user trouble>"
  },
  "product_surface": [
    { "area": "onboarding", "status": "planned", "ref": "PLAN.md#T1" },
    { "area": "core_workflow", "status": "planned", "ref": "PLAN.md#T2" },
    { "area": "data_model", "status": "planned", "ref": "PLAN.md#T3" },
    { "area": "auth_permissions", "status": "planned", "ref": "PLAN.md#T4" },
    { "area": "settings", "status": "planned", "ref": "PLAN.md#T5" },
    { "area": "empty_loading_error_states", "status": "planned", "ref": "PLAN.md#T6" },
    { "area": "analytics_telemetry", "status": "planned", "ref": "PLAN.md#T7" },
    { "area": "admin_ops", "status": "planned", "ref": "PLAN.md#T8" },
    { "area": "billing_or_value_exchange", "status": "planned", "ref": "PLAN.md#T9" },
    { "area": "support_docs", "status": "planned", "ref": "PLAN.md#T10" },
    { "area": "security_privacy", "status": "planned", "ref": "PLAN.md#T11" },
    { "area": "release_ops", "status": "planned", "ref": "PLAN.md#T12" }
  ],
  "business_model": {
    "value_capture": "<subscription, transaction, usage, services, internal ROI, or funded mandate>",
    "pricing_or_funding": "<pricing/funding hypothesis or internal budget logic>",
    "cost_drivers": "<main infra, support, data, compliance, or acquisition cost drivers>",
    "unit_economics_assumption": "<one concrete assumption to validate>",
    "expansion_path": "<how the product grows beyond the first wedge>"
  },
  "trust_and_ops": {
    "authn_authz": "<identity and permission model>",
    "data_policy": "<classification, retention, export/delete, and privacy stance>",
    "observability": "<logs, metrics, traces, analytics, and alert ownership>",
    "reliability_target": "<number+unit target or signed deferral>",
    "support_model": "<support channel, runbook, escalation owner>",
    "incident_response": "<incident owner and recovery path>"
  },
  "launch_readiness": {
    "first_segment": "<beachhead user/job>",
    "acquisition_or_distribution": "<how the first users get it>",
    "activation_metric": "<number+unit activation target>",
    "feedback_channel": "<where feedback lands>",
    "release_plan": "<private beta, internal rollout, public launch, or client handoff>"
  },
  "out_of_scope": [
    {
      "item": "<capability not in this release>",
      "reason": "<why it is safe to cut>",
      "owner": "<decision owner>",
      "review_trigger": "<when to revisit>"
    }
  ],
  "signoff": {
    "owner": "<owner>",
    "status": "self_signed",
    "date": "<YYYY-MM-DD>"
  }
}
```
