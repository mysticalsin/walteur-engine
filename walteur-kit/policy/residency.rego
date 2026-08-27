# WALTEUR residency policy — OPA / conftest deny rules for data residency & PII safety.
#
# Run:  conftest test <data-inventory.json | resources.json> --policy walteur-kit/policy
#
# Evaluated against EITHER shape:
#   (a) a WALTEUR data-inventory array — each item has data_class ("pii.*"),
#       residency_region, and (optionally) encryption / public / sinks fields; OR
#   (b) a resource manifest — an array (or {resources:[...]}) of objects carrying
#       data_class / region / encryption / public flags.
#
# Three denials (any => conftest exits non-zero => compliance-gate FAIL):
#   1. A PII resource located in a NON-permitted region.
#   2. Encryption turned OFF on a PII store.
#   3. A PUBLIC bucket / store that holds PII.
#
# Permitted regions are the EU/EEA data-residency set. Override per-project by
# editing `permitted_regions` below. Matching is case-insensitive and tolerant of
# both coarse ("EU") and fine ("eu-west-1") region identifiers.

package main

import rego.v1

# ── configuration ─────────────────────────────────────────────────────────────

# Permitted residency regions for PII (lower-cased). Coarse + common EU specifics.
permitted_regions := {
	"eu", "eea",
	"eu-west-1", "eu-west-2", "eu-west-3",
	"eu-central-1", "eu-central-2",
	"eu-north-1", "eu-south-1", "eu-south-2",
	"europe-west1", "europe-west2", "europe-west3", "europe-west4",
	"europe-west8", "europe-west9", "europe-north1", "europe-central2",
	"westeurope", "northeurope", "francecentral", "germanywestcentral",
}

# ── input normalisation ───────────────────────────────────────────────────────
# Yield every resource object regardless of wrapper shape.

resources contains r if {
	is_array(input)
	some r in input
	is_object(r)
}

resources contains r if {
	is_object(input)
	is_array(input.resources)
	some r in input.resources
	is_object(r)
}

# A single bare resource object.
resources contains input if {
	is_object(input)
	not input.resources
	holds_pii(input)
}

# ── PII detection helpers ─────────────────────────────────────────────────────

# data_class string starting "pii." (the WALTEUR inventory convention).
holds_pii(r) if startswith(lower(to_str(object.get(r, "data_class", ""))), "pii.")

# explicit boolean flag (resource-manifest convention).
holds_pii(r) if r.pii == true

# classification label spelled out.
holds_pii(r) if lower(to_str(object.get(r, "classification", ""))) == "pii"

# nested data_classes array containing a pii.* class.
holds_pii(r) if {
	some c in object.get(r, "data_classes", [])
	startswith(lower(to_str(c)), "pii.")
}

# ── region helper ─────────────────────────────────────────────────────────────
# Read region from whichever key the document uses.

region_of(r) := lower(to_str(reg)) if {
	reg := object.get(r, "residency_region", object.get(r, "region", object.get(r, "location", "")))
	reg != ""
}

# ── encryption helper ─────────────────────────────────────────────────────────
# Encryption is OFF when explicitly false, or "none"/"off"/"disabled".

encryption_off(r) if r.encryption == false
encryption_off(r) if r.encrypted == false
encryption_off(r) if r.encryption_at_rest == false

encryption_off(r) if {
	v := lower(to_str(object.get(r, "encryption", "")))
	v != ""
	v in {"none", "off", "disabled", "false", "no"}
}

# ── public-exposure helper ────────────────────────────────────────────────────

is_public(r) if r.public == true
is_public(r) if r.public_access == true
is_public(r) if lower(to_str(object.get(r, "acl", ""))) == "public-read"
is_public(r) if lower(to_str(object.get(r, "acl", ""))) == "public-read-write"
is_public(r) if lower(to_str(object.get(r, "visibility", ""))) == "public"

# A sink that is a public/internet destination also counts as exposure.
is_public(r) if {
	some s in object.get(r, "sinks", [])
	contains(lower(to_str(s)), "public")
}

# ── DENY 1 — PII in a non-permitted region ────────────────────────────────────

deny contains msg if {
	some r in resources
	holds_pii(r)
	reg := region_of(r)
	not permitted_regions[reg]
	msg := sprintf(
		"residency: PII resource %q is in non-permitted region %q (data_class=%v); permitted: EU/EEA only",
		[resource_name(r), reg, object.get(r, "data_class", "pii")],
	)
}

# PII with NO declared region is also a denial — residency must be explicit.
deny contains msg if {
	some r in resources
	holds_pii(r)
	region_of(r) == ""
	msg := sprintf(
		"residency: PII resource %q has no declared residency_region/region (data_class=%v)",
		[resource_name(r), object.get(r, "data_class", "pii")],
	)
}

# ── DENY 2 — encryption OFF on a PII store ────────────────────────────────────

deny contains msg if {
	some r in resources
	holds_pii(r)
	encryption_off(r)
	msg := sprintf(
		"encryption: PII store %q has encryption disabled (data_class=%v); encryption at rest is mandatory for PII",
		[resource_name(r), object.get(r, "data_class", "pii")],
	)
}

# ── DENY 3 — public bucket holding PII ────────────────────────────────────────

deny contains msg if {
	some r in resources
	holds_pii(r)
	is_public(r)
	msg := sprintf(
		"exposure: PII store %q is publicly accessible (data_class=%v); PII must not be exposed publicly",
		[resource_name(r), object.get(r, "data_class", "pii")],
	)
}

# ── utilities ─────────────────────────────────────────────────────────────────

# Best-effort human name for a resource in messages.
resource_name(r) := n if {
	n := object.get(r, "name", "")
	n != ""
} else := n if {
	n := object.get(r, "id", "")
	n != ""
} else := "<unnamed>"

# Coerce any scalar to a string for case-insensitive comparison.
to_str(x) := x if is_string(x)
to_str(x) := sprintf("%v", [x]) if not is_string(x)
