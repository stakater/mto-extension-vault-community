#!/usr/bin/env bash
# Render tests for the mto-extension-vault-community charts.
#
# Ported from the Enterprise extension's harness (mto-extension-vault-enterprise
# hack/chart-render-tests.sh at 72f425c). There is no controller in this repo to
# catch a mistake downstream: these checks are the quality gate. Rules every
# check follows:
#   - A check that can pass on its own failure is worse than no check. Render on
#     its own line, check the status, then assert on the output — never inside
#     $(...), which discards the exit status.
#   - Every guard is paired with a positive control, so a guard that rejects
#     everything cannot pass.
#   - Report line 1 of a failure: infrastructure errors print first.
#
# Tenant chart:
#   golden       — component=all equals the committed golden, object for object
#                  and field for field.
#   disjoint     — no object is emitted by both slices (two TIs would fight over it via SSA).
#   union        — core ∪ eso emits exactly the all set, object for object
#                  (content, not only identities), for every fixture. So every
#                  content check below, which reads the all render, holds for
#                  the slices production applies: a path added to one slice
#                  only fails here.
#   exclusivity  — external-secrets.io objects appear only in the eso slice.
#   empty        — the eso slice with no opt-ins renders zero objects.
#   badvalue     — an unknown component fails the render with the helper's message.
#   namebudget   — a sliced render fails when the TI name would exceed 63 chars;
#                  component=all is exempt.
#   policyscope  — every Policy of every fixture passes the scope check, read from
#                  the rendered output: one-line stanzas, no sudo, no +, every path
#                  inside its tenant's mount (or its share), the tenant segment
#                  closed by /; on the all render and on each slice. A
#                  self-test proves the checker flags a bad line, and a hostile
#                  roleCaps fails the render itself.
#   scopebranches — every fail branch of vault.assertPolicyScope fails on its
#                  own bad input (a bare path line for the stanza rule),
#                  through a probe template that calls the helper directly; a
#                  good input renders.
#   quoting      — a ServiceAccount named true in a namespace named 123, with a
#                  share each way, renders every name, namespace,
#                  ServiceAccount and label value as a string.
#   ssogroups    — the SSO values that would break every tenant, or bind one
#                  group too widely, fail: a pattern without {tenant} (also
#                  with one role, where no other rule can refuse it), patterns
#                  that give two tenants (or one tenant's two roles) one group,
#                  in each branch of ssoCollision and in both role orders, a
#                  mapping that is not a map, fallback other than deny, a role
#                  named fallback (with caps), listed twice or without caps,
#                  caps with sudo or of another shape, an empty template, a
#                  double quote, a newline or a tab, a role that is not a DNS
#                  label (with caps), roles that are not a list or are empty;
#                  the tenant chart refuses its share of them, and a workload
#                  token ttl over its maxTTL; the defaults and the near misses
#                  render.
#   ssotoken     — one table of SSO token ttl and maxTTL through the tenant
#                  chart and the bootstrap: a ttl over the maxTTL (a side not
#                  set is the tenant chart's default) and a value Vault can't
#                  read fail in both; seconds, days, 1h30m, 1.5h, 500ms and
#                  Vault's default (0, "") are read as Vault reads them.
#   rolebind     — every workload role binds exactly its own policy, its tenant's
#                  mount, its own ServiceAccount, and a selector of exactly its
#                  namespace name and the tenant label: a namespace name reused by
#                  another tenant gets nothing.
#   mountagree   — the auth mount path agrees across the AuthEngineMount, its
#                  config, every role, the SecretStores and VAULT_K8S_MOUNT,
#                  also with a / around every mount path and name and around
#                  vco.authPath (the admission policies expect none, and the
#                  parent and the CEL carry it trimmed); VAULT_NAMESPACE is
#                  empty.
#   storepath    — every SecretStore reads the tenant's mount <tenant>/kv, KV v2,
#                  with no Vault namespace; every ExternalSecret key is relative
#                  to that mount; with ESO off install-wide, a Deployment asking
#                  for a secret gets a deploy-error and nothing else.
#   shares       — an export policy writes only shared/kv/…/from-<t>/to-<peer>/,
#                  an import policy reads only …/from-<peer>/to-<t>/; both roles
#                  live on the tenant's own mount (ADR-0007); the import store
#                  reads shared/kv; the ConfigMap's share namespaces are empty.
#   subread      — a kv-subscribe-ns grant is read-only on the producer's prefix,
#                  on the metadata path too; an audit-read subscriber lists only.
#   guards       — every misconfigured ServiceAccount or Deployment gets an error
#                  ConfigMap and nothing else; the correct ones in another
#                  namespace still render; identical asks are deduped, clashing
#                  ones refused; hostile values never reach a spec.
#   tokenseconds — token durations are integers on every role; a duration string
#                  fails the render with the schema removed, and the schema
#                  rejects it too.
#   tokentype    — every role pins tokenType; batch + period fails.
#   namecollide  — no two objects of one render share an identity, and parts
#                  that glued to one name with hyphens now give distinct names.
#   ssoredirect  — an empty sso.allowedRedirectUris fails at render, naming the
#                  value; {tenant} in an entry becomes the tenant's name.
#   ssorootlist  — every SSO policy can LIST the tenant's kv mount root.
#   ssoroles     — an SSO role that is not a DNS label, or is named "fallback",
#                  fails the render; a fallback mapping (a role with no group
#                  binding) fails the render.
#   ssobind      — every SSO role binds exactly its own policy, its tenant's OIDC
#                  mount, exactly its tenant's group, string claims, and accepts
#                  exactly sso.oidc.clientId as its audience.
#   falsestring  — the STRING "false" turns no feature on; "true" does.
#   alertlabels  — the ESO alert selects only labels ESO exports (condition,
#                  status, namespace) and names the tenant's namespaces.
#   contract     — the workload contract (annotation keys, Deployment forms, role
#                  names, object names, ConfigMap keys; hack/contract.sh) equals
#                  the pinned Enterprise chart's (hack/enterprise-contract.txt),
#                  except exactly the lines in hack/contract-delta.txt.
#
# Bootstrap and parent:
#   emission     — the parent emits one TI per enabled slice per tenant with a
#                  labelled namespace, none for a tenant without one, and a roster
#                  of exactly the rendered tenants.
#   reserved     — a tenant name that is not a DNS label, over 29 chars, the
#                  shared name, or the first segment of a path Vault or the
#                  platform uses (sys, auth, token, VCO's login mount,
#                  agent-registry, parent.reservedPaths) is skipped and listed in
#                  the skipped-tenants ConfigMap; a valid name beside them renders.
#   parentmounts — the parent's VCO objects are exactly <t>-kv per valid tenant
#                  and shared-kv, at <t>/kv and shared/kv. There is no shared auth
#                  mount: share roles live on each tenant's own (ADR-0007).
#   notargetns   — no render, tenant chart or parent, emits a Namespace CR, a
#                  targetNamespace or a Vault login namespace, and every VCO CR
#                  logs in the same way. Vault Community has one namespace.
#   templateset  — the bootstrap installs a child Template for exactly the enabled
#                  slices, and every templateRef the parent emits resolves.
#   rbacgate     — `create` on ESO kinds exists only while ESO is enabled; the reap
#                  verbs exist regardless (gating them wedges TI teardown).
#   rbaccover    — every redhatcop.redhat.io kind any render emits is in the
#                  ClusterRole (list only) and the configNamespace Role (all verbs).
#   toggles      — near-miss toggle values fail, via the schema with templates
#                  stripped AND via the helpers with the schema removed, each
#                  with its own message.
#   nulltoggle   — a toggle set to null, or a key whose toggle is commented
#                  out, renders what the default renders (admission on, ESO
#                  enabled); an explicit false still changes the render.
#   typeprobe    — every value the tenant chart and the parent render (VCO's
#                  login, the API host, the reviewer, the client secret key,
#                  the refresh interval, a slice key, the Vault address, the
#                  tenant label key) keeps the type of its field when it is a
#                  string YAML reads as a number, and no map key is a number.
#   nullfields   — no rendered field is YAML null, in the bootstrap, the parent,
#                  or the tenant chart with no workloads.
#   parentplumb  — install-wide knobs reach the child valuesTemplate; an unset
#                  token block is omitted, not empty; a ttl of 0 stays 0.
#   installvalues — every value installChecks reads fails when empty or
#                  malformed, through the helpers with the schema removed (and
#                  through the schema where it has a pattern); a reserved shared
#                  name, an empty SSO mount path, ttl over maxTTL (also with
#                  one side set, against the tenant chart's default), the
#                  Kubernetes and SSO mounts on one path or one inside the
#                  other, a quote or a backslash in vco.role and a malformed
#                  reviewer ServiceAccount fail; the schema refuses a
#                  tenantValues value of a type the tenant chart can't read,
#                  naming that field; kubernetes_prod as a mount path and the
#                  near misses render.
#   schemakeys   — at every object the bootstrap schema closes
#                  (additionalProperties: false), found by walking the schema,
#                  a misspelt key fails; the walk finds exactly the pinned
#                  list of objects; the required objects can't be nulled.
#   schemaforms  — schema_at and schema_rule read Helm's schema errors in both
#                  forms (before and after Helm 3.18), on fixed lines: CI runs
#                  one Helm, so the other form is proven here (DX.4).
#   tenantvaluekeys — the bootstrap schema's tenantValues keys (top level, sso,
#                  sso.oidc, sso.mount, monitoring) are the tenant chart's
#                  values.yaml keys, plus the removed ones whose guards name the
#                  fix; the bootstrap's default SSO roles are the tenant chart's
#                  sso.roles and roleCaps keys, and its default token ttl and
#                  maxTTL, SSO token ttl and maxTTL, SSO mount and group
#                  pattern the tenant chart's; the tenant chart's
#                  monitoring.enabled is off, as the RBAC gate assumes.
#   dnsregex     — every regex in the charts is one of the known forms: a
#                  DNS-label copy loosened or spelt another way fails.
#   versionpin   — the bootstrap's tenantChart.version equals the tenant chart
#                  version.
#   outputnames  — output and field names are unique within every Template.
#                  t-op-v2 rejects a field name repeated across outputs and
#                  then resolves none of them (OutputsResolved=False).
#   tenantname   — a tenant named 1234 renders, in the tenant chart and the
#                  parent, with every name, label value and path as a string; a
#                  name that is not a DNS label fails the tenant chart.
#   datalifetime — the tenant chart renders no kv mount; the parent renders it
#                  for every valid Tenant, including one with no labelled
#                  namespace, so deleting a tenant's last namespace cannot
#                  delete its Vault data.
#   tenantvalues — a tenantValues key the bootstrap owns is rejected, and a value
#                  containing "{{" is rejected.
#   ssoissuer    — the bootstrap refuses SSO without an issuer URL.
#   removedkeys  — a values file or tenantValues still setting a removed key
#                  (networkPolicy, sso.oidc.perTenantClient, sso.audience) fails;
#                  the shared SSO client still renders.
#   listingvis   — every mount the tenant chart and the parent render sets
#                  config.listingVisibility.
#                  Unset, VCO's finalizer update sends "" and its CRD enum refuses
#                  it: the CR gets no finalizer, and deleting it never deletes the
#                  mount in Vault.
#   admission    — the bootstrap renders the four admission policies and their
#                  bindings, with the install's values in their CEL: Template
#                  Operator's ServiceAccount, the config namespace, the tenant
#                  label, the API host, the issuer, the group pattern, the
#                  reserved names and VCO's login; the kinds and origin policies
#                  match every namespaced kind; admission.enabled=false renders
#                  none, and a near-miss value fails. What the CEL decides is
#                  `make admission-offline`.
#   vcopolicy    — charts/examples/vco-admin-policy.hcl (production) and the lab
#                  policy differ only by delete on the kv mounts; each grants
#                  exactly the extension's paths, so no other path — a
#                  sys/policies/acl/* or a + form that reaches vco-admin, a
#                  wildcard over sys/policy, sys/mounts, sys/auth or auth, VCO's
#                  own login mount — can pass; every mount pins its type.
#   release      — hack/release-chart.sh, against a stub helm: a published
#                  version with the same content is skipped (no push), one with
#                  other content fails, an explicit not-found is pushed,
#                  anything else fails without pushing.
#   bumpcheck    — hack/version-bump-check.sh in a scratch git repo: a trailing
#                  slash, an absolute path and a missing directory included.
#   fullnames    — kubectl commands in the docs, the Makefile and the scripts
#                  name TemplateInstances and Templates by their full resource
#                  name. On OpenShift the short names are OpenShift's own kinds.
#
# The parent gotemplate is rendered through helm's tpl — an approximation of
# t-op-v2's text/template+Sprig engine that is exact for the constructs it uses.
#
# Regenerating the golden after an INTENTIONAL chart change:
#   helm template mto-extension-vault-community charts/mto-extension-vault-community \
#     -n vault-config -f hack/render-fixtures/values-full.yaml \
#     | yq ea -P '[.] | sort_by(.apiVersion + "|" + .kind + "|" + (.metadata.namespace // "") + "|" + .metadata.name) | .[] | sort_keys(..) | splitDoc' \
#     > hack/render-fixtures/golden-all.yaml
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$REPO_ROOT/charts/mto-extension-vault-community"
BOOTSTRAP="$REPO_ROOT/charts/mto-extension-vault-community-bootstrap"
FIXTURES="$REPO_ROOT/hack/render-fixtures"
HELM="${HELM:-$(command -v "$REPO_ROOT/bin/helm" || command -v helm)}"
YQ="${YQ:-$(command -v "$REPO_ROOT/bin/yq" || command -v yq)}"
NS=vault-config
P=mto-extension-vault-community
RELEASE=mto-extension-vault-community
SLICES="core eso"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # check <name> <ok:0|1> [detail]
  if [ "$2" -eq 0 ]; then
    echo "PASS  $1"
  else
    echo "FAIL  $1${3:+ — $3}"
    fail=1
  fi
}
first() { head -1 "$1" | cut -c1-160; }
# Helm's schema errors name the field and the rule in one of two forms: Helm
# before 3.18 (gojsonschema) writes "- a.b: <message>", Helm 3.18 and later
# (jsonschema v6) "- at '/a/b': <message>". CI runs the Makefile's pinned Helm
# and HELM_MIN allows the older one, so a check accepts both (DX.4).
schema_at() { # schema_at <err file> <a.b>: a schema error names this field
  grep -qF -- "- $2: " "$1" || grep -qF -- "- at '/${2//.//}': " "$1"
}
schema_rule() { # schema_rule <err file> <a.b, or "" for the root> <rule> [arg]: the field fails this rule
  local f=$1 o=$2 s="/${2//.//}"
  [ -n "$2" ] || { o="(root)"; s=""; }
  case $3 in
    pattern) grep -qF -- "- $o: Does not match pattern" "$f" || grep -qE -- "- at '$s': '.*' does not match pattern" "$f" ;;
    unique) grep -qE -- "- ${o//./\\.}: array items\[[0-9]+,[0-9]+\] must be unique" "$f" \
      || grep -qE -- "- at '$s': items at [0-9]+ and [0-9]+ are equal" "$f" ;;
    additional) grep -qF -- "- $o: Additional property $4 is not allowed" "$f" || grep -qF -- "- at '$s': additional properties '$4' not allowed" "$f" ;;
    required) grep -qF -- "- $o: $4 is required" "$f" || grep -qF -- "- at '$s': missing property '$4'" "$f" ;;
    *) echo "schema_rule: no rule '$3'" >&2; return 2 ;;
  esac
}
# yqs <var> <expr> <file>: run yq to completion into <var>. A yq error stops the
# run: it must never read as an empty result, which is the pass condition of
# every "must not contain" check. Never pipe a producer into `grep -q` here —
# under pipefail grep's early exit SIGPIPEs the producer, and the pipeline
# status then says nothing about the match.
yqs() {
  local __o
  __o="$("$YQ" e -N "$2" "$3" 2>"$WORK/yq.err")" \
    || { echo "FAIL  infra — yq failed on $3: $(first "$WORK/yq.err")"; exit 1; }
  printf -v "$1" '%s' "$__o"
}
# lines <text>: the number of non-empty lines, for counts over a yqs result.
lines() { local n; n="$(printf '%s' "$1" | grep -c . || true)"; echo "${n:-0}"; }

# Copies without the schema, and without the templates, so a guard and the
# schema can each be tested on their own.
mkdir -p "$WORK/noschema" "$WORK/notpl"
cp -R "$BOOTSTRAP" "$WORK/noschema/boot"; rm "$WORK/noschema/boot/values.schema.json"
cp -R "$BOOTSTRAP" "$WORK/notpl/boot"; rm -rf "$WORK/notpl/boot/templates"; mkdir "$WORK/notpl/boot/templates"
cp -R "$CHART" "$WORK/noschema/tenant"; rm "$WORK/noschema/tenant/values.schema.json"
cp -R "$CHART" "$WORK/notpl/tenant"; rm -rf "$WORK/notpl/tenant/templates"; mkdir "$WORK/notpl/tenant/templates"

render() { # render <component> <valuesfile> [extra helm args...] -> manifest on stdout
  local c="$1" v="$2"; shift 2
  "$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$v" --set "component=$c" "$@"
}
# Sort docs by identity and normalise key order so comparisons are stable.
normalize() {
  "$YQ" ea -P '[.] | sort_by(.apiVersion + "|" + .kind + "|" + (.metadata.namespace // "") + "|" + .metadata.name) | .[] | sort_keys(..) | splitDoc'
}
identities() { # identities <normalized-file>
  "$YQ" ea '[.apiVersion + "|" + .kind + "|" + (.metadata.namespace // "") + "|" + .metadata.name] | .[]' "$1" | sort
}

# ─── Tenant chart ────────────────────────────────────────────────────────────
for c in all $SLICES; do
  render "$c" "$FIXTURES/values-full.yaml" > "$WORK/$c.raw" 2>"$WORK/$c.err" \
    || { echo "FAIL  setup — values-full component=$c did not render: $(first "$WORK/$c.err")"; exit 1; }
  normalize < "$WORK/$c.raw" > "$WORK/$c.yaml"
  identities "$WORK/$c.yaml" > "$WORK/$c.ids"
done
[ -s "$WORK/all.ids" ] || { echo "FAIL  setup — values-full rendered zero objects"; exit 1; }
# The bootstrap renders at setup too, before any check: a parse error in it
# stops the run here, and never reaches a check as that check's failure.
"$HELM" template b "$BOOTSTRAP" -n "$NS" > "$WORK/boot-default.yaml" 2>"$WORK/boot.err" \
  || { echo "FAIL  setup — the bootstrap did not render: $(first "$WORK/boot.err")"; exit 1; }
for fx in guards no-optins no-workloads; do
  render all "$FIXTURES/values-$fx.yaml" > "$WORK/fx-$fx.raw" 2>"$WORK/fx.err" \
    || { echo "FAIL  setup — values-$fx did not render: $(first "$WORK/fx.err")"; exit 1; }
done

# golden
normalize < "$FIXTURES/golden-all.yaml" > "$WORK/golden.yaml"
diff -u "$WORK/golden.yaml" "$WORK/all.yaml" > "$WORK/golden.diff" \
  && check golden 0 \
  || check golden 1 "component=all drifted from golden-all.yaml (see header for regeneration); first lines: $(head -6 "$WORK/golden.diff" | tail -3 | tr '\n' ' ')"

# disjoint
overlap="$(comm -12 "$WORK/core.ids" "$WORK/eso.ids")"
[ -z "$overlap" ] && check disjoint 0 || check disjoint 1 "emitted by both slices: $overlap"

# union — identities, then content, for every fixture
un_ok=0; un_detail=""
sort "$WORK/core.ids" "$WORK/eso.ids" > "$WORK/union.ids"
diff "$WORK/union.ids" "$WORK/all.ids" > /dev/null \
  || { un_ok=1; un_detail="$un_detail [core ∪ eso ≠ all: $({ diff "$WORK/union.ids" "$WORK/all.ids" || true; } | awk 'NR <= 4 { printf "%s ", $0 }')]"; }
for fx in full guards no-optins no-workloads; do
  for c in core eso; do
    render "$c" "$FIXTURES/values-$fx.yaml" > "$WORK/un-$c.raw" 2>"$WORK/un.err" \
      || { echo "FAIL  setup — values-$fx component=$c did not render: $(first "$WORK/un.err")"; exit 1; }
  done
  [ "$fx" = full ] && f_all="$WORK/all.raw" || f_all="$WORK/fx-$fx.raw"
  cat "$WORK/un-core.raw" "$WORK/un-eso.raw" | normalize > "$WORK/un-slices.yaml"
  normalize < "$f_all" > "$WORK/un-all.yaml"
  diff -u "$WORK/un-all.yaml" "$WORK/un-slices.yaml" > "$WORK/un.diff" \
    || { un_ok=1; un_detail="$un_detail [values-$fx: the slices' objects differ from the all render's: $(grep -E '^[-+][^-+]' "$WORK/un.diff" | head -4 | tr '\n' '|' || true)]"; }
done
[ -s "$WORK/all.raw" ] || { un_ok=1; un_detail="$un_detail [no all render — the check proves nothing]"; }
check union "$un_ok" "$un_detail"

# exclusivity
ex_ok=0; ex_detail=""
eso_in_eso="$(grep -c '^apiVersion: external-secrets\.io/' "$WORK/eso.yaml" || true)"
eso_in_core="$(grep -c '^apiVersion: external-secrets\.io/' "$WORK/core.yaml" || true)"
[ "$eso_in_eso" -gt 0 ] || { ex_ok=1; ex_detail="$ex_detail external-secrets.io missing from eso;"; }
[ "$eso_in_core" -eq 0 ] || { ex_ok=1; ex_detail="$ex_detail external-secrets.io leaked into core ($eso_in_core);"; }
check exclusivity "$ex_ok" "$ex_detail"

# empty
if render eso "$FIXTURES/values-no-optins.yaml" > "$WORK/empty.yaml" 2>"$WORK/empty.err"; then
  # yqs, not `yq | grep -c || true`: a yq failure then stops the run instead of
  # counting as zero objects, which is this check's pass condition.
  yqs emptykinds 'select(.kind != null) | .kind' "$WORK/empty.yaml"
  emptycount="$(lines "$emptykinds")"
  [ "$emptycount" -eq 0 ] && check empty 0 || check empty 1 "expected 0 objects, got $emptycount"
else
  check empty 1 "render itself failed: $(first "$WORK/empty.err")"
fi

# badvalue
if render bogus "$FIXTURES/values-full.yaml" > /dev/null 2> "$WORK/bogus.err"; then
  check badvalue 1 "component=bogus rendered instead of failing"
else
  grep -q 'unknown component' "$WORK/bogus.err" \
    && check badvalue 0 \
    || check badvalue 1 "failed without the componentEnabled message: $(first "$WORK/bogus.err")"
fi

# namebudget — "mto-extension-vault-community-" is 30 chars: core ≤33, .eso ≤29.
nb_ok=0; nb_detail=""
t33="$(printf 'a%.0s' $(seq 1 33))"; t34="${t33}a"; t29="$(printf 'a%.0s' $(seq 1 29))"; t30="${t29}a"
nb_case() { # nb_case <component> <tenant> <expect: ok|fail>
  if render "$1" "$FIXTURES/values-no-optins.yaml" --set "tenant=$2" > /dev/null 2>"$WORK/nb.err"; then
    [ "$3" = ok ] || { nb_ok=1; nb_detail="$nb_detail [$1 tenant len ${#2} rendered, expected fail]"; }
  else
    if [ "$3" = fail ]; then
      grep -q 'label values cap at 63' "$WORK/nb.err" || { nb_ok=1; nb_detail="$nb_detail [$1 len ${#2} failed without the budget message: $(first "$WORK/nb.err")]"; }
    else
      nb_ok=1; nb_detail="$nb_detail [$1 tenant len ${#2} failed, expected ok: $(first "$WORK/nb.err")]"
    fi
  fi
}
nb_case core "$t33" ok; nb_case core "$t34" fail
nb_case eso "$t29" ok;  nb_case eso "$t30" fail
nb_case all "$t34" ok
check namebudget "$nb_ok" "$nb_detail"

# policyscope — the scope check, read from the rendered output (design §4).
# scope_violations <manifest> <env> -> one line per violation, empty when clean
scope_violations() {
  local n line tenant fam parts p re env="$2"
  local stanza='^path "([^"]+)" +\{ capabilities = \[("[a-z]+")(, "[a-z]+")*\] \}$'
  "$YQ" e -N 'select(.kind == "Policy") | .metadata.name as $n | .spec.policy | split("\n") | .[] | $n + "	" + .' "$1" > "$WORK/ps.lines" \
    || { echo "yq failed on $1"; return; }
  while IFS=$'\t' read -r n line; do
    line="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$line")"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    IFS=. read -r -a parts <<<"$n"
    fam="${parts[0]}"; tenant="${parts[1]:-}"
    if ! [[ "$line" =~ $stanza ]]; then echo "$n: not a one-line stanza: $line"; continue; fi
    p="${BASH_REMATCH[1]}"
    case "$line" in *'"sudo"'*) echo "$n: sudo: $line" ;; esac
    case "$p" in *+*) echo "$n: + in $p" ;; esac
    case "$fam/${#parts[@]}" in
      kv/4|sso/3) re="^$tenant/kv/(data|metadata|delete|undelete|destroy)/$env/([a-z0-9_][-a-z0-9_.]*/)*\*\$"
                  [ "$fam" = sso ] && [ "$p" = "$tenant/kv/metadata" ] && continue ;;
      share/6)    if [ "${parts[4]}" = out ]; then re="^shared/kv/(data|metadata)/$env/from-$tenant/to-${parts[5]}/\*\$"
                  else re="^shared/kv/(data|metadata)/$env/from-${parts[5]}/to-$tenant/\*\$"
                    case "$line" in *'"create"'*|*'"update"'*|*'"patch"'*|*'"delete"'*) echo "$n: an import writes: $line" ;; esac
                  fi ;;
      *) echo "$n: in no name family"; continue ;;
    esac
    [[ "$p" =~ $re ]] || echo "$n: $p is outside $re"
  done < "$WORK/ps.lines"
}
ps_ok=0; ps_detail=""
# Self-test: the checker flags each kind of bad line and passes a good one.
cat > "$WORK/ps-self.yaml" <<'YAML'
kind: Policy
metadata: { name: kv.team.ns.sa }
spec:
  policy: |
    # a comment is fine
    path "team/kv/data/dev/ns/sa/*" { capabilities = ["read"] }
    path "team-a/kv/data/dev/ns/sa/*" { capabilities = ["read"] }
    path "team*" { capabilities = ["read"] }
    path "team/kv/data/dev/+/sa/*" { capabilities = ["read"] }
    path "team/kv/data/dev/ns/sa/*" { capabilities = ["read", "sudo"] }
    path "team/kv/config" { capabilities = ["update"] }
    path "team/kv/data/dev/ns/sa/*" {
      capabilities = ["read"] }
YAML
self="$(scope_violations "$WORK/ps-self.yaml" dev)"
for want in 'team-a/kv/data/dev/ns/sa/\* is outside' 'team\* is outside' '\+ in team/kv/data/dev/\+/sa' 'sudo: ' 'team/kv/config is outside' 'not a one-line stanza: path "team/kv/data/dev/ns/sa/\*" \{$' 'not a one-line stanza: capabilities'; do
  grep -qE "$want" <<<"$self" || { ps_ok=1; ps_detail="$ps_detail [self-test: no violation matching '$want' in: $(tr '\n' '|' <<<"$self")]"; }
done
grep -q 'team/kv/data/dev/ns/sa/\* is outside' <<<"$self" && { ps_ok=1; ps_detail="$ps_detail [self-test: a good line was flagged]"; }
for f in all.raw core.raw eso.raw fx-guards.raw fx-no-optins.raw fx-no-workloads.raw; do
  v="$(scope_violations "$WORK/$f" dev)"
  [ -z "$v" ] || { ps_ok=1; ps_detail="$ps_detail [$f: $(tr '\n' '|' <<<"$v")]"; }
done
yqs npol 'select(.kind == "Policy") | .metadata.name' "$WORK/all.raw"
[ "$(lines "$npol")" -ge 4 ] || { ps_ok=1; ps_detail="$ps_detail [values-full rendered $(lines "$npol") policies — the check proves nothing]"; }
yqs ncore 'select(.kind == "Policy") | .metadata.name' "$WORK/core.raw"
[ "$(lines "$ncore")" = "$(lines "$npol")" ] || { ps_ok=1; ps_detail="$ps_detail [the core slice rendered $(lines "$ncore") policies, all $(lines "$npol")]"; }
# The render-time guard: a role capability list with sudo, and an env that
# would put a wildcard into the path, fail the render itself.
printf 'roleCaps:\n  editor: %s\n' "'[\"read\", \"sudo\"]'" > "$WORK/ps-sudo.yaml"
for c in "-f $WORK/ps-sudo.yaml:grants sudo" "--set env=dev/*:is not a DNS label"; do
  if render core "$FIXTURES/values-full.yaml" ${c%%:*} > /dev/null 2>"$WORK/ps.err"; then
    ps_ok=1; ps_detail="$ps_detail [${c%%:*} rendered]"
  else
    grep -q -- "${c#*:}" "$WORK/ps.err" || { ps_ok=1; ps_detail="$ps_detail [${c%%:*} failed elsewhere: $(first "$WORK/ps.err")]"; }
  fi
done
check policyscope "$ps_ok" "$ps_detail"

# scopebranches — a probe template calls vault.assertPolicyScope directly, so
# each fail branch gets a bad input the chart itself never renders.
sb2_ok=0; sb2_detail=""
cp -R "$CHART" "$WORK/probe"
printf '{{- with .Values.probe }}{{ include "vault.assertPolicyScope" (dict "name" .name "policy" .policy "ctx" $) }}{{ end }}\n' > "$WORK/probe/templates/zz-probe.yaml"
probe() { # probe <label> <name> <policy> <expect: ok | message> [extra helm args]
  local label="$1" name="$2" body="$3" want="$4"; shift 4
  printf 'probe:\n  name: %s\n  policy: |\n%s\n' "$name" "$(sed 's/^/    /' <<<"$body")" > "$WORK/probe.yaml"
  if "$HELM" template x "$WORK/probe" -n "$NS" --set tenant=t --set env=dev -f "$WORK/probe.yaml" "$@" > /dev/null 2>"$WORK/probe.err"; then
    [ "$want" = ok ] || { sb2_ok=1; sb2_detail="$sb2_detail [$label rendered, want '$want']"; }
  else
    if [ "$want" = ok ]; then
      sb2_ok=1; sb2_detail="$sb2_detail [$label failed, want ok: $(first "$WORK/probe.err")]"
    else
      grep -qF -- "$want" "$WORK/probe.err" || { sb2_ok=1; sb2_detail="$sb2_detail [$label failed elsewhere: $(first "$WORK/probe.err")]"; }
    fi
  fi
}
good='path "t/kv/data/dev/ns/sa/*" { capabilities = ["read"] }'
probe good          kv.t.ns.sa           "$good" ok
probe sso-root      sso.t.admin          'path "t/kv/metadata" { capabilities = ["list"] }' ok
probe share-in-read share.t.ns.sa.in.p   'path "shared/kv/data/dev/from-p/to-t/*" { capabilities = ["read", "list"] }' ok
probe env           kv.t.ns.sa           "$good" 'is not a DNS label: it is a segment of every policy path' --set 'env=dev/*'
probe shared        kv.t.ns.sa           "$good" 'sharedTenant.name "sh.red" is not a DNS label' --set sharedTenant.name=sh.red
probe tenant        kv.other.ns.sa       "$good" 'does not belong to tenant'
probe kv-parts      kv.t.ns.sa.extra     "$good" 'is in no name family'
probe sso-parts     sso.t.admin.extra    "$good" 'is in no name family'
probe share-parts   share.t.ns.sa.out    "$good" 'is in no name family'
probe family        vault.t.ns.sa        "$good" 'is in no name family'
probe part          kv.t.NS.sa           "$good" 'that is not a DNS label'
probe share-dir     share.t.ns.sa.both.p "$good" 'is neither .out. nor .in.'
probe stanza        kv.t.ns.sa           'path "t/kv/data/dev/ns/sa/*" {' 'not a one-line path stanza'
# A bare path in scope: only the stanza rule refuses it (the path rule reads
# the whole line as the path when the line is not a stanza).
probe stanza-bare   kv.t.ns.sa           't/kv/data/dev/ns/sa/*' 'not a one-line path stanza'
probe sudo          kv.t.ns.sa           'path "t/kv/data/dev/ns/sa/*" { capabilities = ["read", "sudo"] }' 'grants sudo'
probe outside       kv.t.ns.sa           'path "t/kv/config" { capabilities = ["update"] }' 'outside its scope'
probe prefix        kv.t.ns.sa           'path "t-a/kv/data/dev/ns/sa/*" { capabilities = ["read"] }' 'outside its scope'
probe share-way     share.t.ns.sa.out.p  'path "shared/kv/data/dev/from-p/to-t/*" { capabilities = ["read"] }' 'outside its scope'
probe import-write  share.t.ns.sa.in.p   'path "shared/kv/data/dev/from-p/to-t/*" { capabilities = ["read", "create"] }' 'writes'
check scopebranches "$sb2_ok" "$sb2_detail"

# quoting — names YAML would read as a bool or a number. A role named
# kv.t.123.true is fine; namespace: 123 or - true is an int and a bool, and
# the admission of the whole tenant's apply fails on them.
qt_ok=0; qt_detail=""
cat > "$WORK/qt.yaml" <<'YAML'
tenant: t
serviceAccounts:
  - metadata: {name: "true", namespace: "123", annotations: {vault.stakater.com/kv: "true", vault.stakater.com/role: editor, vault.stakater.com/kv-export-tenant: "456", vault.stakater.com/kv-import-tenant: "456"}}
knownTenants: "t,456"
deployments:
  - metadata: {name: "456", namespace: "123", annotations: {vault.stakater.com/kv-secret.null: "db#password"}}
    spec: {template: {spec: {serviceAccountName: "true"}}}
YAML
render all "$WORK/qt.yaml" > "$WORK/qt.out" 2>"$WORK/qt.err" || { qt_ok=1; qt_detail="$qt_detail [the fixture did not render: $(first "$WORK/qt.err")]"; }
yqs qtnon '(.metadata.name | select(tag != "!!str")), (.metadata.namespace | select(. != null and tag != "!!str")), (.spec.targetServiceAccounts[]? | select(tag != "!!str")), (.. | select(has("serviceAccountRef")) | .serviceAccountRef.name | select(tag != "!!str")), (.. | select(has("matchLabels")) | .matchLabels[] | select(tag != "!!str")), (.metadata.labels[]? | select(tag != "!!str"))' "$WORK/qt.out"
[ -z "$qtnon" ] || { qt_ok=1; qt_detail="$qt_detail [non-string names: $(tr '\n' ' ' <<<"$qtnon")]"; }
yqs qtkinds 'select(.metadata.namespace == "123") | .kind' "$WORK/qt.out"
for k in ConfigMap SecretStore ExternalSecret; do
  grep -qx "$k" <<<"$qtkinds" || { qt_ok=1; qt_detail="$qt_detail [no $k in namespace 123 — the check proves nothing]"; }
done
yqs qtshare 'select(.kind == "KubernetesAuthEngineRole" and (.metadata.name | test("^share[.]"))) | .metadata.name' "$WORK/qt.out"
[ "$(lines "$qtshare")" = 2 ] || { qt_ok=1; qt_detail="$qt_detail [want 2 share roles for ServiceAccount true, got: $(tr '\n' ' ' <<<"$qtshare")]"; }
check quoting "$qt_ok" "$qt_detail"

# rolebind
rb_ok=0; rb_detail=""
for f in all.raw fx-guards.raw; do
  yqs roles 'select(.kind == "KubernetesAuthEngineRole") | .metadata.name + " " + .spec.name + " " + (.spec.policies | join(",")) + " " + .spec.path + " " + (.spec.targetServiceAccounts | join(",")) + " " + (.spec.targetNamespaces.targetNamespaceSelector.matchLabels | to_entries | map(.key + "=" + .value) | sort | join(",")) + " " + ((.spec.targetNamespaces | has("targetNamespaces")) | tostring)' "$WORK/$f"
  [ -n "$roles" ] || { rb_ok=1; rb_detail="$rb_detail [$f: no roles — the check proves nothing]"; continue; }
  while read -r meta name pols path sas sel list; do
    IFS=. read -r -a parts <<<"$name"
    t="${parts[1]}"; ns="${parts[2]}"; sa="${parts[3]}"
    want="$name $name $name $t/kubernetes/workloads $sa kubernetes.io/metadata.name=$ns,stakater.com/tenant=$t false"
    got="$meta $name $pols $path $sas $sel $list"
    [ "$got" = "$want" ] || rb_detail="$rb_detail [$f: got '$got' want '$want']"
  done <<<"$roles"
done
[ -z "$rb_detail" ] || rb_ok=1
check rolebind "$rb_ok" "$rb_detail"

# mountagree — on the full render, and on one with a / around every mount
# path and name: the install check trims it, and the admission policies
# expect every object without it.
ma_ok=0; ma_detail=""
render all "$FIXTURES/values-full.yaml" --set kubernetesAuth.path=/kubernetes/ --set kubernetesAuth.name=workloads/ \
  --set sso.mount.path=oidc/ --set sso.mount.name=/sso/ --set vco.authPath=/kubernetes/ > "$WORK/ma-slash.raw" 2>"$WORK/ma.err" \
  || { ma_ok=1; ma_detail="$ma_detail [the render with slashes failed: $(first "$WORK/ma.err")]"; }
for f in all.raw ma-slash.raw; do
  yqs m_auth 'select(.kind == "AuthEngineMount" and .spec.type == "kubernetes") | .spec.path + "/" + .spec.name' "$WORK/$f"
  yqs m_cfg 'select(.kind == "KubernetesAuthEngineConfig") | .spec.path + "/" + .spec.name' "$WORK/$f"
  yqs m_roles 'select(.kind == "KubernetesAuthEngineRole") | .spec.path' "$WORK/$f"
  yqs m_cms 'select(.kind == "ConfigMap" and (.data | has("VAULT_K8S_MOUNT"))) | .data.VAULT_K8S_MOUNT' "$WORK/$f"
  yqs m_stores 'select(.kind == "SecretStore") | .spec.provider.vault.auth.kubernetes.mountPath' "$WORK/$f"
  for pair in "AuthEngineMount:$m_auth" "KubernetesAuthEngineConfig:$m_cfg" "roles:$(sort -u <<<"$m_roles")" "SecretStores:$(sort -u <<<"$m_stores")" "VAULT_K8S_MOUNT:$(sort -u <<<"$m_cms")"; do
    [ "${pair#*:}" = team-a/kubernetes/workloads ] || { ma_ok=1; ma_detail="$ma_detail [$f ${pair%%:*}: '$(echo "${pair#*:}" | tr '\n' ' ')']"; }
  done
  yqs m_sso 'select(.kind == "AuthEngineMount" and .spec.type == "oidc") | .spec.path + "/" + .spec.name' "$WORK/$f"
  yqs m_ssocfg 'select(.kind == "JWTOIDCAuthEngineConfig") | .spec.path' "$WORK/$f"
  yqs m_ssoroles 'select(.kind == "JWTOIDCAuthEngineRole") | .spec.path' "$WORK/$f"
  for pair in "oidc AuthEngineMount:$m_sso" "JWTOIDCAuthEngineConfig:$m_ssocfg" "oidc roles:$(sort -u <<<"$m_ssoroles")"; do
    [ "${pair#*:}" = team-a/oidc/sso ] || { ma_ok=1; ma_detail="$ma_detail [$f ${pair%%:*}: '$(echo "${pair#*:}" | tr '\n' ' ')']"; }
  done
  # VCO's own login mount, as every CR names it: the admission policies
  # expect it without a /.
  yqs m_vco 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .spec.authentication.path' "$WORK/$f"
  [ "$(sort -u <<<"$m_vco")" = kubernetes ] || { ma_ok=1; ma_detail="$ma_detail [$f vco.authPath: '$(sort -u <<<"$m_vco" | tr '\n' ' ')']"; }
done
# The bootstrap with the same slashes: the parent's parameter and the CEL
# carry the trimmed path.
"$HELM" template b "$BOOTSTRAP" -n "$NS" --set vco.authPath=/kubernetes/ > "$WORK/ma-boot.yaml" 2>"$WORK/ma.err" \
  || { ma_ok=1; ma_detail="$ma_detail [the bootstrap with vco.authPath=/kubernetes/ failed: $(first "$WORK/ma.err")]"; }
yqs ma_param 'select(.kind == "Template") | .spec.parameters[]? | select(.name == "vcoAuthPath") | .value' "$WORK/ma-boot.yaml"
[ "$ma_param" = kubernetes ] || { ma_ok=1; ma_detail="$ma_detail [the parent's vcoAuthPath is '$ma_param']"; }
grep -qF "object.spec.authentication.path == 'kubernetes' &&" "$WORK/ma-boot.yaml" \
  || { ma_ok=1; ma_detail="$ma_detail [the admission policies expect another vco.authPath than kubernetes]"; }
yqs vns 'select(.kind == "ConfigMap" and (.metadata.name | test("^vault-config-")) and (.data | has("VAULT_K8S_MOUNT"))) | .metadata.name + "=" + (.data.VAULT_NAMESPACE | tostring)' "$WORK/all.raw"
[ -n "$vns" ] || { ma_ok=1; ma_detail="$ma_detail [no vault-config ConfigMap — the check proves nothing]"; }
bad="$(grep -v '=$' <<<"$vns" || true)"
[ -z "$bad" ] || { ma_ok=1; ma_detail="$ma_detail [VAULT_NAMESPACE not empty: $(tr '\n' ' ' <<<"$bad")]"; }
check mountagree "$ma_ok" "$ma_detail"

# storepath
sp_ok=0; sp_detail=""
yqs stores 'select(.kind == "SecretStore") | .metadata.name + " " + .spec.provider.vault.path + " " + .spec.provider.vault.version + " " + (.spec.provider.vault | has("namespace") | tostring)' "$WORK/all.raw"
[ -n "$stores" ] || { sp_ok=1; sp_detail="$sp_detail [no SecretStore rendered — the check proves nothing]"; }
while read -r name path version hasns; do
  want_path=team-a/kv; case "$name" in *.share-*) want_path=shared/kv ;; esac
  [ "$path $version $hasns" = "$want_path v2 false" ] || sp_detail="$sp_detail [$name: path $path, version $version, namespace field $hasns]"
done <<<"$stores"
yqs eskeys 'select(.kind == "ExternalSecret") | .metadata.name + " " + ((.spec.data[0].remoteRef.key) // (.spec.dataFrom[0].extract.key))' "$WORK/all.raw"
[ -n "$eskeys" ] || { sp_ok=1; sp_detail="$sp_detail [no ExternalSecret rendered — the check proves nothing]"; }
while read -r name key; do
  case "$key" in
    dev/team-a-dev/payments/*|dev/_shared/from-team-a-tools/*|dev/from-team-b/to-team-a/*) ;;
    *) sp_detail="$sp_detail [$name reads $key, not relative to the tenant mount under dev/team-a-dev/payments/]" ;;
  esac
done <<<"$eskeys"
render all "$FIXTURES/values-full.yaml" --set eso=disabled > "$WORK/eso-off.yaml" 2>"$WORK/eso-off.err" \
  || sp_detail="$sp_detail [eso=disabled did not render: $(first "$WORK/eso-off.err")]"
yqs esooff 'select(.apiVersion | test("^external-secrets")) | .kind + "/" + .metadata.name' "$WORK/eso-off.yaml"
[ -z "$esooff" ] || sp_detail="$sp_detail [eso=disabled still renders $(tr '\n' ' ' <<<"$esooff")]"
yqs esoerr 'select(.kind == "ConfigMap" and .metadata.name == "vault-config-web.deploy-error") | .data.ERROR' "$WORK/eso-off.yaml"
grep -q 'External Secrets Operator is disabled' <<<"$esoerr" || sp_detail="$sp_detail [eso=disabled: no deploy-error for web]"
[ -z "$sp_detail" ] || sp_ok=1
check storepath "$sp_ok" "$sp_detail"

# shares
sh_ok=0; sh_detail=""
pol() { "$YQ" e -N "select(.kind == \"Policy\" and .metadata.name == \"$1\") | .spec.policy" "$WORK/all.raw"; }
out_pol="$(pol share.team-a.team-a-dev.app-a.out.team-b)"; in_pol="$(pol share.team-a.team-a-dev.app-a.in.team-b)"
want_out='path "shared/kv/data/dev/from-team-a/to-team-b/*"     { capabilities = ["create", "read", "update", "list"] }
path "shared/kv/metadata/dev/from-team-a/to-team-b/*" { capabilities = ["create", "read", "update", "list"] }'
want_in='path "shared/kv/data/dev/from-team-b/to-team-a/*"     { capabilities = ["read", "list"] }
path "shared/kv/metadata/dev/from-team-b/to-team-a/*" { capabilities = ["read", "list"] }'
[ "$out_pol" = "$want_out" ] || { sh_ok=1; sh_detail="$sh_detail [export policy: $(tr '\n' '|' <<<"$out_pol")]"; }
[ "$in_pol" = "$want_in" ] || { sh_ok=1; sh_detail="$sh_detail [import policy: $(tr '\n' '|' <<<"$in_pol")]"; }
yqs shroles 'select(.kind == "KubernetesAuthEngineRole" and (.metadata.name | test("^share[.]"))) | .metadata.name + " " + .spec.path' "$WORK/all.raw"
[ "$(lines "$shroles")" = 2 ] || { sh_ok=1; sh_detail="$sh_detail [want 2 share roles, got: $(tr '\n' '|' <<<"$shroles")]"; }
elsewhere="$(grep -v ' team-a/kubernetes/workloads$' <<<"$shroles" || true)"
[ -z "$elsewhere" ] || { sh_ok=1; sh_detail="$sh_detail [a share role is not on the tenant's own mount: $(tr '\n' '|' <<<"$elsewhere")]"; }
yqs shns 'select(.kind == "ConfigMap" and .metadata.name == "vault-config-app-a") | .data | to_entries | .[] | select(.key | test("^VAULT_(OUT|IN)_.*_NAMESPACE$")) | .key + "=" + .value' "$WORK/all.raw"
[ "$(sort <<<"$shns" | tr '\n' ' ')" = "VAULT_IN_TEAM_B_NAMESPACE= VAULT_OUT_TEAM_B_NAMESPACE= " ] || { sh_ok=1; sh_detail="$sh_detail [share namespaces in the ConfigMap: '$(tr '\n' ' ' <<<"$shns")']"; }
# An off-roster peer renders nothing; the share self-heals when it appears.
render all "$FIXTURES/values-full.yaml" --set knownTenants=team-a > "$WORK/sh-roster.yaml" 2>"$WORK/sh.err" || { sh_ok=1; sh_detail="$sh_detail [render with a roster without team-b failed: $(first "$WORK/sh.err")]"; }
yqs shoff 'select(.metadata.name | test("share")) | .kind + "/" + .metadata.name' "$WORK/sh-roster.yaml"
[ -z "$shoff" ] || { sh_ok=1; sh_detail="$sh_detail [shares to an off-roster peer rendered: $(tr '\n' ' ' <<<"$shoff")]"; }
check shares "$sh_ok" "$sh_detail"

# subread — app-a (editor) subscribes to team-a-tools; app-d (audit-read) to team-a-dev
sr_ok=0; sr_detail=""
pol() { "$YQ" e -N "select(.kind == \"Policy\" and .metadata.name == \"$1\") | .spec.policy" "$WORK/all.raw"; }
pol kv.team-a.team-a-dev.app-a > "$WORK/pol-a"
grep -q 'path "team-a/kv/metadata/dev/_shared/from-team-a-tools/\*" { capabilities = \["read", "list"\] }' "$WORK/pol-a" \
  || { sr_ok=1; sr_detail="$sr_detail [editor subscriber metadata grant is not read/list]"; }
grep -qE 'path "team-a/kv/data/dev/_shared/from-team-a-tools/\*" +\{ capabilities = \["read", "list"\] \}' "$WORK/pol-a" \
  || { sr_ok=1; sr_detail="$sr_detail [editor subscriber data grant is not read/list]"; }
grep 'from-team-a-tools' "$WORK/pol-a" > "$WORK/pol-a-sub" \
  || { sr_ok=1; sr_detail="$sr_detail [no from-team-a-tools grant at all]"; }
grep -qE '"(create|update|patch|delete)"' "$WORK/pol-a-sub" \
  && { sr_ok=1; sr_detail="$sr_detail [a write capability on the producer's prefix]"; }
pol kv.team-a.team-a-tools.app-d > "$WORK/pol-d"
grep -q 'path "team-a/kv/metadata/dev/_shared/from-team-a-dev/\*" { capabilities = \["list"\] }' "$WORK/pol-d" \
  || { sr_ok=1; sr_detail="$sr_detail [audit-read subscriber metadata grant is not list-only]"; }
grep -q 'team-a/kv/data/dev/_shared/from-team-a-dev/' "$WORK/pol-d" \
  && { sr_ok=1; sr_detail="$sr_detail [audit-read subscriber was granted data reads]"; }
yqs fromkey 'select(.kind == "ConfigMap" and .metadata.name == "vault-config-app-a") | .data.VAULT_FROM_TEAM_A_TOOLS_PATH + " " + .data.VAULT_KV_SHARED_OUT_PATH' "$WORK/all.raw"
[ "$fromkey" = "team-a/kv/data/dev/_shared/from-team-a-tools/ team-a/kv/data/dev/_shared/from-team-a-dev/" ] \
  || { sr_ok=1; sr_detail="$sr_detail [app-a's shared ConfigMap keys: '$fromkey']"; }
check subread "$sr_ok" "$sr_detail"

# guards
gd_ok=0; gd_detail=""
for pair in \
  "g-role-only:kv is not" "g-no-role:role is not set" "g-bad-role:is not a known role" \
  "g-transit:is not supported" "g-injection:is not a valid app name" "g-wildcard:is not a valid app name" \
  "g-reserved:is not a valid app name" "g-claimed:claimed by more than one" "g-claimer:claimed by more than one" \
  "default:cannot be granted Vault access" "g-unknown-key:unknown annotation" "g-bad-bool:must be" \
  "g-app-only:no app identity is registered" "g.dotted:cannot be used with Vault" \
  "g-foreign-ns:is not a namespace of tenant" "g-orphan-sub:so it grants nothing" \
  "g-orphan-share:so it grants nothing" "g-share-err:is not a known role"; do
  sa="${pair%%:*}"; msg="${pair#*:}"
  yqs err "select(.kind == \"ConfigMap\" and .metadata.name == \"vault-config-$sa.error\") | .data.ERROR" "$WORK/fx-guards.raw"
  grep -q -- "$msg" <<<"$err" \
    || { gd_ok=1; gd_detail="$gd_detail [$sa: no error ConfigMap saying '$msg']"; }
  yqs hit "select(.kind == \"Policy\" and (.metadata.name | test(\"[.]$sa\$\"))) | .metadata.name" "$WORK/fx-guards.raw"
  [ -n "$hit" ] \
    && { gd_ok=1; gd_detail="$gd_detail [$sa: a Policy rendered despite the error]"; }
done
# The share templates' own error gate: a rejected ServiceAccount with share
# annotations gets no share Policy, Role or SecretStore.
yqs sharehit 'select(.metadata.name | test("g-share-err")) | select(.kind != "ConfigMap") | .kind + "/" + .metadata.name' "$WORK/fx-guards.raw"
[ -z "$sharehit" ] || { gd_ok=1; gd_detail="$gd_detail [a rejected ServiceAccount still got share objects: $(tr '\n' ' ' <<<"$sharehit")]"; }
# Positive controls in the other namespace.
for sa in good-sa hostile-sa sub-ok; do
  yqs hit "select(.kind == \"Policy\" and .metadata.name == \"kv.team-a.team-a-prod.$sa\") | .metadata.name" "$WORK/fx-guards.raw"
  [ -n "$hit" ] \
    || { gd_ok=1; gd_detail="$gd_detail [$sa: correct SA rendered no Policy — one namespace's error froze another]"; }
done
# Deployment-level cases.
es_count() { local es; yqs es "select(.kind == \"ExternalSecret\" and .metadata.name == \"$1\") | .metadata.name" "$WORK/fx-guards.raw"; lines "$es"; }
[ "$(es_count good-sa-db)" = 1 ] || { gd_ok=1; gd_detail="$gd_detail [identical asks were not deduped to ONE ExternalSecret]"; }
[ "$(es_count good-sa-cfg)" = 0 ] || { gd_ok=1; gd_detail="$gd_detail [clashing asks rendered an ExternalSecret]"; }
[ "$(es_count sub-ok-y)" = 1 ] || { gd_ok=1; gd_detail="$gd_detail [a granted subscription rendered no ExternalSecret]"; }
[ "$(es_count good-sa-z)" = 1 ] || { gd_ok=1; gd_detail="$gd_detail [an own-namespace subscription rendered no ExternalSecret]"; }
[ "$(es_count sub-missing-x)" = 0 ] || { gd_ok=1; gd_detail="$gd_detail [an ungranted subscription rendered an ExternalSecret]"; }
for pair in "d-clash-a:ask for different secrets" "d-clash-b:ask for different secrets" "d-no-sa:requires spec.template.spec.serviceAccountName" \
  "d-misplaced:is read on the ServiceAccount" "d-ghost-sa:does not exist in namespace" "d-no-kv:needs KV access" \
  "d-sub-nogrant:does not list it in" "d-sub-foreign:is not a namespace of tenant" \
  "d-imp-bad:not in the tenant roster" "d-imp-nogrant:does not list it in" \
  "d-unknown:unknown annotation" "d-evil-key:field selector" "d-evil-leaf:is not a valid secret reference" "d-evil-name:names the Kubernetes Secret"; do
  d="${pair%%:*}"; msg="${pair#*:}"
  yqs err "select(.kind == \"ConfigMap\" and .metadata.name == \"vault-config-$d.deploy-error\") | .data.ERROR" "$WORK/fx-guards.raw"
  grep -q -- "$msg" <<<"$err" \
    || { gd_ok=1; gd_detail="$gd_detail [$d: no deploy-error ConfigMap saying '$msg']"; }
done
# Hostile values never reach a rendered spec, and the error ConfigMap cannot be forged.
yqs strs 'select(.kind != "ConfigMap") | .. | select(tag == "!!str")' "$WORK/fx-guards.raw"
[ -n "$strs" ] || { gd_ok=1; gd_detail="$gd_detail [no strings extracted — the hostile-value check proves nothing]"; }
grep -qE 'capabilities = \["sudo"\]|\.\./|forged|team-b/' <<<"$strs" \
  && { gd_ok=1; gd_detail="$gd_detail [a hostile value reached a non-ConfigMap object]"; }
yqs forged 'select(.kind == "ConfigMap") | has("spec")' "$WORK/fx-guards.raw"
grep -qx true <<<"$forged" \
  && { gd_ok=1; gd_detail="$gd_detail [an error ConfigMap carries a forged top-level field]"; }
check guards "$gd_ok" "$gd_detail"

# tokenseconds
tsx_ok=0; tsx_detail=""
yqs nonint 'select(.kind == "KubernetesAuthEngineRole") | .spec | to_entries | .[] | select(.key | test("^token(TTL|MaxTTL|Period)$")) | select(.value | tag != "!!int") | .key' "$WORK/all.raw"
[ -z "$nonint" ] || { tsx_ok=1; tsx_detail="$tsx_detail [non-integer token fields: $nonint]"; }
yqs ints 'select(.kind == "KubernetesAuthEngineRole") | .spec.tokenTTL' "$WORK/all.raw"
[ "$(sort -u <<<"$ints")" = 3600 ] || { tsx_ok=1; tsx_detail="$tsx_detail [tokenTTL not plumbed as 3600: '$ints']"; }
if "$HELM" template x "$WORK/noschema/tenant" -n "$NS" -f "$FIXTURES/values-full.yaml" --set-string token.ttl=1h > /dev/null 2>"$WORK/tsx.err"; then
  tsx_ok=1; tsx_detail="$tsx_detail [token.ttl=1h rendered with the schema removed]"
else
  grep -q 'must be an integer number of seconds' "$WORK/tsx.err" || { tsx_ok=1; tsx_detail="$tsx_detail [token.ttl=1h failed without the helper message: $(first "$WORK/tsx.err")]"; }
fi
# The schema on its own, templates stripped.
if "$HELM" template x "$WORK/notpl/tenant" -n "$NS" --set tenant=t --set-string token.ttl=1h > /dev/null 2>"$WORK/tsx.err"; then
  tsx_ok=1; tsx_detail="$tsx_detail [the schema accepted token.ttl=1h]"
fi
"$HELM" template x "$WORK/notpl/tenant" -n "$NS" --set tenant=t --set token.ttl=900 > /dev/null 2>"$WORK/tsx.err" \
  || { tsx_ok=1; tsx_detail="$tsx_detail [the schema refused token.ttl=900: $(first "$WORK/tsx.err")]"; }
check tokenseconds "$tsx_ok" "$tsx_detail"

# tokentype
tt_ok=0; tt_detail=""
yqs rolenames 'select(.kind == "KubernetesAuthEngineRole") | .metadata.name' "$WORK/all.raw"
yqs roletypes 'select(.kind == "KubernetesAuthEngineRole") | .spec.tokenType' "$WORK/all.raw"
nroles="$(lines "$rolenames")"
typed="$(lines "$(grep -x service <<<"$roletypes" || true)")"
[ "$nroles" -gt 0 ] || { tt_ok=1; tt_detail="$tt_detail [no roles rendered]"; }
[ "$typed" = "$nroles" ] || { tt_ok=1; tt_detail="$tt_detail [$typed of $nroles roles pin tokenType service]"; }
if "$HELM" template x "$WORK/noschema/tenant" -n "$NS" -f "$FIXTURES/values-full.yaml" --set token.type=batch > /dev/null 2>"$WORK/tt.err"; then
  tt_ok=1; tt_detail="$tt_detail [batch + period rendered]"
else
  grep -q 'a batch token cannot be renewed' "$WORK/tt.err" || { tt_ok=1; tt_detail="$tt_detail [batch + period failed elsewhere: $(first "$WORK/tt.err")]"; }
fi
"$HELM" template x "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" --set token.type=batch --set token.period=0 > /dev/null 2>"$WORK/tt.err" \
  || { tt_ok=1; tt_detail="$tt_detail [batch without period rejected: $(first "$WORK/tt.err")]"; }
check tokentype "$tt_ok" "$tt_detail"

# namecollide
nc_ok=0; nc_detail=""
# nc_ids <manifest> <ids-out>: sorted identities. On its own line, so a yq failure
# stops the run instead of reading as "no duplicates".
nc_ids() {
  normalize < "$1" > "$1.norm" || { echo "FAIL  infra — yq failed normalizing $1"; exit 1; }
  identities "$1.norm" > "$2" || { echo "FAIL  infra — yq failed listing identities of $1"; exit 1; }
}
for fx in full guards no-optins no-workloads; do
  render all "$FIXTURES/values-$fx.yaml" > "$WORK/nc.yaml" 2>"$WORK/nc.err" || { nc_ok=1; nc_detail="$nc_detail [$fx: render failed]"; continue; }
  nc_ids "$WORK/nc.yaml" "$WORK/nc.ids"
  dups="$(uniq -d "$WORK/nc.ids" | tr '\n' ' ')"
  [ -z "$dups" ] || { nc_ok=1; nc_detail="$nc_detail [$fx: duplicate identities: $dups]"; }
done
cat > "$WORK/coll.yaml" <<'YAML'
tenant: t
serviceAccounts:
  - metadata: {name: api-x, namespace: t-web, annotations: {vault.stakater.com/kv: "true", vault.stakater.com/role: editor}}
  - metadata: {name: x, namespace: t-web-api, annotations: {vault.stakater.com/kv: "true", vault.stakater.com/role: viewer}}
YAML
render all "$WORK/coll.yaml" > "$WORK/coll.out" 2>"$WORK/coll.err" || { nc_ok=1; nc_detail="$nc_detail [collision fixture failed to render: $(first "$WORK/coll.err")]"; }
yqs pnames 'select(.kind == "Policy") | .metadata.name' "$WORK/coll.out"
[ "$(sort -u <<<"$pnames" | grep -c .)" = 2 ] || { nc_ok=1; nc_detail="$nc_detail [t-web/api-x and t-web-api/x: $(tr '\n' ' ' <<<"$pnames")]"; }
# nc_pair <label> <values-a> <values-b>: two tenants' core renders, which both
# land in configNamespace, share no identity. Each must render a Policy, or the
# check passes on an empty render.
nc_pair() {
  local pa pb d
  render core "$2" > "$WORK/nca.yaml" 2>"$WORK/nca.err" || { nc_ok=1; nc_detail="$nc_detail [$1: first render failed: $(first "$WORK/nca.err")]"; return; }
  render core "$3" > "$WORK/ncb.yaml" 2>"$WORK/ncb.err" || { nc_ok=1; nc_detail="$nc_detail [$1: second render failed: $(first "$WORK/ncb.err")]"; return; }
  yqs pa 'select(.kind == "Policy") | .metadata.name' "$WORK/nca.yaml"
  yqs pb 'select(.kind == "Policy") | .metadata.name' "$WORK/ncb.yaml"
  [ -n "$pa" ] && [ -n "$pb" ] || { nc_ok=1; nc_detail="$nc_detail [$1: a render has no Policy — the check proves nothing]"; return; }
  cat "$WORK/nca.yaml" "$WORK/ncb.yaml" > "$WORK/ncab.yaml"
  nc_ids "$WORK/ncab.yaml" "$WORK/ncab.ids"
  d="$(uniq -d "$WORK/ncab.ids" | tr '\n' ' ')"
  [ -z "$d" ] || { nc_ok=1; nc_detail="$nc_detail [$1: two tenants render the same objects: $d]"; }
}
# Across tenants: tenant a, namespace b-c vs tenant a-b, namespace c.
printf 'tenant: a\nserviceAccounts:\n  - metadata: {name: d, namespace: b-c, annotations: {vault.stakater.com/kv: "true", vault.stakater.com/role: editor}}\n' > "$WORK/xa.yaml"
printf 'tenant: a-b\nserviceAccounts:\n  - metadata: {name: d, namespace: c, annotations: {vault.stakater.com/kv: "true", vault.stakater.com/role: editor}}\n' > "$WORK/xb.yaml"
nc_pair "a/b-c vs a-b/c" "$WORK/xa.yaml" "$WORK/xb.yaml"
# Across name families: tenant sso's own Policy for namespace acme and
# ServiceAccount admin vs tenant acme's SSO admin Policy (sso.acme.admin).
printf 'tenant: sso\nserviceAccounts:\n  - metadata: {name: admin, namespace: acme, annotations: {vault.stakater.com/kv: "true", vault.stakater.com/role: editor}}\n' > "$WORK/fa.yaml"
printf 'tenant: acme\nsso: {enabled: true, oidc: {issuerUrl: "https://idp.example"}}\n' > "$WORK/fb.yaml"
nc_pair "sso/acme/admin vs acme SSO admin" "$WORK/fa.yaml" "$WORK/fb.yaml"
check namecollide "$nc_ok" "$nc_detail"

# ssoredirect — both empty forms from a VALUES FILE: `--set x=[]` gives helm
# the string "[]", which would never reach the guard.
so_ok=0; so_detail=""
printf 'sso:\n  allowedRedirectUris: []\n'   > "$WORK/ssor-empty.yaml"
printf 'sso:\n  allowedRedirectUris: null\n' > "$WORK/ssor-null.yaml"
for form in empty null; do
  if render core "$FIXTURES/values-full.yaml" -f "$WORK/ssor-$form.yaml" > "$WORK/ssor.out" 2>&1; then
    so_ok=1; so_detail="$so_detail [allowedRedirectUris=$form rendered]"; continue
  fi
  grep -q 'requires at least one entry in sso.allowedRedirectUris' "$WORK/ssor.out" \
    || { so_ok=1; so_detail="$so_detail [$form failed elsewhere: $(first "$WORK/ssor.out")]"; }
done
yqs uris 'select(.kind == "JWTOIDCAuthEngineRole") | .spec.allowedRedirectURIs[]' "$WORK/all.raw"
want_uris="$(printf '%s\n' http://localhost:8250/oidc/callback https://vault.example.com/ui/vault/auth/team-a/oidc/sso/oidc/callback)"
[ "$(sort -u <<<"$uris")" = "$want_uris" ] || { so_ok=1; so_detail="$so_detail [redirect URIs rendered '$(sort -u <<<"$uris" | tr '\n' ' ')']"; }
check ssoredirect "$so_ok" "$so_detail"

# ssorootlist
sl_ok=0; sl_detail=""
n_sso=0
yqs ssopols 'select(.kind == "Policy" and (.metadata.name | test("^sso[.]"))) | .metadata.name' "$WORK/all.raw"
for p in $ssopols; do
  n_sso=$((n_sso + 1))
  yqs body "select(.kind == \"Policy\" and .metadata.name == \"$p\") | .spec.policy" "$WORK/all.raw"
  grep -q 'path "team-a/kv/metadata" { capabilities = \["list"\] }' <<<"$body" || { sl_ok=1; sl_detail="$sl_detail [$p cannot list the kv root]"; }
done
[ "$n_sso" -eq 4 ] || { sl_ok=1; sl_detail="$sl_detail [expected 4 SSO role policies, found $n_sso]"; }
check ssorootlist "$sl_ok" "$sl_detail"

# ssoroles — every bad role fails with its own message; the default roles render.
st_ok=0; st_detail=""
printf 'sso:\n  roles: [fallback]\nroleCaps:\n  fallback: %s\n' "'[\"read\"]'" > "$WORK/sst-fallback.yaml"
printf 'sso:\n  roles: [Bad.Role]\n' > "$WORK/sst-dns.yaml"
printf 'sso:\n  tenantRoleMapping:\n    fallback: viewer\n' > "$WORK/sst-mapping.yaml"
for c in "fallback:is reserved" "dns:is not a DNS label" "mapping:a fallback role binds no group"; do
  name="${c%%:*}"; msg="${c#*:}"
  if render core "$FIXTURES/values-full.yaml" -f "$WORK/sst-$name.yaml" > /dev/null 2>"$WORK/sst.err"; then
    st_ok=1; st_detail="$st_detail [$name rendered]"
  else
    grep -q -- "$msg" "$WORK/sst.err" || { st_ok=1; st_detail="$st_detail [$name failed elsewhere: $(first "$WORK/sst.err")]"; }
  fi
done
yqs ssoroles 'select(.kind == "JWTOIDCAuthEngineRole") | .metadata.name' "$WORK/all.raw"
[ "$(lines "$ssoroles")" = 4 ] || { st_ok=1; st_detail="$st_detail [values-full rendered $(lines "$ssoroles") SSO roles, want 4 — the refusals above prove nothing]"; }
check ssoroles "$st_ok" "$st_detail"

# ssobind
sb_ok=0; sb_detail=""
render all "$FIXTURES/values-full.yaml" --set sso.oidc.clientId=mto-vault > "$WORK/sb-custom.yaml" 2>"$WORK/sb.err" \
  || { sb_ok=1; sb_detail="$sb_detail [render with sso.oidc.clientId=mto-vault failed: $(first "$WORK/sb.err")]"; }
for c in "default:$WORK/all.raw:vault" "custom:$WORK/sb-custom.yaml:mto-vault"; do
  name="${c%%:*}"; rest="${c#*:}"; file="${rest%:*}"; aud="${rest##*:}"
  yqs sbroles 'select(.kind == "JWTOIDCAuthEngineRole") | .metadata.name + " " + (.spec.tokenPolicies | join(",")) + " " + .spec.path + " " + (.spec.boundClaims.groups | join(",")) + " " + (.spec.boundClaimsType // "string") + " " + (.spec.boundAudiences | join(","))' "$file"
  [ -n "$sbroles" ] || { sb_ok=1; sb_detail="$sb_detail [$name: no SSO role]"; continue; }
  while read -r rname pols path groups ctype auds; do
    role="${rname##*.}"
    want="$rname team-a/oidc/sso team-a-${role}s string $aud"
    [ "$pols $path $groups $ctype $auds" = "$want" ] || sb_detail="$sb_detail [$name: $rname binds '$pols $path $groups $ctype $auds', want '$want']"
  done <<<"$sbroles"
done
[ -z "$sb_detail" ] || sb_ok=1
check ssobind "$sb_ok" "$sb_detail"

# ssogroups — the bootstrap at install, the tenant chart at render.
sg_ok=0; sg_detail=""
sg_tenant() { # sg_tenant <label> <values YAML> <expect: ok | message>
  printf '%s\n' "$2" > "$WORK/sg-tenant.yaml"
  if render core "$FIXTURES/values-full.yaml" -f "$WORK/sg-tenant.yaml" > /dev/null 2>"$WORK/sg.err"; then
    [ "$3" = ok ] || { sg_ok=1; sg_detail="$sg_detail [tenant chart $1 rendered, want '$3']"; }
  elif [ "$3" = ok ]; then
    sg_ok=1; sg_detail="$sg_detail [tenant chart $1 failed: $(first "$WORK/sg.err")]"
  else
    grep -qF -- "$3" "$WORK/sg.err" || { sg_ok=1; sg_detail="$sg_detail [tenant chart $1 failed elsewhere: $(first "$WORK/sg.err")]"; }
  fi
}
sg_tenant platform 'sso: {tenantRoleMapping: {admin: {pattern: platform-admins}}}' 'must contain {tenant} exactly once'
sg_tenant string-map 'sso: {tenantRoleMapping: {admin: "ops-{tenant}-admins"}}' 'must be {} (the default pattern) or {pattern:'
sg_tenant one-group 'sso: {tenantGroupTemplate: "{tenant}"}' 'bind the same group'
sg_tenant ttl 'token: {ttl: 7200, maxTTL: 3600}' 'is over token.maxTTL'
sg_tenant mapped 'sso: {tenantRoleMapping: {admin: {pattern: "ops-{tenant}"}}}' ok
sg_tenant roles-empty 'sso: {roles: []}' 'with an empty sso.roles'
sg_boot() { # sg_boot <label> <tenantValues YAML> <expect: ok | message | schema:<rule>:<a.b>> [chart dir] [other values YAML]
  printf 'tenantValues: %s\n' "$2" > "$WORK/sg-boot.yaml"
  [ -z "${5:-}" ] || printf '%s\n' "$5" >> "$WORK/sg-boot.yaml"
  if "$HELM" template b "${4:-$BOOTSTRAP}" -n "$NS" -f "$WORK/sg-boot.yaml" > /dev/null 2>"$WORK/sg.err"; then
    [ "$3" = ok ] || { sg_ok=1; sg_detail="$sg_detail [bootstrap $1 rendered, want '$3']"; }
  elif [ "$3" = ok ]; then
    sg_ok=1; sg_detail="$sg_detail [bootstrap $1 failed: $(first "$WORK/sg.err")]"
  else
    case $3 in
      schema:*) local r=${3#schema:}; schema_rule "$WORK/sg.err" "${r#*:}" "${r%%:*}" ;;
      *) grep -qF -- "$3" "$WORK/sg.err" ;;
    esac || { sg_ok=1; sg_detail="$sg_detail [bootstrap $1 failed elsewhere: $(first "$WORK/sg.err")]"; }
  fi
}
rc='roleCaps: {read: "[\"read\"]", a: "[\"read\"]", b: "[\"read\"]"}'
sg_boot default '{}' ok
sg_boot dotted "{$rc, sso: {roles: [read, audit-read], tenantGroupTemplate: \"{tenant}.{role}\"}}" ok
sg_boot prefixes '{sso: {tenantGroupTemplate: "grp-{tenant}-{role}", tenantRoleMapping: {admin: {pattern: "ops-{tenant}"}}}}' ok
sg_boot empty-entry '{sso: {tenantRoleMapping: {admin: {}, fallback: deny}}}' ok
sg_boot no-overlap "{$rc, sso: {roles: [a, b], tenantRoleMapping: {a: {pattern: \"{tenant}_x-s\"}, b: {pattern: \"h_{tenant}_y\"}}}}" ok
sg_boot platform '{sso: {tenantRoleMapping: {admin: {pattern: platform-admins}}}}' 'must contain {tenant} exactly once'
sg_boot twice '{sso: {tenantGroupTemplate: "{tenant}-{tenant}-{role}"}}' 'must contain {tenant} exactly once'
# One role: no pair for the collision check, so only the {tenant} rule
# refuses these.
sg_boot platform-one '{sso: {roles: [admin], tenantRoleMapping: {admin: {pattern: platform-admins}}}}' 'must contain {tenant} exactly once'
sg_boot twice-one '{sso: {roles: [admin], tenantGroupTemplate: "{tenant}-{tenant}-{role}"}}' 'must contain {tenant} exactly once'
# A newline folds to a space in the admission policies' YAML: the CEL would
# expect another group than the tenant chart binds.
sg_boot newline '{sso: {tenantRoleMapping: {admin: {pattern: "{tenant}-\nadmins"}}}}' 'holds a control character'
sg_boot tab '{sso: {tenantRoleMapping: {admin: {pattern: "{tenant}-\tadmins"}}}}' 'holds a control character'
# ssoCollision: S2 = E S1 (read before audit-read), S1 = E S2 (audit-read
# first), a longer prefix, the overlap across two tenants, the overlap within
# one, and one pattern for every role.
sg_boot suffix-1 "{$rc, sso: {roles: [read, audit-read]}}" 'can give two tenants the same group, for example x-audit-reads'
sg_boot suffix-2 "{$rc, sso: {roles: [audit-read, read]}}" 'can give two tenants the same group, for example x-audit-reads'
sg_boot prefix '{sso: {tenantRoleMapping: {admin: {pattern: "ops-{tenant}"}}}}' 'can give two tenants the same group, for example ops-x-editors'
sg_boot overlap "{$rc, sso: {roles: [a, b], tenantRoleMapping: {a: {pattern: \"{tenant}_x-s\"}, b: {pattern: \"h_{tenant}-s\"}}}}" 'can give two tenants the same group, for example h_x-s'
sg_boot overlap-one "{$rc, sso: {roles: [a, b], tenantRoleMapping: {a: {pattern: \"{tenant}_a-s\"}, b: {pattern: \"a_{tenant}-s\"}}}}" 'give one tenant the same group for both roles, for example a_a-s'
sg_boot one-group '{sso: {tenantGroupTemplate: "{tenant}"}}' 'give one tenant the same group for both roles'
sg_boot string-map '{sso: {tenantRoleMapping: {admin: "ops-{tenant}-admins"}}}' 'must be {} (the default pattern) or {pattern:'
sg_boot empty-pattern '{sso: {tenantRoleMapping: {admin: {pattern: ""}}}}' 'must be {} (the default pattern) or {pattern:'
sg_boot misspelt-entry '{sso: {tenantRoleMapping: {admin: {patern: "x-{tenant}"}}}}' 'must be {} (the default pattern) or {pattern:'
sg_boot unknown-role '{sso: {tenantRoleMapping: {ops: {pattern: "ops-{tenant}"}}}}' 'maps a role that is not in sso.roles'
sg_boot fallback-allow '{sso: {tenantRoleMapping: {fallback: allow}}}' 'It must be "deny"'
sg_boot role-fallback '{roleCaps: {fallback: "[\"read\"]"}, sso: {roles: [admin, fallback]}}' 'entry "fallback" is reserved'
sg_boot role-twice '{sso: {roles: [admin, admin]}}' 'lists "admin" twice' "$WORK/noschema/boot"
sg_boot role-twice-schema '{sso: {roles: [admin, admin]}}' 'schema:unique:tenantValues.sso.roles'
sg_boot role-no-caps '{sso: {roles: [admin, ops]}}' 'has no roleCaps entry'
sg_boot caps-sudo '{roleCaps: {admin: "[\"read\", \"sudo\"]"}}' 'grants sudo'
sg_boot caps-shape '{roleCaps: {admin: "read, list"}}' 'is not one capability list'
sg_boot empty-template '{sso: {tenantGroupTemplate: ""}}' 'is set but empty'
sg_boot dquote '{sso: {tenantGroupTemplate: "{tenant}-\"{role}"}}' 'contains a quote, a double quote or a backslash'
sg_boot badrole '{sso: {roles: [Admin]}}' 'is not a DNS label'
# With a roleCaps entry, so only the DNS-label guard refuses it.
sg_boot badrole-caps '{roleCaps: {Admin: "[\"read\"]"}, sso: {roles: [Admin]}}' 'is not a DNS label'
sg_boot roles-string '{sso: {roles: admin}}' 'must be a list of role names' "$WORK/noschema/boot"
# With SSO on only: with SSO off no tenant gets a role anyway.
sg_boot roles-empty '{sso: {roles: []}}' 'tenantValues.sso.roles is empty' "$BOOTSTRAP" 'parent: {sso: {enabled: true, issuerUrl: "https://idp.example.com"}}'
sg_boot roles-empty-sso-off '{sso: {roles: []}}' ok
check ssogroups "$sg_ok" "$sg_detail"

# ssotoken — one table of SSO token ttl and maxTTL, through the tenant chart
# at render and the bootstrap at install (a side not set is the tenant
# chart's default): both refuse what Vault refuses, a role whose ttl is over
# its max ttl, and a value Vault can't read.
sx_ok=0; sx_detail=""
while IFS='|' read -r label vals want; do
  [ -n "$label" ] || continue
  printf 'sso: {enabled: true}\nssoToken: %s\n' "$vals" > "$WORK/sx-t.yaml"
  printf 'tenantValues: {ssoToken: %s}\n' "$vals" > "$WORK/sx-b.yaml"
  for side in tenant bootstrap; do
    rc=0
    if [ "$side" = tenant ]; then
      render core "$FIXTURES/values-full.yaml" -f "$WORK/sx-t.yaml" > /dev/null 2>"$WORK/sx.err" || rc=$?
    else
      "$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/sx-b.yaml" > /dev/null 2>"$WORK/sx.err" || rc=$?
    fi
    if [ "$rc" = 0 ]; then
      [ "$want" = ok ] || { sx_ok=1; sx_detail="$sx_detail [$side $label rendered, want '$want']"; }
    elif [ "$want" = ok ]; then
      sx_ok=1; sx_detail="$sx_detail [$side $label was refused: $(first "$WORK/sx.err")]"
    else
      grep -qF -- "$want" "$WORK/sx.err" || { sx_ok=1; sx_detail="$sx_detail [$side $label failed elsewhere: $(first "$WORK/sx.err")]"; }
    fi
  done
done <<'TABLE'
two-hours|{ttl: "2h"}|ttl "2h" is over
max-ten-minutes|{maxTTL: "10m"}|ttl "15m" is over
decimal|{ttl: "1.5h"}|ttl "1.5h" is over
minutes-over-an-hour|{ttl: "61m"}|ttl "61m" is over
seconds|{ttl: "90", maxTTL: "1m"}|ttl "90" is over
days|{ttl: "2d", maxTTL: "1d"}|ttl "2d" is over
not-a-duration|{ttl: "soon"}|"soon" is not a duration Vault reads
equal|{ttl: "1h", maxTTL: "1h"}|ok
mixed|{ttl: "1h30m", maxTTL: "2h"}|ok
millis|{ttl: "500ms"}|ok
plus-sign|{ttl: "+20m"}|ok
plus-seconds|{ttl: "+900"}|ok
leading-dot|{ttl: ".5h"}|ok
trailing-dot|{ttl: "1.h"}|ok
greek-mu|{ttl: "1μs"}|ok
plus-over|{ttl: "+2h"}|ttl "+2h" is over
max-vault-default|{ttl: "2h", maxTTL: "0"}|ok
ttl-vault-default|{ttl: ""}|ok
TABLE
check ssotoken "$sx_ok" "$sx_detail"

# falsestring — schema kept on: it accepts "false", which is the point
fs_ok=0; fs_detail=""
render all "$FIXTURES/values-full.yaml" --set-string sso.enabled=false --set-string monitoring.enabled=false > "$WORK/fs-false.yaml" 2>"$WORK/fs.err" || { fs_ok=1; fs_detail="$fs_detail [\"false\" did not render: $(first "$WORK/fs.err")]"; }
yqs fson 'select(.kind == "JWTOIDCAuthEngineConfig" or .kind == "JWTOIDCAuthEngineRole" or .kind == "PrometheusRule" or (.kind == "AuthEngineMount" and .spec.type == "oidc")) | .kind' "$WORK/fs-false.yaml"
[ -z "$fson" ] || { fs_ok=1; fs_detail="$fs_detail [the string \"false\" rendered: $(sort -u <<<"$fson" | tr '\n' ' ')]"; }
render all "$FIXTURES/values-full.yaml" --set-string sso.enabled=true --set-string monitoring.enabled=true > "$WORK/fs-true.yaml" 2>"$WORK/fs.err" || { fs_ok=1; fs_detail="$fs_detail [\"true\" did not render: $(first "$WORK/fs.err")]"; }
yqs fsyes 'select(.kind == "JWTOIDCAuthEngineConfig" or .kind == "PrometheusRule") | .kind' "$WORK/fs-true.yaml"
[ "$(sort -u <<<"$fsyes" | tr '\n' ' ')" = "JWTOIDCAuthEngineConfig PrometheusRule " ] || { fs_ok=1; fs_detail="$fs_detail [the string \"true\" did not render SSO and monitoring: '$fsyes']"; }
if "$HELM" template x "$WORK/noschema/tenant" -n "$NS" --set tenant=t --set-string sso.enabled=on --set sso.oidc.issuerUrl=https://idp > /dev/null 2>"$WORK/tg.err"; then
  fs_ok=1; fs_detail="$fs_detail [tenant sso.enabled=on without schema rendered]"
else
  grep -q 'sso.enabled must be true or false' "$WORK/tg.err" || { fs_ok=1; fs_detail="$fs_detail [sso.enabled=on was not refused by the guard: $(first "$WORK/tg.err")]"; }
fi
if "$HELM" template x "$WORK/notpl/tenant" -n "$NS" --set tenant=t --set-string sso.enabled=on > /dev/null 2>"$WORK/tg.err"; then
  fs_ok=1; fs_detail="$fs_detail [the schema accepted sso.enabled=on]"
fi
check falsestring "$fs_ok" "$fs_detail"

# alertlabels
al_ok=0; al_detail=""
yqs expr 'select(.kind == "PrometheusRule") | .spec.groups[].rules[].expr' "$WORK/all.raw"
[ -n "$expr" ] || { al_ok=1; al_detail="$al_detail [values-full rendered no alert — the check proves nothing]"; }
used="$(grep -oE '[a-z_]+ *=~? *"' <<<"$expr" | sed -E 's/ *=~? *"//' | sort -u | tr '\n' ' ')"
[ "$used" = "condition namespace status " ] || { al_ok=1; al_detail="$al_detail [the alert selects labels '$used'; ESO exports only name, namespace, condition, status]"; }
grep -q 'namespace=~"team-a-dev|team-a-tools"' <<<"$expr" || { al_ok=1; al_detail="$al_detail [the alert does not select the tenant's namespaces: $expr]"; }
check alertlabels "$al_ok" "$al_detail"

# contract
ct_ok=0; ct_detail=""
HELM="$HELM" YQ="$YQ" "$REPO_ROOT/hack/contract.sh" "$CHART" > "$WORK/contract.txt" 2>"$WORK/contract.err" \
  || { echo "FAIL  infra — hack/contract.sh failed: $(first "$WORK/contract.err")"; exit 1; }
[ "$(lines "$(cat "$WORK/contract.txt")")" -ge 20 ] || { ct_ok=1; ct_detail="$ct_detail [the contract has $(lines "$(cat "$WORK/contract.txt")") lines — the check proves nothing]"; }
grep -v '^#' "$REPO_ROOT/hack/enterprise-contract.txt" | grep . | sort -u > "$WORK/ent-contract.txt"
{ comm -23 "$WORK/ent-contract.txt" "$WORK/contract.txt" | sed 's/^/- /'
  comm -13 "$WORK/ent-contract.txt" "$WORK/contract.txt" | sed 's/^/+ /'; } | sort > "$WORK/delta.real"
# An empty delta is the goal state: grep finding no line must not end the run.
{ grep -v '^#' "$REPO_ROOT/hack/contract-delta.txt" || true; } | sed 's/  #.*$//' | { grep . || true; } | sort > "$WORK/delta.want"
if ! diff "$WORK/delta.want" "$WORK/delta.real" > "$WORK/delta.diff"; then
  ct_ok=1
  ct_detail="$ct_detail [the contract drifted from Enterprise beyond hack/contract-delta.txt: $(grep -E '^[<>]' "$WORK/delta.diff" | sed -e 's/^< /listed but not real: /' -e 's/^> /real but not listed: /' | tr '\n' '|')]"
fi
check contract "$ct_ok" "$ct_detail"

# ─── The parent gotemplate, through a shim chart ─────────────────────────────
mkdir -p "$WORK/shim/templates" "$WORK/shim/files"
cp "$BOOTSTRAP/files/parent-gotemplate.tpl" "$WORK/shim/files/"
printf 'apiVersion: v2\nname: shim\nversion: 0.0.1\n' > "$WORK/shim/Chart.yaml"
printf '{{ tpl ($.Files.Get "files/parent-gotemplate.tpl") (dict "parameters" .Values.parameters) }}\n' > "$WORK/shim/templates/render.yaml"
# The parameters are the bootstrap's own: read from its rendered parent
# Template (rendered at setup), so a parameter renamed on one side cannot pass
# here.
"$YQ" e -N "select(.kind == \"Template\" and .metadata.name == \"$P-parent\")
         | {\"parameters\": (.spec.parameters | map(select(has(\"value\"))) | map({\"key\": .name, \"value\": .value}) | from_entries)}" \
  "$WORK/boot-default.yaml" > "$WORK/shim/values.yaml" 2>"$WORK/yq.err" \
  || { echo "FAIL  setup — no parent Template parameters: $(first "$WORK/yq.err")"; exit 1; }
grep -q 'reservedNames' "$WORK/shim/values.yaml" \
  || { echo "FAIL  setup — the parent Template has no reservedNames parameter"; exit 1; }
cat > "$WORK/emit-tenants.yaml" <<'EOF'
parameters:
  vcoRole: vco-role
  vcoServiceAccount: vco-sa
  tenants:
    - metadata: { name: team-a }
    - metadata: { name: team-b }
    # no labelled namespace -> kv mount, no child TI
    - metadata: { name: empty-tenant }
    # all digits: a valid DNS label that YAML reads as a number unless quoted
    - metadata: { name: "1234" }
    # skipped and reported: the shared name, Vault's own paths, VCO's login
    # mount, a platform mount from parent.reservedPaths, not a DNS label, and
    # a DNS label of 64 characters, and one of 30 (over the 29-char budget of
    # the child TI name mto-extension-vault-community-<tenant>.eso)
    - metadata: { name: shared }
    - metadata: { name: sys }
    - metadata: { name: auth }
    - metadata: { name: identity }
    - metadata: { name: cubbyhole }
    - metadata: { name: agent-registry }
    - metadata: { name: token }
    - metadata: { name: kubernetes }
    - metadata: { name: secret }
    - metadata: { name: has.dot }
    - metadata: { name: tenant-name-of-sixty-four-characters-which-is-one-over-the-cap-x }
    - metadata: { name: tenant-name-of-thirty-chars-xy }
    # 29 characters: the longest name that renders
    - metadata: { name: tenant-name-of-twenty-nine-xy }
  # The gate counts namespaces carrying tenantLabelKey. The unlabelled and
  # foreign-labelled entries prove the filter is not counting the whole list.
  tenantNamespaces:
    - metadata: { name: team-a-dev, labels: { stakater.com/tenant: team-a } }
    - metadata: { name: team-b-dev, labels: { stakater.com/tenant: team-b } }
    - metadata: { name: n1234-dev, labels: { stakater.com/tenant: "1234" } }
    - metadata: { name: shared-dev, labels: { stakater.com/tenant: shared } }
    - metadata: { name: sys-dev, labels: { stakater.com/tenant: sys } }
    - metadata: { name: kubernetes-dev, labels: { stakater.com/tenant: kubernetes } }
    - metadata: { name: has-dot-dev, labels: { stakater.com/tenant: has.dot } }
    - metadata: { name: no-label-ns }
    - metadata: { name: someone-elses-ns, labels: { stakater.com/tenant: other-tenant } }
EOF
emit() { # emit <eso> [extra helm args] -> rendered parent output
  local eso="$1"; shift
  "$HELM" template shim "$WORK/shim" -f "$WORK/emit-tenants.yaml" --set "parameters.eso=$eso" "$@"
}
for eso in enabled disabled; do
  emit "$eso" > "$WORK/emit-$eso.yaml" 2>"$WORK/emit.err" \
    || { echo "FAIL  setup — the parent did not render with eso=$eso: $(first "$WORK/emit.err")"; exit 1; }
done

# typeprobe — every scalar the tenant chart and the parent render from a
# value keeps its type when the value is a string YAML reads as a number: a
# base render with plain strings, and a probe with "123" (and "0" for the
# refresh interval, "#123" for a slice key), must agree on the type of every
# field both have, and no map key may be a number. Unquoted, each would
# install and then fail every tenant at apply (C.21).
tp_ok=0; tp_detail=""
tp_leaves() { # tp_leaves <manifest>: "<kind>/<name> <path> <tag>" per scalar
  "$YQ" e -N '. as $d | .. | select(tag != "!!map" and tag != "!!seq") | $d.kind + "/" + ($d.metadata.name // "") + "	" + (path | join(".")) + "	" + tag' "$1"
}
tp_compare() { # tp_compare <label> <base manifest> <probe manifest> <fewest fields to compare>
  local n bad keys
  tp_leaves "$2" | sort > "$WORK/tp-base" || { echo "FAIL  infra — yq failed on $2"; exit 1; }
  tp_leaves "$3" | sort > "$WORK/tp-probe" || { echo "FAIL  infra — yq failed on $3"; exit 1; }
  # Join on "<kind>/<name> <path>": the fields both renders have.
  awk -F'\t' 'NR == FNR { b[$1 "\t" $2] = $3; next } ($1 "\t" $2) in b { n++; if (b[$1 "\t" $2] != $3) print $1 " " $2 ": " b[$1 "\t" $2] " -> " $3 } END { print "compared " n+0 > "/dev/stderr" }' \
    "$WORK/tp-base" "$WORK/tp-probe" > "$WORK/tp-bad" 2>"$WORK/tp-n"
  n=$(sed -n 's/^compared //p' "$WORK/tp-n")
  [ "${n:-0}" -ge "$4" ] || { tp_ok=1; tp_detail="$tp_detail [$1: only ${n:-0} fields compared, want $4 or more — the check proves nothing]"; }
  bad=$(head -5 "$WORK/tp-bad" | tr '\n' '|')
  [ -z "$bad" ] || { tp_ok=1; tp_detail="$tp_detail [$1: a field changed its type: $bad]"; }
  keys=$("$YQ" e -N '. as $d | .. | select(tag == "!!map") | keys | .[] | select(tag != "!!str") | $d.kind + "/" + $d.metadata.name + " key " + (. | tostring) + " " + tag' "$3") \
    || { echo "FAIL  infra — yq failed on $3"; exit 1; }
  [ -z "$keys" ] || { tp_ok=1; tp_detail="$tp_detail [$1: a map key is not a string: $(head -3 <<<"$keys" | tr '\n' '|')]"; }
}
tp_set() { # tp_set <value>: the probed tenant chart values, each set to <value>
  printf -- '--set-string vco.role=%s --set-string vco.authPath=%s --set-string vco.serviceAccount=%s --set-string kubernetesAuth.kubernetesHost=%s --set-string kubernetesAuth.tokenReviewerServiceAccount=%s --set-string kubernetesAuth.name=%s --set-string sso.mount.name=%s --set-string tenantLabelKey=%s --set-string sso.oidc.clientSecretRef.key=%s --set-string vaultServer=%s' "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1"
}
sed 's/"db-creds#password"/"db-creds#123"/' "$FIXTURES/values-full.yaml" > "$WORK/tp-fixture.yaml"
grep -q '"db-creds#123"' "$WORK/tp-fixture.yaml" || { echo "FAIL  infra — the probe fixture has no slice key to probe"; exit 1; }
# shellcheck disable=SC2046
render all "$FIXTURES/values-full.yaml" $(tp_set plain-x) --set-string externalSecretRefreshInterval=1h > "$WORK/tp-base.yaml" 2>"$WORK/tp.err" \
  || { tp_ok=1; tp_detail="$tp_detail [the base render failed: $(first "$WORK/tp.err")]"; }
# shellcheck disable=SC2046
render all "$WORK/tp-fixture.yaml" $(tp_set 123) --set-string externalSecretRefreshInterval=0 > "$WORK/tp-probe.yaml" 2>"$WORK/tp.err" \
  || { tp_ok=1; tp_detail="$tp_detail [the probe render failed: $(first "$WORK/tp.err")]"; }
# The probe reaches the fields it names: a check that changes nothing proves nothing.
yqs tp_role 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .spec.authentication.role' "$WORK/tp-probe.yaml"
[ "$(sort -u <<<"$tp_role")" = 123 ] || { tp_ok=1; tp_detail="$tp_detail [the probe's vco.role is '$(sort -u <<<"$tp_role" | tr '\n' ' ')', want 123]"; }
yqs tp_slice 'select(.kind == "ExternalSecret") | .spec.data[]? | .secretKey' "$WORK/tp-probe.yaml"
grep -qx 123 <<<"$tp_slice" || { tp_ok=1; tp_detail="$tp_detail [no ExternalSecret carries the probe's slice key 123]"; }
tp_compare "tenant chart" "$WORK/tp-base.yaml" "$WORK/tp-probe.yaml" 700
emit enabled --set-string parameters.vcoAuthPath=plain-x --set-string parameters.vcoRole=plain-x \
  --set-string parameters.vcoServiceAccount=plain-x > "$WORK/tp-pbase.yaml" 2>"$WORK/tp.err" \
  || { tp_ok=1; tp_detail="$tp_detail [the parent's base render failed: $(first "$WORK/tp.err")]"; }
# The namespaces carry the probe's label key too, so the child TIs (and their
# namespaceSelector) render.
sed 's#stakater.com/tenant: #"123": #' "$WORK/emit-tenants.yaml" > "$WORK/tp-tenants.yaml"
emit enabled -f "$WORK/tp-tenants.yaml" --set-string parameters.vcoAuthPath=123 --set-string parameters.vcoRole=123 \
  --set-string parameters.vcoServiceAccount=123 --set-string parameters.tenantLabelKey=123 > "$WORK/tp-pprobe.yaml" 2>"$WORK/tp.err" \
  || { tp_ok=1; tp_detail="$tp_detail [the parent's probe render failed: $(first "$WORK/tp.err")]"; }
yqs tp_prole 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .spec.authentication.role' "$WORK/tp-pprobe.yaml"
[ "$(sort -u <<<"$tp_prole")" = 123 ] || { tp_ok=1; tp_detail="$tp_detail [the parent probe's vcoRole is '$(sort -u <<<"$tp_prole" | tr '\n' ' ')', want 123]"; }
yqs tp_ptis 'select(.kind == "TemplateInstance") | .metadata.name' "$WORK/tp-pprobe.yaml"
[ "$(lines "$tp_ptis")" -ge 2 ] || { tp_ok=1; tp_detail="$tp_detail [the parent probe renders $(lines "$tp_ptis") TemplateInstances: their namespaceSelector is not probed]"; }
tp_compare parent "$WORK/tp-pbase.yaml" "$WORK/tp-pprobe.yaml" 80
check typeprobe "$tp_ok" "$tp_detail"

# emission
em_ok=0; em_detail=""
for em in "enabled:$P-team-a->$P $P-team-a.eso->$P-eso $P-team-b->$P $P-team-b.eso->$P-eso $P-1234->$P $P-1234.eso->$P-eso" \
          "disabled:$P-team-a->$P $P-team-b->$P $P-1234->$P"; do
  eso="${em%%:*}"; want="$(printf '%s\n' ${em#*:} | sort | tr '\n' ' ')"
  yqs gotti 'select(.kind == "TemplateInstance") | .metadata.name + "->" + .spec.templateRef.name' "$WORK/emit-$eso.yaml"
  got="$(sort <<<"$gotti" | tr '\n' ' ')"
  [ "$got" = "$want" ] || { em_ok=1; em_detail="$em_detail [eso=$eso: want $want got $got]"; }
done
yqs roster 'select(.kind == "TemplateInstance") | .spec.parameters[] | select(.name == "knownTenants") | .value' "$WORK/emit-enabled.yaml"
[ "$(sort -u <<<"$roster")" = "team-a,team-b,1234" ] || { em_ok=1; em_detail="$em_detail [knownTenants roster: want team-a,team-b,1234 got '$(sort -u <<<"$roster" | tr '\n' ' ')']"; }
check emission "$em_ok" "$em_detail"

# reserved
rs_ok=0; rs_detail=""
yqs skipped "select(.kind == \"ConfigMap\" and .metadata.name == \"$P-skipped-tenants\") | .data | keys | .[]" "$WORK/emit-enabled.yaml"
want_skipped="agent-registry auth cubbyhole has.dot identity kubernetes secret shared sys tenant-name-of-sixty-four-characters-which-is-one-over-the-cap-x tenant-name-of-thirty-chars-xy token "
[ "$(sort <<<"$skipped" | tr '\n' ' ')" = "$want_skipped" ] || { rs_ok=1; rs_detail="$rs_detail [skipped-tenants lists '$(sort <<<"$skipped" | tr '\n' ' ')', want $want_skipped]"; }
yqs why "select(.kind == \"ConfigMap\" and .metadata.name == \"$P-skipped-tenants\") | .data.kubernetes" "$WORK/emit-enabled.yaml"
grep -q 'Vault refuses a mount nested under another' <<<"$why" || { rs_ok=1; rs_detail="$rs_detail [the reason for kubernetes does not name the nesting: '$why']"; }
yqs why30 "select(.kind == \"ConfigMap\" and .metadata.name == \"$P-skipped-tenants\") | .data.\"tenant-name-of-thirty-chars-xy\"" "$WORK/emit-enabled.yaml"
grep -q 'over 29' <<<"$why30" || { rs_ok=1; rs_detail="$rs_detail [the reason for a 30-character name does not name the budget: '$why30']"; }
[ "${#want_skipped}" -gt 0 ] && [ "$(printf 'tenant-name-of-thirty-chars-xy' | wc -c | tr -d ' ')" = 30 ] && [ "$(printf 'tenant-name-of-twenty-nine-xy' | wc -c | tr -d ' ')" = 29 ] \
  || { rs_ok=1; rs_detail="$rs_detail [the fixture names are not 30 and 29 characters]"; }
# A skipped name renders nothing at all: no mount, no TI, no label value.
yqs mnames 'select(.kind == "SecretEngineMount" or .kind == "TemplateInstance") | .kind + "/" + .metadata.name' "$WORK/emit-enabled.yaml"
for r in sys auth identity cubbyhole agent-registry token kubernetes secret has.dot; do
  grep -qxE "SecretEngineMount/$r-kv|TemplateInstance/$P-$r([.]eso)?" <<<"$mnames" \
    && { rs_ok=1; rs_detail="$rs_detail [reserved name $r rendered]"; }
done
grep -qxE "TemplateInstance/$P-shared([.]eso)?" <<<"$mnames" && { rs_ok=1; rs_detail="$rs_detail [the shared name got a child TI]"; }
# The list follows its inputs: another VCO login mount and another
# reservedPaths entry are reserved; the defaults then are not.
"$HELM" template b "$BOOTSTRAP" -n "$NS" --set vco.authPath=k8s-admin --set 'parent.reservedPaths={vaultadmin}' > "$WORK/boot-res.yaml" 2>"$WORK/boot.err" \
  || { rs_ok=1; rs_detail="$rs_detail [bootstrap with another authPath failed: $(first "$WORK/boot.err")]"; }
yqs resnames "select(.kind == \"Template\" and .metadata.name == \"$P-parent\") | .spec.parameters[] | select(.name == \"reservedNames\") | .value" "$WORK/boot-res.yaml"
for want in k8s-admin vaultadmin token sys shared; do
  grep -qE "(^|,)$want(,|\$)" <<<"$resnames" || { rs_ok=1; rs_detail="$rs_detail [$want missing from reservedNames '$resnames']"; }
done
grep -qE '(^|,)(kubernetes|secret)(,|$)' <<<"$resnames" && { rs_ok=1; rs_detail="$rs_detail [a default stayed reserved after it was replaced: '$resnames']"; }
if "$HELM" template b "$WORK/noschema/boot" -n "$NS" --set 'parent.reservedPaths={secret/}' > /dev/null 2>"$WORK/boot.err"; then
  rs_ok=1; rs_detail="$rs_detail [a reservedPaths entry with a slash was accepted]"
else
  grep -q 'is not a DNS label' "$WORK/boot.err" || { rs_ok=1; rs_detail="$rs_detail [secret/ failed elsewhere: $(first "$WORK/boot.err")]"; }
fi
check reserved "$rs_ok" "$rs_detail"

# parentmounts
pm_ok=0; pm_detail=""
yqs pkinds 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .kind + "/" + .metadata.name + " " + .spec.path + "/" + .spec.name' "$WORK/emit-enabled.yaml"
want_pm="$(printf '%s\n' "SecretEngineMount/shared-kv shared/kv" \
  "SecretEngineMount/team-a-kv team-a/kv" "SecretEngineMount/team-b-kv team-b/kv" \
  "SecretEngineMount/empty-tenant-kv empty-tenant/kv" "SecretEngineMount/1234-kv 1234/kv" \
  "SecretEngineMount/tenant-name-of-twenty-nine-xy-kv tenant-name-of-twenty-nine-xy/kv" | sort | tr '\n' ' ')"
[ "$(sort <<<"$pkinds" | tr '\n' ' ')" = "$want_pm" ] || { pm_ok=1; pm_detail="$pm_detail [parent VCO objects: want $want_pm got $(sort <<<"$pkinds" | tr '\n' ' ')]"; }
yqs pmtypes 'select(.kind == "SecretEngineMount") | .spec.type + "/" + .spec.options.version' "$WORK/emit-enabled.yaml"
[ "$(sort -u <<<"$pmtypes")" = "kv/2" ] || { pm_ok=1; pm_detail="$pm_detail [a secrets mount is not kv version 2: $(sort -u <<<"$pmtypes" | tr '\n' ' ')]"; }
yqs pmlabels 'select(.kind == "SecretEngineMount" and .metadata.name != "shared-kv") | .metadata.name + "=" + .metadata.labels."stakater.com/tenant"' "$WORK/emit-enabled.yaml"
for t in team-a team-b empty-tenant 1234 tenant-name-of-twenty-nine-xy; do
  grep -qx "$t-kv=$t" <<<"$pmlabels" || { pm_ok=1; pm_detail="$pm_detail [$t-kv does not carry its tenant label]"; }
done
check parentmounts "$pm_ok" "$pm_detail"

# notargetns — every render this harness makes: tenant chart, parent and bootstrap
nt_ok=0; nt_detail=""
for f in "$WORK"/emit-*.yaml "$WORK/boot-default.yaml" "$WORK"/*.raw; do
  yqs ns 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1" and .kind == "Namespace") | .metadata.name' "$f"
  [ -z "$ns" ] || { nt_ok=1; nt_detail="$nt_detail [$(basename "$f") renders a Namespace CR: $ns]"; }
  yqs tns '.. | select(has("targetNamespace")) | .targetNamespace' "$f"
  [ -z "$tns" ] || { nt_ok=1; nt_detail="$nt_detail [$(basename "$f") renders a targetNamespace: $(tr '\n' ' ' <<<"$tns")]"; }
  yqs vns 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .spec.authentication | select(has("namespace")) | .namespace' "$f"
  [ -z "$vns" ] || { nt_ok=1; nt_detail="$nt_detail [$(basename "$f") renders a Vault login namespace: $vns]"; }
done
yqs pauth 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .spec.authentication | to_json(0)' "$WORK/emit-enabled.yaml"
[ "$(sort -u <<<"$pauth" | grep -c .)" = 1 ] || { nt_ok=1; nt_detail="$nt_detail [the parent's CRs log in more than one way: $(sort -u <<<"$pauth" | tr '\n' ' ')]"; }
grep -q '"role":"vco-role"' <<<"$pauth" && grep -q '"name":"vco-sa"' <<<"$pauth" \
  || { nt_ok=1; nt_detail="$nt_detail [role and serviceAccount not in their own fields: $pauth]"; }
if "$HELM" template b "$BOOTSTRAP" -n "$NS" --set vco.namespace=org > /dev/null 2>"$WORK/nt.err"; then
  nt_ok=1; nt_detail="$nt_detail [the bootstrap accepted vco.namespace]"
else
  schema_rule "$WORK/nt.err" vco additional namespace \
    || { nt_ok=1; nt_detail="$nt_detail [the bootstrap's vco.namespace failed elsewhere: $(first "$WORK/nt.err")]"; }
fi
if render core "$FIXTURES/values-full.yaml" --set vco.namespace=org > /dev/null 2>"$WORK/nt.err"; then
  nt_ok=1; nt_detail="$nt_detail [the tenant chart accepted vco.namespace]"
else
  grep -q 'Vault Community Edition has no namespaces' "$WORK/nt.err" || { nt_ok=1; nt_detail="$nt_detail [vco.namespace failed elsewhere: $(first "$WORK/nt.err")]"; }
fi
yqs tauth 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .spec.authentication | to_json(0)' "$WORK/all.raw"
[ "$(sort -u <<<"$tauth" | grep -c .)" = 1 ] || { nt_ok=1; nt_detail="$nt_detail [the tenant chart's CRs log in more than one way: $(sort -u <<<"$tauth" | tr '\n' ' ')]"; }
check notargetns "$nt_ok" "$nt_detail"

# templateset
ts_ok=0; ts_detail=""
for ts in "enabled:$P $P-eso $P-parent" "disabled:$P $P-parent"; do
  eso="${ts%%:*}"; want="$(printf '%s\n' ${ts#*:} | sort | tr '\n' ' ')"
  "$HELM" template b "$BOOTSTRAP" -n "$NS" --set "parent.eso=$eso" > "$WORK/boot-$eso.yaml" 2>"$WORK/boot.err" \
    || { ts_ok=1; ts_detail="$ts_detail [eso=$eso: bootstrap render failed: $(first "$WORK/boot.err")]"; continue; }
  yqs tnames 'select(.kind == "Template") | .metadata.name' "$WORK/boot-$eso.yaml"
  got="$(sort <<<"$tnames" | tr '\n' ' ')"
  [ "$got" = "$want" ] || { ts_ok=1; ts_detail="$ts_detail [eso=$eso: want $want got $got]"; }
  yqs refs 'select(.kind == "TemplateInstance") | .spec.templateRef.name' "$WORK/emit-$eso.yaml"
  [ -n "$refs" ] || { ts_ok=1; ts_detail="$ts_detail [eso=$eso: the parent emitted no templateRef — the check proves nothing]"; }
  for ref in $(sort -u <<<"$refs"); do
    grep -qx "$ref" <(printf '%s\n' $got) || { ts_ok=1; ts_detail="$ts_detail [eso=$eso: parent emits templateRef $ref with no Template]"; }
  done
done
# The extension's Templates allow only configNamespace in targetNamespaces.
yqs tns 'select(.kind == "Template") | .spec.targetNamespaces.explicit.allow.literal | join(",")' "$WORK/boot-enabled.yaml"
[ "$(sort -u <<<"$tns")" = "$NS" ] || { ts_ok=1; ts_detail="$ts_detail [a Template allows another namespace: $(sort -u <<<"$tns" | tr '\n' ' ')]"; }
check templateset "$ts_ok" "$ts_detail"

# rbacgate
rbac_atoms() { # <bootstrap manifest> -> "group/resource verb" atoms of the manager ClusterRole
  "$YQ" e -N "select(.kind == \"ClusterRole\" and .metadata.name == \"$P-manager\") | .rules[] | . as \$r | \$r.apiGroups[] as \$g | \$r.resources[] as \$res | \$r.verbs[] | \$g + \"/\" + \$res + \" \" + ." "$1" | sort -u
}
rg_ok=0; rg_detail=""
rbac_atoms "$WORK/boot-enabled.yaml" > "$WORK/rbac-on"
rbac_atoms "$WORK/boot-disabled.yaml" > "$WORK/rbac-off"
[ -s "$WORK/rbac-on" ] || { rg_ok=1; rg_detail="$rg_detail [no ClusterRole atoms extracted — the check proves nothing]"; }
for kind in secretstores externalsecrets; do
  grep -qx "external-secrets.io/$kind create" "$WORK/rbac-on"  || { rg_ok=1; rg_detail="$rg_detail [$kind create missing with ESO on]"; }
  grep -qx "external-secrets.io/$kind create" "$WORK/rbac-off" && { rg_ok=1; rg_detail="$rg_detail [$kind create present with ESO off]"; }
  for v in get list watch update patch delete; do
    grep -qx "external-secrets.io/$kind $v" "$WORK/rbac-off" || { rg_ok=1; rg_detail="$rg_detail [$kind $v missing with ESO off — TI teardown would wedge]"; }
  done
done
"$HELM" template b "$BOOTSTRAP" -n "$NS" --set tenantValues.monitoring.enabled=true > "$WORK/boot-features.yaml" 2>"$WORK/boot.err" \
  || { rg_ok=1; rg_detail="$rg_detail [bootstrap with features on failed: $(first "$WORK/boot.err")]"; }
rbac_atoms "$WORK/boot-features.yaml" > "$WORK/rbac-features"
for gk in monitoring.coreos.com/prometheusrules; do
  grep -qx "$gk create" "$WORK/rbac-features" || { rg_ok=1; rg_detail="$rg_detail [$gk create missing with its feature on]"; }
  grep -qx "$gk create" "$WORK/rbac-on" && { rg_ok=1; rg_detail="$rg_detail [$gk create present with its feature off]"; }
  grep -qx "$gk delete" "$WORK/rbac-on" || { rg_ok=1; rg_detail="$rg_detail [$gk delete missing with its feature off — teardown would wedge]"; }
done
if "$HELM" template b "$BOOTSTRAP" -n "$NS" --set-string tenantValues.monitoring.enabled=yes > /dev/null 2>"$WORK/boot.err"; then
  rg_ok=1; rg_detail="$rg_detail [tenantValues.monitoring.enabled=yes accepted]"
else
  schema_at "$WORK/boot.err" tenantValues.monitoring.enabled \
    || { rg_ok=1; rg_detail="$rg_detail [tenantValues.monitoring.enabled=yes failed elsewhere: $(first "$WORK/boot.err")]"; }
fi
check rbacgate "$rg_ok" "$rg_detail"

# rbaccover — every redhatcop kind any render emits, lower-cased plural
rc_ok=0; rc_detail=""
{ for f in "$WORK"/emit-enabled.yaml "$WORK"/all.raw; do
    [ -f "$f" ] || continue
    "$YQ" e -N 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .kind' "$f"
  done; } | sort -u > "$WORK/rendered-kinds"
[ -s "$WORK/rendered-kinds" ] || { rc_ok=1; rc_detail="$rc_detail [no redhatcop kinds rendered — the check proves nothing]"; }
yqs cr_list "select(.kind == \"ClusterRole\" and .metadata.name == \"$P-manager\") | .rules[] | select(.apiGroups[] == \"redhatcop.redhat.io\") | .verbs | join(\",\")" "$WORK/boot-enabled.yaml"
[ "$cr_list" = "list" ] || { rc_ok=1; rc_detail="$rc_detail [ClusterRole redhatcop verbs must be exactly list, got '$cr_list']"; }
yqs role_verbs "select(.kind == \"Role\" and .metadata.name == \"$P-manager\") | .rules[] | select(.apiGroups[] == \"redhatcop.redhat.io\") | .verbs | join(\",\")" "$WORK/boot-enabled.yaml"
[ "$role_verbs" = "get,list,watch,create,update,patch,delete" ] || { rc_ok=1; rc_detail="$rc_detail [Role redhatcop verbs: '$role_verbs']"; }
yqs nsres "select(.kind == \"Role\" or .kind == \"ClusterRole\") | .rules[] | select(.apiGroups[] == \"redhatcop.redhat.io\") | .resources[] | select(. == \"namespaces\")" "$WORK/boot-enabled.yaml"
[ -z "$nsres" ] || { rc_ok=1; rc_detail="$rc_detail [the RBAC still grants the VCO Namespace kind]"; }
while read -r kind; do
  plural="$(echo "$kind" | tr 'A-Z' 'a-z')"; case "$plural" in *y) plural="${plural%y}ies";; *) plural="${plural}s";; esac
  for which in ClusterRole Role; do
    yqs res "select(.kind == \"$which\" and .metadata.name == \"$P-manager\") | .rules[] | select(.apiGroups[] == \"redhatcop.redhat.io\") | .resources[]" "$WORK/boot-enabled.yaml"
    grep -qx "$plural" <<<"$res" \
      || { rc_ok=1; rc_detail="$rc_detail [$kind ($plural) rendered but not in the $which]"; }
  done
done < "$WORK/rendered-kinds"
check rbaccover "$rc_ok" "$rc_detail"

# toggles — schema with templates stripped, helpers with the schema removed
tg_ok=0; tg_detail=""
tg_case() { # tg_case <chart-dir-name> <values-arg> <label> <helper message> <schema field>
  local variant
  for variant in noschema notpl; do
    if "$HELM" template x "$WORK/$variant/$1" -n "$NS" $2 > /dev/null 2>"$WORK/tg.err"; then
      tg_ok=1; tg_detail="$tg_detail [$3 accepted with $variant]"
    else
      if [ "$variant" = noschema ]; then grep -qF -- "$4" "$WORK/tg.err"; else schema_at "$WORK/tg.err" "$5"; fi \
        || { tg_ok=1; tg_detail="$tg_detail [$3 with $variant failed elsewhere: $(first "$WORK/tg.err")]"; }
    fi
  done
}
tg_case boot "--set parent.eso=true" "parent.eso=true" 'parent.eso must be "enabled" or "disabled"' parent.eso
tg_case boot "--set parent.sso.enabled=yes" "parent.sso.enabled=yes" 'parent.sso.enabled must be a boolean true or false' parent.sso.enabled
tg_case boot "--set-string sync.mode=on" "sync.mode=on" 'sync.mode must be one of off, revert, strict' sync.mode
for variant in noschema notpl; do
  "$HELM" template x "$WORK/$variant/boot" -n "$NS" --set parent.eso=disabled --set-string parent.sso.enabled=true --set parent.sso.issuerUrl=https://idp > /dev/null 2>"$WORK/tg.err" \
    || { tg_ok=1; tg_detail="$tg_detail [canonical bootstrap values rejected with $variant: $(first "$WORK/tg.err")]"; }
done
check toggles "$tg_ok" "$tg_detail"

# nulltoggle — a toggle set to null, or a key whose toggle is commented out,
# renders what the default renders: Helm deletes a null key before the schema
# sees it, and the helpers then take the chart default, never "off".
nl_ok=0; nl_detail=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  printf '%b\n' "$c" > "$WORK/nl.yaml"
  if "$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/nl.yaml" > "$WORK/nl.out" 2>"$WORK/nl.err"; then
    cmp -s "$WORK/boot-default.yaml" "$WORK/nl.out" \
      || { nl_ok=1; nl_detail="$nl_detail [$c renders other than the default: $({ diff "$WORK/boot-default.yaml" "$WORK/nl.out" || true; } | awk '/^[<>]/ && n < 2 { printf "%s ", $0; n++ }')]"; }
  else
    nl_ok=1; nl_detail="$nl_detail [$c failed: $(first "$WORK/nl.err")]"
  fi
done <<'TABLE'
admission:\n  # enabled: true
admission: {enabled: null}
admission: null
parent: {eso: null}
parent: {sso: {enabled: null}}
sync: {mode: null}
TABLE
# A control: the comparison sees an explicit change.
"$HELM" template b "$BOOTSTRAP" -n "$NS" --set admission.enabled=false > "$WORK/nl.out" 2>"$WORK/nl.err" \
  || { nl_ok=1; nl_detail="$nl_detail [admission.enabled=false failed: $(first "$WORK/nl.err")]"; }
cmp -s "$WORK/boot-default.yaml" "$WORK/nl.out" \
  && { nl_ok=1; nl_detail="$nl_detail [admission.enabled=false renders the default — the check sees nothing]"; }
check nulltoggle "$nl_ok" "$nl_detail"

# nullfields — with a self-check, because a detector that cannot report is
# indistinguishable from a clean render.
nullfield_paths() { # <manifest> -> "Kind/name path" per null leaf
  "$YQ" e -N 'select(. != null) | . as $d | (.. | select(tag == "!!null") | ($d.kind + "/" + $d.metadata.name + " " + (path | join("."))))' "$1"
}
nf_detail=""
printf 'kind: Probe\nmetadata:\n  name: clean\nspec:\n  domains:\n    - a\n' > "$WORK/nf-clean.yaml"
printf 'kind: Probe\nmetadata:\n  name: dirty\nspec:\n  domains:\n' > "$WORK/nf-dirty.yaml"
[ -z "$(nullfield_paths "$WORK/nf-clean.yaml")" ] || nf_detail="$nf_detail [self-check: false positive on a clean probe]"
[ "$(nullfield_paths "$WORK/nf-dirty.yaml")" = "Probe/dirty spec.domains" ] || nf_detail="$nf_detail [self-check: the detector cannot see a known null]"
for c in all core eso; do
  render "$c" "$FIXTURES/values-no-workloads.yaml" > "$WORK/nw-$c.yaml" 2>"$WORK/nw.err" \
    || { nf_detail="$nf_detail [no-workloads $c: render failed: $(first "$WORK/nw.err")]"; continue; }
done
for f in boot-default.yaml emit-enabled.yaml emit-disabled.yaml nw-all.yaml nw-core.yaml nw-eso.yaml all.raw; do
  [ -f "$WORK/$f" ] || continue
  nf_out="$(nullfield_paths "$WORK/$f")" || { nf_detail="$nf_detail [$f: yq failed]"; continue; }
  [ -z "$nf_out" ] || nf_detail="$nf_detail [$f: $(printf '%s' "$nf_out" | sort -u | tr '\n' ' ')]"
done
[ -z "$nf_detail" ] && check nullfields 0 || check nullfields 1 "rendered null field(s) — admission rejects these and fails the whole TI:$nf_detail"

# parentplumb — parsed as YAML, never grepped
pp_ok=0; pp_detail=""
cat > "$WORK/pp.yaml" <<'YAML'
vco:
  role: my-role
kubernetesAuth:
  name: apps
parent:
  token:
    type: batch
    ttl: 900
  sso:
    allowedRedirectUris:
      - "https://console.example.com/oidc/callback"
YAML
"$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/pp.yaml" > "$WORK/pp.out" 2>&1 \
  || { pp_ok=1; pp_detail="$pp_detail [bootstrap render failed: $(first "$WORK/pp.out")]"; }
"$YQ" e -N "select(.kind == \"Template\" and .metadata.name == \"$P\") | .spec.helm.valuesTemplate" "$WORK/pp.out" > "$WORK/pp-values.yaml" 2>/dev/null \
  || { pp_ok=1; pp_detail="$pp_detail [could not extract the core valuesTemplate]"; }
pp_get() { "$YQ" e -N "$1" "$WORK/pp-values.yaml" 2>/dev/null; }
[ "$(pp_get '.vco.role')" = my-role ] || { pp_ok=1; pp_detail="$pp_detail [vco.role not plumbed]"; }
[ "$(pp_get '.vco | has("namespace")')" = false ] || { pp_ok=1; pp_detail="$pp_detail [vco.namespace reached the tenant chart]"; }
[ "$(pp_get '.kubernetesAuth.name')" = apps ] || { pp_ok=1; pp_detail="$pp_detail [kubernetesAuth.name not plumbed]"; }
[ "$(pp_get '.token.type')" = batch ] || { pp_ok=1; pp_detail="$pp_detail [token.type not plumbed]"; }
[ "$(pp_get '.token.ttl | tag')" = '!!int' ] || { pp_ok=1; pp_detail="$pp_detail [token.ttl lost its integer type: $(pp_get '.token.ttl | tag')]"; }
[ "$(pp_get '.sso.allowedRedirectUris[0]')" = 'https://console.example.com/oidc/callback' ] || { pp_ok=1; pp_detail="$pp_detail [allowedRedirectUris not plumbed]"; }
# The plumbed values must survive the tenant chart, not only parse here.
"$YQ" e -N '{"vco": .vco, "kubernetesAuth": .kubernetesAuth, "token": .token, "sso": {"allowedRedirectUris": .sso.allowedRedirectUris}}' "$WORK/pp-values.yaml" > "$WORK/pp-tenant-values.yaml"
if render core "$FIXTURES/values-full.yaml" -f "$WORK/pp-tenant-values.yaml" --set token.period=0 > "$WORK/pp-tenant.out" 2>&1; then
  yqs ppaths 'select(.kind == "KubernetesAuthEngineRole") | .spec.path' "$WORK/pp-tenant.out"
  [ "$(sort -u <<<"$ppaths")" = team-a/kubernetes/apps ] \
    || { pp_ok=1; pp_detail="$pp_detail [plumbed mount name did not reach the roles: '$(sort -u <<<"$ppaths" | tr '\n' ' ')']"; }
  yqs pprole 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .spec.authentication.role' "$WORK/pp-tenant.out"
  [ "$(sort -u <<<"$pprole")" = my-role ] || { pp_ok=1; pp_detail="$pp_detail [plumbed vco.role did not reach the CRs: '$pprole']"; }
else
  pp_ok=1; pp_detail="$pp_detail [tenant chart rejected the plumbed values: $(first "$WORK/pp-tenant.out")]"
fi
# Counterweight: an unset token block is omitted, not emitted empty.
"$YQ" e -N "select(.kind == \"Template\" and .metadata.name == \"$P\") | .spec.helm.valuesTemplate" "$WORK/boot-enabled.yaml" > "$WORK/pp-def.yaml"
yqs hastok 'has("token")' "$WORK/pp-def.yaml"
[ "$hastok" = false ] || { pp_ok=1; pp_detail="$pp_detail [an unset parent.token emitted a token key]"; }
# A ttl of 0 ("Vault's default" to the tenant chart) is plumbed, not dropped.
printf 'parent:\n  token:\n    ttl: 0\n' > "$WORK/pp-zero.yaml"
"$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/pp-zero.yaml" > "$WORK/pp-zero.out" 2>&1 \
  || { pp_ok=1; pp_detail="$pp_detail [parent.token.ttl=0 failed the render: $(first "$WORK/pp-zero.out")]"; }
"$YQ" e -N "select(.kind == \"Template\" and .metadata.name == \"$P\") | .spec.helm.valuesTemplate" "$WORK/pp-zero.out" > "$WORK/pp-zero-values.yaml"
yqs ppzero '.token.ttl | tag + "=" + (. | tostring)' "$WORK/pp-zero-values.yaml"
[ "$ppzero" = '!!int=0' ] || { pp_ok=1; pp_detail="$pp_detail [parent.token.ttl=0 reached the tenant chart as '$ppzero', want 0]"; }
printf 'parent:\n  sso: null\n  token: null\n' > "$WORK/pp-null.yaml"
"$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/pp-null.yaml" > "$WORK/pp-null.out" 2>&1 \
  || { pp_ok=1; pp_detail="$pp_detail [a nulled parent.sso/token failed the render: $(first "$WORK/pp-null.out")]"; }
check parentplumb "$pp_ok" "$pp_detail"

# installvalues — the helpers with the schema removed, and the schema with
# the templates stripped, each on its own.
iv_ok=0; iv_detail=""
iv_helper() { # iv_helper <label> <values YAML> <helper message>: the schema removed
  printf '%s\n' "$2" > "$WORK/iv.yaml"
  if "$HELM" template b "$WORK/noschema/boot" -n "$NS" -f "$WORK/iv.yaml" > /dev/null 2>"$WORK/iv.err"; then
    iv_ok=1; iv_detail="$iv_detail [$1 rendered with the schema removed]"
  else
    grep -qF -- "$3" "$WORK/iv.err" || { iv_ok=1; iv_detail="$iv_detail [$1 failed elsewhere: $(first "$WORK/iv.err")]"; }
  fi
}
for c in "configNamespace:configNamespace: Vault-Config" \
         "templateOperator.namespace:templateOperator: {namespace: \"\"}" \
         "templateOperator.namespace:templateOperator: {namespace: \"a:b\"}" \
         "templateOperator.serviceAccountName:templateOperator: {serviceAccountName: \"\"}" \
         "vco.serviceAccount:vco: {serviceAccount: \"a b\"}" \
         "vco.authPath:vco: {authPath: \"k8s x\"}" \
         "parent.env:parent: {env: Prod}" \
         "parent.sharedTenantName:parent: {sharedTenantName: sh.red}" \
         "parent.tenantLabelKey:parent: {tenantLabelKey: \"a b\"}" \
         "kubernetesAuth.path:kubernetesAuth: {path: \"k8s.x\"}" \
         "kubernetesAuth.name:kubernetesAuth: {name: \"\"}" \
         "tenantValues.sso.mount.path:tenantValues: {sso: {mount: {path: \"\"}}}" \
         "tenantValues.sso.mount.name:tenantValues: {sso: {mount: {name: \"a b\"}}}" \
         "kubernetesAuth.tokenReviewerServiceAccount:kubernetesAuth: {tokenReviewerServiceAccount: \"a b\"}"; do
  iv_helper "${c%%:*}" "${c#*:}" "${c%%:*} \""
done
iv_helper "a reserved shared name" 'parent: {sharedTenantName: sys}' 'parent.sharedTenantName "sys" is a reserved name'
iv_helper "a shared name in reservedPaths" 'parent: {sharedTenantName: secret}' 'parent.sharedTenantName "secret" is a reserved name'
iv_helper "ttl over maxTTL" 'parent: {token: {ttl: 7200, maxTTL: 3600}}' 'parent.token.ttl 7200 is over parent.token.maxTTL 3600'
# One side set: the other is the tenant chart's default (ttl 3600, maxTTL
# 14400, pinned by tenantvaluekeys), and the tenant chart compares the two.
iv_helper "a ttl over the default maxTTL" 'parent: {token: {ttl: 20000}}' 'parent.token.ttl 20000 is over parent.token.maxTTL 14400'
iv_helper "a maxTTL under the default ttl" 'parent: {token: {maxTTL: 1800}}' 'parent.token.ttl 3600 is over parent.token.maxTTL 1800'
iv_helper "an empty vco.role" 'vco: {role: ""}' 'vco.role "" must be set'
# Null: Helm deletes the key, so the schema's minLength never sees it.
iv_helper "a null API host" 'kubernetesAuth: {kubernetesHost: null}' 'kubernetesAuth.kubernetesHost must be set'
iv_helper "a null tenant chart version" 'tenantChart: {version: null}' 'tenantChart.version must be set'
# With admission off: the admission template embeds vco.role, refuses a quote
# itself, and renders before 01-checks.yaml.
iv_helper "a quote in vco.role" "admission: {enabled: false}
vco: {role: \"vco'x\"}" "vco.role \"vco'x\" must be set and hold no quote or backslash"
iv_helper "a backslash in vco.role" 'admission: {enabled: false}
vco: {role: "vco\\x"}' 'must be set and hold no quote or backslash'
# The Kubernetes and SSO auth mounts: never one path, never one inside the
# other (auth/<tenant>/oidc/sso by default).
iv_helper "both mounts on one path" 'kubernetesAuth: {path: oidc, name: sso}' 'kubernetesAuth (auth/<tenant>/oidc/sso) and tenantValues.sso.mount (auth/<tenant>/oidc/sso)'
iv_helper "the Kubernetes mount inside the SSO mount" 'kubernetesAuth: {path: oidc/sso, name: apps}' 'kubernetesAuth (auth/<tenant>/oidc/sso/apps) and tenantValues.sso.mount (auth/<tenant>/oidc/sso)'
iv_helper "the SSO mount inside the Kubernetes mount" 'tenantValues: {sso: {mount: {path: kubernetes/workloads, name: sso}}}' 'kubernetesAuth (auth/<tenant>/kubernetes/workloads) and tenantValues.sso.mount (auth/<tenant>/kubernetes/workloads/sso)'
# Wrong types the tenant chart can't read: the schema refuses each, on its
# own (the templates stripped).
# Each names the field the schema must refuse, so a refusal of another field
# is not this case's.
while IFS='|' read -r field c; do
  [ -n "$field" ] || continue
  printf '%s\n' "$c" > "$WORK/iv.yaml"
  if "$HELM" template b "$WORK/notpl/boot" -n "$NS" -f "$WORK/iv.yaml" > /dev/null 2>"$WORK/iv.err"; then
    iv_ok=1; iv_detail="$iv_detail [the schema accepted $c]"
  else
    schema_at "$WORK/iv.err" "$field" || { iv_ok=1; iv_detail="$iv_detail [$c failed elsewhere: $(grep -m1 -- '^- ' "$WORK/iv.err" || first "$WORK/iv.err")]"; }
  fi
done <<'TABLE'
tenantValues.roleCaps|tenantValues: {roleCaps: null}
tenantValues.roleCaps.admin|tenantValues: {roleCaps: {admin: [read]}}
tenantValues.sso.tenantRoleMapping|tenantValues: {sso: {tenantRoleMapping: []}}
tenantValues.sso.tenantRoleMapping.admin.pattern|tenantValues: {sso: {tenantRoleMapping: {admin: {pattern: ["{tenant}-x"]}}}}
tenantValues.ssoToken|tenantValues: {ssoToken: ""}
tenantValues.ssoToken.ttl|tenantValues: {ssoToken: {ttl: 900}}
tenantValues.sso.oidc.clientSecretRef|tenantValues: {sso: {oidc: {clientSecretRef: x}}}
tenantValues.sso.oidc.clientSecretRef.name|tenantValues: {sso: {oidc: {clientSecretRef: {name: 1}}}}
tenantValues.sso.oidc.caBundlePem|tenantValues: {sso: {oidc: {caBundlePem: 123}}}
tenantValues.vaultCABundle|tenantValues: {vaultCABundle: 123}
tenantValues.sso.oidc.clientId|tenantValues: {sso: {oidc: {clientId: ""}}}
tenantValues.sso.tenantGroupTemplate|tenantValues: {sso: {tenantGroupTemplate: [x]}}
tenantValues.sso.mount.name|tenantValues: {sso: {mount: {name: 1}}}
tenantValues.monitoring.prometheusNamespace|tenantValues: {monitoring: {prometheusNamespace: 1}}
TABLE
# Their right forms pass the schema, the helpers' near misses too.
printf '%s\n' 'tenantValues: {vaultCABundle: pem, ssoToken: {ttl: 30m, maxTTL: 2h}, roleCaps: {ops: "[\"read\"]"}, sso: {roles: [admin, ops], tenantGroupTemplate: "{tenant}-{role}s", tenantRoleMapping: {admin: {pattern: "ops-{tenant}-x"}, ops: {}, fallback: deny}, mount: {path: oidc, name: sso}, oidc: {clientId: vault, clientSecretRef: {name: a, key: b}, caBundlePem: pem}}, monitoring: {prometheusNamespace: monitoring}}' > "$WORK/iv.yaml"
"$HELM" template b "$WORK/notpl/boot" -n "$NS" -f "$WORK/iv.yaml" > /dev/null 2>"$WORK/iv.err" \
  || { iv_ok=1; iv_detail="$iv_detail [the schema refused the right types: $(first "$WORK/iv.err")]"; }
# The schema refuses the ones it has a pattern for, on its own.
while IFS='|' read -r field c; do
  [ -n "$field" ] || continue
  printf '%s\n' "$c" > "$WORK/iv.yaml"
  if "$HELM" template b "$WORK/notpl/boot" -n "$NS" -f "$WORK/iv.yaml" > /dev/null 2>"$WORK/iv.err"; then
    iv_ok=1; iv_detail="$iv_detail [the schema accepted $c]"
  else
    schema_rule "$WORK/iv.err" "$field" pattern || { iv_ok=1; iv_detail="$iv_detail [$c failed elsewhere: $(grep -m1 -- '^- ' "$WORK/iv.err" || first "$WORK/iv.err")]"; }
  fi
done <<'TABLE'
templateOperator.namespace|templateOperator: {namespace: ""}
templateOperator.serviceAccountName|templateOperator: {serviceAccountName: "a:b"}
parent.sharedTenantName|parent: {sharedTenantName: sh.red}
configNamespace|configNamespace: Vault-Config
TABLE
# Near misses that must install.
for c in 'kubernetesAuth: {path: kubernetes_prod}' 'parent: {token: {ttl: 3600, maxTTL: 3600}}' 'parent: {sharedTenantName: shares}' \
         'parent: {token: {ttl: 14400}}' 'parent: {token: {maxTTL: 3600}}' 'parent: {token: {ttl: 20000, maxTTL: 0}}' \
         'parent: {token: {ttl: 0, maxTTL: 1800}}' 'kubernetesAuth: {path: oidc, name: workloads}' 'kubernetesAuth: {path: oidc, name: ssox}' \
         'tenantValues: {sso: {mount: {path: kubernetes, name: workloadsx}}}' 'vco: {authPath: /kubernetes/}' \
         'kubernetesAuth: {tokenReviewerServiceAccount: vault-token-reviewer}'; do
  printf '%s\n' "$c" > "$WORK/iv.yaml"
  "$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/iv.yaml" > /dev/null 2>"$WORK/iv.err" \
    || { iv_ok=1; iv_detail="$iv_detail [$c was refused: $(first "$WORK/iv.err")]"; }
done
# The helpers alone: a quote in a role pattern stops the CEL compiling.
printf '%s\n' "tenantValues: {sso: {tenantRoleMapping: {admin: {pattern: \"{tenant}'s-admins\"}}}}" > "$WORK/iv.yaml"
if "$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/iv.yaml" > /dev/null 2>"$WORK/iv.err"; then
  iv_ok=1; iv_detail="$iv_detail [a quote in a role pattern rendered]"
else
  grep -q 'contains a quote, a double quote or a backslash' "$WORK/iv.err" || { iv_ok=1; iv_detail="$iv_detail [a quoted pattern failed elsewhere: $(first "$WORK/iv.err")]"; }
fi
# Positive control: the lab's and the e2e suite's values pass the schema.
"$HELM" template b "$WORK/notpl/boot" -n "$NS" --set configNamespace=vault-config --set vco.serviceAccount=vco-admin \
  --set templateOperator.serviceAccountName=template-operator-v2-controller-manager --set templateOperator.namespace=template-operator-v2-system \
  --set tenantChart.registry=http://chart-repo --set parent.eso=enabled --set parent.externalSecretRefreshInterval=15s \
  --set parent.sso.enabled=true --set parent.sso.issuerUrl=http://dex:5556 --set 'parent.sso.allowedRedirectUris[0]=http://localhost:8250/oidc/callback' \
  --set tenantValues.monitoring.enabled=true --set tenantValues.sso.oidc.clientId=vault > /dev/null 2>"$WORK/iv.err" \
  || { iv_ok=1; iv_detail="$iv_detail [the schema refused the lab's values: $(first "$WORK/iv.err")]"; }
check installvalues "$iv_ok" "$iv_detail"

# schemakeys — every object the schema closes refuses a key it does not list.
# The objects are found by walking the schema, and the list is pinned: an
# object opened again (additionalProperties: true, the line dropped, or the
# node replaced by a bare type) or a new one changes the list and fails here.
# Change SK_CLOSED with the schema.
SK_CLOSED="<root> admission kubernetesAuth parent parent.sso parent.token sync templateOperator tenantChart tenantValues
tenantValues.monitoring tenantValues.sso tenantValues.sso.mount tenantValues.sso.oidc tenantValues.sso.oidc.clientSecretRef
tenantValues.ssoToken vco"
sk_ok=0; sk_detail=""
python3 - "$BOOTSTRAP/values.schema.json" > "$WORK/sk.paths" <<'PY' || { echo "FAIL  infra — cannot walk the bootstrap schema"; exit 1; }
import json, sys
schema = json.load(open(sys.argv[1]))
closed = []
def walk(node, path):
    if not isinstance(node, dict):
        return
    if "properties" in node:
        closed.append((path, node.get("additionalProperties") is False))
        for k, v in node["properties"].items():
            walk(v, path + [k])
walk(schema, [])
for path, is_closed in closed:
    print(("." .join(path) or "<root>") + "	" + ("closed" if is_closed else "open"))
PY
sk_got="$(cut -f1 "$WORK/sk.paths" | sort | tr '\n' ' ')"
sk_want="$(printf '%s\n' $SK_CLOSED | sort | tr '\n' ' ')"
[ "$sk_got" = "$sk_want" ] || { sk_ok=1; sk_detail="$sk_detail [the objects with properties are '$sk_got', want '$sk_want']"; }
while IFS=$'\t' read -r path state; do
  [ "$state" = closed ] || { sk_ok=1; sk_detail="$sk_detail [$path lists its keys but accepts any other]"; continue; }
  key="zzMisspelt"; [ "$path" = "<root>" ] || key="$path.zzMisspelt"
  if "$HELM" template b "$WORK/notpl/boot" -n "$NS" --set "$key=x" > /dev/null 2>"$WORK/sk.err"; then
    sk_ok=1; sk_detail="$sk_detail [the schema accepted $key]"
  else
    grep -q 'zzMisspelt' "$WORK/sk.err" || { sk_ok=1; sk_detail="$sk_detail [$key failed elsewhere: $(first "$WORK/sk.err")]"; }
  fi
done < "$WORK/sk.paths"
for obj in vco kubernetesAuth templateOperator tenantChart parent; do
  printf '%s: null\n' "$obj" > "$WORK/sk-null.yaml"
  if "$HELM" template b "$WORK/notpl/boot" -n "$NS" -f "$WORK/sk-null.yaml" > /dev/null 2>"$WORK/sk.err"; then
    sk_ok=1; sk_detail="$sk_detail [the schema accepted $obj: null]"
  else
    schema_rule "$WORK/sk.err" "" required "$obj" \
      || { sk_ok=1; sk_detail="$sk_detail [$obj: null failed elsewhere: $(first "$WORK/sk.err")]"; }
  fi
done
check schemakeys "$sk_ok" "$sk_detail"

# schemaforms — the schema helpers on fixed lines of both Helm forms, and a
# near miss of each (another field, another rule): CI runs one Helm version,
# so the other form's branch is proven here, not by the checks above (DX.4).
sf_ok=0; sf_detail=""
sf_e="$WORK/sf.err"
sf() { # sf <want: yes|no> <error line> <helper call, with $sf_e as its file>
  local want=$1 line=$2 got; shift 2
  printf '%s\n' "$line" > "$sf_e"
  if "$@"; then got=yes; else got=no; fi
  [ "$got" = "$want" ] || { sf_ok=1; sf_detail="$sf_detail [$1 ${*:3} on '$line': $got, want $want]"; }
}
sf yes "- parent.eso: Invalid type. Expected: string, given: boolean" schema_at "$sf_e" parent.eso
sf yes "- at '/parent/eso': got boolean, want string" schema_at "$sf_e" parent.eso
sf no "- at '/parent/esoX': got boolean, want string" schema_at "$sf_e" parent.eso
sf yes "- tenantValues.sso.roles: array items[0,1] must be unique" schema_rule "$sf_e" tenantValues.sso.roles unique
sf yes "- at '/tenantValues/sso/roles': items at 0 and 1 are equal" schema_rule "$sf_e" tenantValues.sso.roles unique
sf no "- at '/tenantValues/sso/rolesX': items at 0 and 1 are equal" schema_rule "$sf_e" tenantValues.sso.roles unique
sf yes "- vco: Additional property namespace is not allowed" schema_rule "$sf_e" vco additional namespace
sf yes "- at '/vco': additional properties 'namespace' not allowed" schema_rule "$sf_e" vco additional namespace
sf no "- at '/vco': additional properties 'role' not allowed" schema_rule "$sf_e" vco additional namespace
sf yes "- (root): vco is required" schema_rule "$sf_e" "" required vco
sf yes "- at '': missing property 'vco'" schema_rule "$sf_e" "" required vco
sf no "- at '': missing property 'parent'" schema_rule "$sf_e" "" required vco
sf yes "- configNamespace: Does not match pattern '^[a-z]'" schema_rule "$sf_e" configNamespace pattern
sf yes "- at '/configNamespace': 'V' does not match pattern '^[a-z]'" schema_rule "$sf_e" configNamespace pattern
sf no "- at '/configNamespace': got number, want string" schema_rule "$sf_e" configNamespace pattern
check schemaforms "$sf_ok" "$sf_detail"

# tenantvaluekeys — the bootstrap schema's tenantValues keys are the tenant
# chart's values.yaml keys, plus the removed keys whose guards name the fix.
tk_ok=0; tk_detail=""
SCHEMA="$BOOTSTRAP/values.schema.json"
tk_pair() { # tk_pair <label> <schema path> <values path> <removed keys...>
  local label="$1" sp="$2" vp="$3" want got; shift 3
  yqs got "$sp | keys | .[]" "$SCHEMA"
  yqs want "$vp | keys | .[]" "$CHART/values.yaml"
  want="$(printf '%s\n' "$want" "$@" | grep . | sort | tr '\n' ' ')"
  got="$(tr -d '"' <<<"$got" | sort | tr '\n' ' ')"  # yq prints a JSON file's keys quoted
  [ -n "$got" ] && [ "$got" = "$want" ] || { tk_ok=1; tk_detail="$tk_detail [$label: schema '$got', tenant values '$want']"; }
}
tk_pair tenantValues '.properties.tenantValues.properties' '.' networkPolicy
tk_pair sso '.properties.tenantValues.properties.sso.properties' '.sso' audience
tk_pair sso.oidc '.properties.tenantValues.properties.sso.properties.oidc.properties' '.sso.oidc' perTenantClient
tk_pair sso.mount '.properties.tenantValues.properties.sso.properties.mount.properties' '.sso.mount'
tk_pair monitoring '.properties.tenantValues.properties.monitoring.properties' '.monitoring'
mkdir -p "$WORK/dr/templates" && cp "$BOOTSTRAP/templates/_helpers.tpl" "$WORK/dr/templates/" && cp "$BOOTSTRAP/Chart.yaml" "$WORK/dr/" \
  && printf 'roles: {{ include "mto-extension-vault-community-bootstrap.defaultRoles" . | fromYamlArray | sortAlpha | join "," }}\ntoken: {{ include "mto-extension-vault-community-bootstrap.defaultToken" . | fromYaml | toJson }}\nssoToken: {{ include "mto-extension-vault-community-bootstrap.defaultSsoToken" . | fromYaml | toJson }}\nssoMount: {{ include "mto-extension-vault-community-bootstrap.defaultSsoMount" . | fromYaml | toJson }}\ngroupTemplate: {{ include "mto-extension-vault-community-bootstrap.defaultGroupTemplate" . | quote }}\n' > "$WORK/dr/templates/x.yaml"
"$HELM" template b "$WORK/dr" > "$WORK/dr.out" 2>"$WORK/dr.err" || { echo "FAIL  infra — cannot render the default roles: $(first "$WORK/dr.err")"; exit 1; }
yqs bootroles '.roles' "$WORK/dr.out"
yqs tenroles '.sso.roles | sort | join(",")' "$CHART/values.yaml"
yqs tencaps '.roleCaps | keys | sort | join(",")' "$CHART/values.yaml"
[ "$bootroles" = "$tenroles" ] && [ "$bootroles" = "$tencaps" ] \
  || { tk_ok=1; tk_detail="$tk_detail [the bootstrap's default roles '$bootroles', the tenant chart's sso.roles '$tenroles' and roleCaps '$tencaps']"; }
# The token defaults the install compares a one-sided parent.token with.
yqs boottok '(.token.ttl | tostring) + "/" + (.token.maxTTL | tostring)' "$WORK/dr.out"
yqs tentok '(.token.ttl | tostring) + "/" + (.token.maxTTL | tostring)' "$CHART/values.yaml"
[ -n "$tentok" ] && [ "$boottok" = "$tentok" ] \
  || { tk_ok=1; tk_detail="$tk_detail [the bootstrap's default token ttl/maxTTL '$boottok', the tenant chart's '$tentok']"; }
# The SSO token, mount and group pattern defaults the install and the
# admission policies assume, and the feature default the RBAC gate assumes.
for pair in '.ssoToken.ttl + "/" + .ssoToken.maxTTL:.ssoToken.ttl + "/" + .ssoToken.maxTTL' \
            '.ssoMount.path + "/" + .ssoMount.name:.sso.mount.path + "/" + .sso.mount.name' \
            '.groupTemplate:.sso.tenantGroupTemplate'; do
  yqs bootv "${pair%%:*}" "$WORK/dr.out"
  yqs tenv "${pair#*:}" "$CHART/values.yaml"
  [ -n "$tenv" ] && [ "$bootv" = "$tenv" ] \
    || { tk_ok=1; tk_detail="$tk_detail [the bootstrap's default '$bootv', the tenant chart's ${pair#*:} '$tenv']"; }
done
yqs tenmon '.monitoring.enabled' "$CHART/values.yaml"
[ "$tenmon" = false ] || { tk_ok=1; tk_detail="$tk_detail [the tenant chart's monitoring.enabled is '$tenmon': the bootstrap's RBAC gate takes an unset feature as off]"; }
check tenantvaluekeys "$tk_ok" "$tk_detail"

# dnsregex — one DNS-label regex, everywhere. Every character class with a-z
# or A-Z in the charts must belong to one of the known forms below; a copy
# loosened (a dot, an uppercase letter) or spelt another way ([a-z0-9-]) is
# left over and fails. A new form is added here on purpose, with its reason.
dr_ok=0; dr_detail=""
python3 - "$REPO_ROOT/charts" > "$WORK/dr.out" <<'PY' || { echo "FAIL  infra — the dnsregex scan failed"; exit 1; }
import os, sys
known = [
    "[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?",          # a label key's name part
    "[A-Za-z0-9_-]([A-Za-z0-9._/-]*[A-Za-z0-9_-])?",     # a secret path in a Deployment annotation
    "[A-Za-z0-9._-]+", "[-._a-zA-Z0-9]+",                # a Secret key
    "[a-z0-9]([-a-z0-9]*[a-z0-9])?",                     # THE DNS label
    "^([a-z0-9][-a-z0-9]*)?$", "^([-a-z0-9]*[a-z0-9])?$",  # the head and tail of one (ssoCollision)
    "[a-z0-9_][-a-z0-9_.]*",                             # a KV path segment under <env>/
    "[a-z0-9_][-a-z0-9_]*",                              # a Vault mount path segment
    "[a-z]+",                                            # a capability
]
labels = 0
for root, _, files in os.walk(sys.argv[1]):
    for f in sorted(files):
        path = os.path.join(root, f)
        for n, line in enumerate(open(path, encoding="utf-8"), 1):
            labels += line.count(known[4])
            rest = line
            for k in known:
                rest = rest.replace(k, "")
            if "a-z" in rest or "A-Z" in rest:
                print(f"BAD {os.path.relpath(path, sys.argv[1])}:{n}: {line.strip()[:120]}")
print(f"LABELS {labels}")
PY
dr_bad="$(grep '^BAD ' "$WORK/dr.out" || true)"
[ -z "$dr_bad" ] || { dr_ok=1; dr_detail="$dr_detail [regexes of no known form: $(sed 's/^BAD //' <<<"$dr_bad" | tr '\n' '|')]"; }
dr_n="$(sed -n 's/^LABELS //p' "$WORK/dr.out")"
[ "${dr_n:-0}" -ge 30 ] || { dr_ok=1; dr_detail="$dr_detail [$dr_n DNS-label copies found — the check proves nothing]"; }
check dnsregex "$dr_ok" "$dr_detail"

# versionpin
tv="$("$YQ" e '.version' "$CHART/Chart.yaml")"
bv="$("$YQ" e '.tenantChart.version' "$BOOTSTRAP/values.yaml")"
[ "$tv" = "$bv" ] && check versionpin 0 || check versionpin 1 "tenant chart is $tv, bootstrap pins $bv"

# outputnames — on both ESO settings, so every Template variant is covered.
on_ok=0; on_detail=""
for eso in enabled disabled; do
  yqs tmpls 'select(.kind == "Template") | .metadata.name' "$WORK/boot-$eso.yaml"
  [ -n "$tmpls" ] || { on_ok=1; on_detail="$on_detail [eso=$eso: no Templates]"; }
  for t in $tmpls; do
    yqs onames "select(.kind == \"Template\" and .metadata.name == \"$t\") | .spec.outputs[].name" "$WORK/boot-$eso.yaml"
    yqs fnames "select(.kind == \"Template\" and .metadata.name == \"$t\") | .spec.outputs[].fields[].name" "$WORK/boot-$eso.yaml"
    [ -n "$fnames" ] || { on_ok=1; on_detail="$on_detail [$t: no output fields]"; }
    dup="$(sort <<<"$onames" | uniq -d)"; [ -z "$dup" ] || { on_ok=1; on_detail="$on_detail [$t: duplicate output names: $dup]"; }
    dup="$(sort <<<"$fnames" | uniq -d | tr '\n' ' ')"; [ -z "$dup" ] || { on_ok=1; on_detail="$on_detail [$t: duplicate field names: $dup]"; }
  done
done
check outputnames "$on_ok" "$on_detail"

# tenantname
tnm_ok=0; tnm_detail=""
render core "$FIXTURES/values-full.yaml" --set-string tenant=1234 --set knownTenants=1234 > "$WORK/num.yaml" 2>"$WORK/num.err" \
  || { tnm_ok=1; tnm_detail="$tnm_detail [tenant 1234 did not render: $(first "$WORK/num.err")]"; }
yqs nonstr '(.. | select(has("name")) | .name | select(tag != "!!str")), (.metadata.labels[]? | select(tag != "!!str")), (.. | select(has("matchLabels")) | .matchLabels[] | select(tag != "!!str")), (select(.apiVersion == "redhatcop.redhat.io/v1alpha1" and .spec.path != null) | .spec.path | select(tag != "!!str"))' "$WORK/num.yaml"
[ -z "$nonstr" ] || { tnm_ok=1; tnm_detail="$tnm_detail [tenant 1234 left non-string values: $(tr '\n' ' ' <<<"$nonstr")]"; }
yqs numpolicies 'select(.kind == "Policy") | .metadata.name' "$WORK/num.yaml"
[ -n "$numpolicies" ] || { tnm_ok=1; tnm_detail="$tnm_detail [tenant 1234 rendered no Policy — the check proves nothing]"; }
for bad in has.dot Upper under_score; do
  if render core "$FIXTURES/values-no-optins.yaml" --set-string "tenant=$bad" > /dev/null 2>"$WORK/tnm.err"; then
    tnm_ok=1; tnm_detail="$tnm_detail [tenant $bad rendered]"
  else
    grep -q 'is not a DNS label' "$WORK/tnm.err" || { tnm_ok=1; tnm_detail="$tnm_detail [tenant $bad failed elsewhere: $(first "$WORK/tnm.err")]"; }
  fi
done
yqs pnonstr '(.. | select(has("value")) | .value | select(tag != "!!str")), (.. | select(has("matchLabels")) | .matchLabels[] | select(tag != "!!str")), (.metadata.name | select(tag != "!!str")), (.metadata.labels[]? | select(tag != "!!str")), (select(.apiVersion == "redhatcop.redhat.io/v1alpha1" and .spec.path != null) | .spec.path | select(tag != "!!str"))' "$WORK/emit-enabled.yaml"
[ -z "$pnonstr" ] || { tnm_ok=1; tnm_detail="$tnm_detail [parent left non-string values for tenant 1234: $(tr '\n' ' ' <<<"$pnonstr")]"; }
yqs n1234 'select(.metadata.name == "1234-kv") | .spec.path' "$WORK/emit-enabled.yaml"
[ "$n1234" = 1234 ] || { tnm_ok=1; tnm_detail="$tnm_detail [tenant 1234 rendered no mount — the check proves nothing]"; }
check tenantname "$tnm_ok" "$tnm_detail"

# datalifetime
dl_ok=0; dl_detail=""
for c in all core; do
  yqs data "select(.kind == \"SecretEngineMount\") | .kind + \"/\" + .metadata.name" "$WORK/$c.raw"
  [ -z "$data" ] || { dl_ok=1; dl_detail="$dl_detail [tenant chart ($c) renders $data — it must come from the parent]"; }
done
yqs empt 'select(.kind == "SecretEngineMount" and .metadata.name == "empty-tenant-kv") | .spec.path' "$WORK/emit-enabled.yaml"
[ "$empt" = empty-tenant ] || { dl_ok=1; dl_detail="$dl_detail [a tenant with no labelled namespace has no kv mount from the parent: '$empt']"; }
yqs emptti 'select(.kind == "TemplateInstance" and (.metadata.name | test("empty-tenant"))) | .metadata.name' "$WORK/emit-enabled.yaml"
[ -z "$emptti" ] || { dl_ok=1; dl_detail="$dl_detail [a tenant with no labelled namespace got a child TI: $emptti]"; }
check datalifetime "$dl_ok" "$dl_detail"

# tenantvalues — the bootstrap half
tv_ok=0; tv_detail=""
for owned in "tenantValues.vco.role=x:use vco instead" "tenantValues.sso.enabled=true:use parent.sso.enabled" "tenantValues.token.ttl=5:use parent.token"; do
  if "$HELM" template b "$BOOTSTRAP" -n "$NS" --set "${owned%%:*}" > /dev/null 2>"$WORK/tv.err"; then
    tv_ok=1; tv_detail="$tv_detail [${owned%%:*} accepted]"
  else
    grep -q -- "${owned#*:}" "$WORK/tv.err" || { tv_ok=1; tv_detail="$tv_detail [${owned%%:*} failed elsewhere: $(first "$WORK/tv.err")]"; }
  fi
done
# From a values file, and asserted on the guard's own message: `--set` reads
# {…} as list syntax, so a --set value fails in helm's argument parser before it
# reaches the chart, and this check then passed with the guard deleted.
printf 'tenantValues:\n  sso:\n    tenantGroupTemplate: "{tenant}-{role}-{{ .x }}"\n' > "$WORK/tv-braces.yaml"
if "$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/tv-braces.yaml" > /dev/null 2>"$WORK/tv.err"; then
  tv_ok=1; tv_detail="$tv_detail [a value containing {{ was accepted]"
else
  grep -q 'renders the child valuesTemplate as a Go template' "$WORK/tv.err" \
    || { tv_ok=1; tv_detail="$tv_detail [a value containing {{ failed elsewhere: $(first "$WORK/tv.err")]"; }
fi
# Positive control: a value the bootstrap does not own reaches the tenant.
printf 'tenantValues:\n  monitoring:\n    prometheusNamespace: tv-monitoring\n' > "$WORK/tv-ok.yaml"
"$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/tv-ok.yaml" > "$WORK/tv.out" 2>"$WORK/tv.err" \
  || { tv_ok=1; tv_detail="$tv_detail [a tenant value was refused: $(first "$WORK/tv.err")]"; }
yqs tvvals "select(.kind == \"Template\" and .metadata.name == \"$P\") | .spec.helm.valuesTemplate" "$WORK/tv.out"
grep -q 'prometheusNamespace: tv-monitoring' <<<"$tvvals" || { tv_ok=1; tv_detail="$tv_detail [tenantValues did not reach the child valuesTemplate]"; }
check tenantvalues "$tv_ok" "$tv_detail"

# ssoissuer
si_ok=0; si_detail=""
if "$HELM" template b "$BOOTSTRAP" -n "$NS" --set parent.sso.enabled=true > /dev/null 2>"$WORK/si.err"; then
  si_ok=1; si_detail="$si_detail [SSO without an issuer URL installed]"
else
  grep -q 'requires parent.sso.issuerUrl' "$WORK/si.err" || { si_ok=1; si_detail="$si_detail [failed elsewhere: $(first "$WORK/si.err")]"; }
fi
"$HELM" template b "$BOOTSTRAP" -n "$NS" --set parent.sso.enabled=true --set parent.sso.issuerUrl=https://idp > /dev/null 2>"$WORK/si.err" \
  || { si_ok=1; si_detail="$si_detail [SSO with an issuer URL was refused: $(first "$WORK/si.err")]"; }
check ssoissuer "$si_ok" "$si_detail"

# removedkeys — the bootstrap half
rk_ok=0; rk_detail=""
for c in "tenantValues.networkPolicy.enabled=true:NetworkPolicy feature was removed" \
         "tenantValues.sso.oidc.perTenantClient=true:per-tenant client option was removed" \
         "tenantValues.sso.audience=vault:tenantValues.sso.audience was removed"; do
  if "$HELM" template b "$BOOTSTRAP" -n "$NS" --set "${c%%:*}" > /dev/null 2>"$WORK/rk.err"; then
    rk_ok=1; rk_detail="$rk_detail [the bootstrap accepted ${c%%:*}]"
  else
    grep -q -- "${c#*:}" "$WORK/rk.err" || { rk_ok=1; rk_detail="$rk_detail [${c%%:*} failed elsewhere: $(first "$WORK/rk.err")]"; }
  fi
done
for c in "networkPolicy.enabled=true:networkPolicy was removed" "sso.oidc.perTenantClient=false:sso.oidc.perTenantClient was removed" \
         "sso.audience=vault:sso.audience was removed"; do
  if render all "$FIXTURES/values-full.yaml" --set "${c%%:*}" > /dev/null 2>"$WORK/rk.err"; then
    rk_ok=1; rk_detail="$rk_detail [the tenant chart accepted ${c%%:*}]"
  else
    grep -q -- "${c#*:}" "$WORK/rk.err" || { rk_ok=1; rk_detail="$rk_detail [tenant ${c%%:*} failed elsewhere: $(first "$WORK/rk.err")]"; }
  fi
done
# The SSO config still renders the one shared client when the keys are absent.
yqs cid 'select(.kind == "JWTOIDCAuthEngineConfig") | .spec.OIDCClientID + " " + .spec.OIDCCredentials.secret.name' "$WORK/all.raw"
[ "$cid" = "vault vault-oidc-client-secret" ] || { rk_ok=1; rk_detail="$rk_detail [the shared SSO client rendered '$cid', want 'vault vault-oidc-client-secret']"; }
check removedkeys "$rk_ok" "$rk_detail"

# listingvis — every mount sets config.listingVisibility to a value VCO's
# CRD enum accepts.
lv_ok=0; lv_detail=""
for c in "tenant:$WORK/all.raw:1" "parent:$WORK/emit-enabled.yaml:5"; do
  name="${c%%:*}"; rest="${c#*:}"; file="${rest%:*}"; min="${rest##*:}"
  yqs lvmounts 'select(.kind == "SecretEngineMount" or .kind == "AuthEngineMount") | .kind + "/" + .metadata.name' "$file"
  n=$(lines "$lvmounts")
  [ "$n" -ge "$min" ] || { lv_ok=1; lv_detail="$lv_detail [$name: $n mounts rendered, want at least $min — the check below proves nothing]"; }
  yqs lvbad 'select(.kind == "SecretEngineMount" or .kind == "AuthEngineMount") | select(.spec.config.listingVisibility != "hidden" and .spec.config.listingVisibility != "unauth") | .kind + "/" + .metadata.name + " -> " + (.spec.config.listingVisibility // "<unset>")' "$file"
  [ -z "$lvbad" ] || { lv_ok=1; lv_detail="$lv_detail [$name: mounts without a valid listingVisibility: $(tr '\n' ' ' <<<"$lvbad")]"; }
done
check listingvis "$lv_ok" "$lv_detail"

# admission
ad_ok=0; ad_detail=""
yqs vaps 'select(.kind == "ValidatingAdmissionPolicy") | .metadata.name' "$WORK/boot-default.yaml"
yqs vapbs 'select(.kind == "ValidatingAdmissionPolicyBinding") | .metadata.name + "=" + .spec.policyName + "=" + (.spec.validationActions | join(","))' "$WORK/boot-default.yaml"
for p in kinds origin scope cluster; do
  grep -qx "$P-vco-$p" <<<"$vaps" || { ad_ok=1; ad_detail="$ad_detail [no admission policy $P-vco-$p]"; }
  grep -qx "$P-vco-$p=$P-vco-$p=Deny" <<<"$vapbs" || { ad_ok=1; ad_detail="$ad_detail [no Deny binding for $P-vco-$p]"; }
done
yqs fp 'select(.kind == "ValidatingAdmissionPolicy") | .spec.failurePolicy' "$WORK/boot-default.yaml"
[ "$(sort -u <<<"$fp")" = Fail ] || { ad_ok=1; ad_detail="$ad_detail [failurePolicy is not Fail everywhere: $(sort -u <<<"$fp" | tr '\n' ' ')]"; }
yqs adscope 'select(.kind == "ValidatingAdmissionPolicy" and (.metadata.name | test("-vco-(kinds|origin)$"))) | .metadata.name + "=" + (.spec.matchConstraints.resourceRules[0].resources | join(",")) + "/" + .spec.matchConstraints.resourceRules[0].scope' "$WORK/boot-default.yaml"
[ "$(sort <<<"$adscope" | tr '\n' ' ')" = "$P-vco-kinds=*/Namespaced $P-vco-origin=*/Namespaced " ] \
  || { ad_ok=1; ad_detail="$ad_detail [the kinds and origin policies do not match every namespaced kind: $(tr '\n' ' ' <<<"$adscope")]"; }
cat > "$WORK/ad.yaml" <<'YAML'
configNamespace: cfg-x
vco: { authPath: k8s-login, role: vco-x, serviceAccount: vco-sa-x }
templateOperator: { namespace: tov-ns, serviceAccountName: tov-sa }
kubernetesAuth: { kubernetesHost: "https://api.example.com:6443", tokenReviewerServiceAccount: rev-sa }
parent:
  tenantLabelKey: example.com/tenant
  sso: { enabled: true, issuerUrl: "https://idp.example.com/realms/x" }
  reservedPaths: [platform-x]
tenantValues:
  sso:
    tenantGroupTemplate: "grp-{tenant}-{role}"
    tenantRoleMapping: { admin: { pattern: "ops-{tenant}" } }
YAML
"$HELM" template b "$BOOTSTRAP" -n cfg-x -f "$WORK/ad.yaml" > "$WORK/ad.out" 2>"$WORK/ad.err" \
  || { ad_ok=1; ad_detail="$ad_detail [bootstrap with other values failed: $(first "$WORK/ad.err")]"; }
yqs adcel 'select(.kind == "ValidatingAdmissionPolicy") | .. | select(tag == "!!str")' "$WORK/ad.out"
for want in "system:serviceaccount:tov-ns:tov-sa" "'example.com/tenant': variables.t" "https://api.example.com:6443" \
  "https://idp.example.com/realms/x" "'admin': 'ops-{tenant}'" "'editor': 'grp-{tenant}-{role}'" "'platform-x'" "'rev-sa'" \
  "authentication.path == 'k8s-login'" "authentication.role == 'vco-x'" "serviceAccount.name == 'vco-sa-x'"; do
  grep -qF -- "$want" <<<"$adcel" || { ad_ok=1; ad_detail="$ad_detail [the admission policies do not carry '$want']"; }
done
yqs adns 'select(.kind == "ValidatingAdmissionPolicy") | .spec.matchConstraints.namespaceSelector.matchLabels."kubernetes.io/metadata.name"' "$WORK/ad.out"
[ "$(sort -u <<<"$adns")" = cfg-x ] || { ad_ok=1; ad_detail="$ad_detail [the admission policies match namespace '$(sort -u <<<"$adns" | tr '\n' ' ')', want cfg-x]"; }
yqs adparam 'select(.kind == "ValidatingAdmissionPolicyBinding" and .spec.paramRef != null) | .spec.paramRef.namespace + "/" + .spec.paramRef.name' "$WORK/ad.out"
[ "$adparam" = cfg-x/kube-root-ca.crt ] || { ad_ok=1; ad_detail="$ad_detail [the cluster binding reads '$adparam', want cfg-x/kube-root-ca.crt]"; }
"$HELM" template b "$BOOTSTRAP" -n "$NS" --set admission.enabled=false > "$WORK/ad-off.yaml" 2>"$WORK/ad.err" \
  || { ad_ok=1; ad_detail="$ad_detail [admission.enabled=false failed: $(first "$WORK/ad.err")]"; }
yqs adoff 'select(.kind == "ValidatingAdmissionPolicy" or .kind == "ValidatingAdmissionPolicyBinding") | .metadata.name' "$WORK/ad-off.yaml"
[ -z "$adoff" ] || { ad_ok=1; ad_detail="$ad_detail [admission.enabled=false still renders: $(tr '\n' ' ' <<<"$adoff")]"; }
if "$HELM" template b "$WORK/noschema/boot" -n "$NS" --set-string admission.enabled=yes > /dev/null 2>"$WORK/ad.err"; then
  ad_ok=1; ad_detail="$ad_detail [admission.enabled=yes accepted]"
else
  grep -qF 'admission.enabled must be a boolean true or false' "$WORK/ad.err" \
    || { ad_ok=1; ad_detail="$ad_detail [admission.enabled=yes failed elsewhere: $(first "$WORK/ad.err")]"; }
fi
if "$HELM" template b "$BOOTSTRAP" -n "$NS" --set "parent.sso.enabled=true" --set "parent.sso.issuerUrl=https://idp/x'y" > /dev/null 2>"$WORK/ad.err"; then
  ad_ok=1; ad_detail="$ad_detail [an issuer with a quote was embedded in CEL]"
else
  grep -q 'contains a quote or a backslash' "$WORK/ad.err" || { ad_ok=1; ad_detail="$ad_detail [a quoted issuer failed elsewhere: $(first "$WORK/ad.err")]"; }
fi
check admission "$ad_ok" "$ad_detail"

# vcopolicy
vp_ok=0; vp_detail=""
PROD="$REPO_ROOT/charts/examples/vco-admin-policy.hcl"; LAB="$REPO_ROOT/hack/lab/vco-admin-policy.hcl"
stanzas() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$'; }
d="$(diff <(stanzas "$PROD") <(stanzas "$LAB") | grep -E '^[<>]' || true)"
want_d='<   capabilities = ["create", "read", "update"]
>   capabilities = ["create", "read", "update", "delete"]'
[ "$d" = "$want_d" ] || { vp_ok=1; vp_detail="$vp_detail [production and lab policies differ by more than the kv delete: $(tr '\n' '|' <<<"$d")]"; }
stanzas "$PROD" | grep -A1 '^path "sys/mounts/+/kv" {$' | grep -qx '  capabilities = \["create", "read", "update"\]' \
  || { vp_ok=1; vp_detail="$vp_detail [the production kv mount grant is not create, read, update]"; }
# Exactly these paths, nothing else: a denylist misses the next form (a
# sys/policies/acl/* or a sys/policy/+ grant both reach vco-admin).
want_paths="$(printf '%s\n' sys/mounts 'sys/mounts/+/kv' 'sys/mounts/+/kv/tune' sys/auth \
  'sys/auth/+/kubernetes/workloads' 'sys/auth/+/kubernetes/workloads/tune' 'sys/auth/+/oidc/sso' 'sys/auth/+/oidc/sso/tune' \
  'auth/+/kubernetes/workloads/config' 'auth/+/kubernetes/workloads/role/kv.*' 'auth/+/kubernetes/workloads/role/share.*' \
  'auth/+/oidc/sso/config' 'auth/+/oidc/sso/role/sso.*' 'sys/policy/kv.*' 'sys/policy/share.*' 'sys/policy/sso.*' | sort)"
for f in "$PROD" "$LAB"; do
  # Every path stanza, whatever its spacing: one grep for a strict form would
  # miss `path  "x"` or a stanza on the same line as another.
  paths="$(sed -e 's/#.*//' "$f" | grep -oE 'path[[:space:]]*"[^"]*"' | sed -E 's/^path[[:space:]]*"//; s/"$//')"
  [ "$(lines "$paths")" -ge 15 ] || { vp_ok=1; vp_detail="$vp_detail [$(basename "$f"): only $(lines "$paths") paths — the check proves nothing]"; }
  [ "$(sort <<<"$paths")" = "$want_paths" ] \
    || { vp_ok=1; vp_detail="$vp_detail [$(basename "$f") grants other paths: $(diff <(echo "$want_paths") <(sort <<<"$paths") | grep -E '^[<>]' | tr '\n' ' ' || true)]"; }
  bad="$(grep -E '^(sys/policy/\*|sys/mounts/\*|sys/auth/\*|auth/\*|auth/kubernetes/|auth/token|sys/policy/vco-admin|sys/policy/default|\*)' <<<"$paths" || true)"
  [ -z "$bad" ] || { vp_ok=1; vp_detail="$vp_detail [$(basename "$f") grants $(tr '\n' ' ' <<<"$bad")]"; }
  grep -q 'sudo' <(grep -A2 -E '^path "(sys/policy|auth/)' "$f") && { vp_ok=1; vp_detail="$vp_detail [$(basename "$f") gives sudo on a policy or role path]"; }
  for m in 'sys/mounts/+/kv:kv' 'sys/auth/+/kubernetes/workloads:kubernetes' 'sys/auth/+/oidc/sso:oidc'; do
    block="$(awk -v p="path \"${m%%:*}\" {" '$0 == p {on=1} on {print} on && /^}/ {exit}' "$f")"
    grep -q "\"type\" = \[\"${m##*:}\"\]" <<<"$block" || { vp_ok=1; vp_detail="$vp_detail [$(basename "$f"): ${m%%:*} does not pin type ${m##*:}]"; }
  done
done
check vcopolicy "$vp_ok" "$vp_detail"

# release
rl_ok=0; rl_detail=""
mkdir -p "$WORK/stub"
cat > "$WORK/stub/helm" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1" in
  show) case "$STUB_MODE" in
          published*) echo "name: x"; exit 0 ;;
          notfound)  echo "Error: ghcr.io/x: not found" >&2; exit 1 ;;
          *)         echo "Error: unauthorized: authentication required" >&2; exit 1 ;;
        esac ;;
  # pull <ref> --version <v> --untar --untardir <dir>: the published chart,
  # the same as the source or, in mode published-other, edited.
  pull) d="$7"; mkdir -p "$d"; cp -R "$STUB_CHART" "$d/"
        [ "$STUB_MODE" = published-other ] && echo "# changed" >> "$d/$(basename "$STUB_CHART")/values.yaml"; exit 0 ;;
  package) mkdir -p "$4"; n="$(awk '/^name:/{print $2; exit}' "$2/Chart.yaml")"
           tar -czf "$4/$n-$(awk '/^version:/{print $2; exit}' "$2/Chart.yaml").tgz" -C "$(dirname "$2")" "$(basename "$2")" ;;
  push) exit 0 ;;
esac
STUB
chmod +x "$WORK/stub/helm"
rl_case() { # rl_case <mode> <expect-exit 0|1> <expect-push yes|no>
  local rc=0
  : > "$WORK/stub.log"
  (cd "$WORK" && STUB_MODE="$1" STUB_LOG="$WORK/stub.log" STUB_CHART="$CHART" HELM="$WORK/stub/helm" \
     bash -e "$REPO_ROOT/hack/release-chart.sh" "$CHART" ghcr.io/example/charts) > "$WORK/rl.out" 2>&1 || rc=$?
  [ "$rc" -eq "$2" ] || rl_detail="$rl_detail [$1: exit $rc, want $2: $(first "$WORK/rl.out")]"
  if grep -q '^push ' "$WORK/stub.log"; then pushed=yes; else pushed=no; fi
  [ "$pushed" = "$3" ] || rl_detail="$rl_detail [$1: pushed=$pushed, want $3]"
}
rl_case published 0 no
rl_case published-other 1 no
grep -q 'already published with other content' "$WORK/rl.out" || rl_detail="$rl_detail [published-other: no message naming the conflict: $(first "$WORK/rl.out")]"
rl_case notfound 0 yes
rl_case unauthorized 1 no
[ -z "$rl_detail" ] || rl_ok=1
check release "$rl_ok" "$rl_detail"

# bumpcheck
bc_ok=0; bc_detail=""
G="$WORK/bump-repo"
mkdir -p "$G/charts/a" "$G/charts/b"
printf 'name: a\nversion: 0.1.0\n' > "$G/charts/a/Chart.yaml"
printf 'name: b\nversion: 0.1.0\n' > "$G/charts/b/Chart.yaml"
git -C "$G" init -q -b main && git -C "$G" -c user.email=t@t -c user.name=t add . && git -C "$G" -c user.email=t@t -c user.name=t commit -qm base
git -C "$G" switch -q -c pr
bc_case() { # bc_case <label> <expect-exit 0|1>
  local rc=0
  # shellcheck disable=SC2086 # bc_dirs is a list
  (cd "$G" && git -c user.email=t@t -c user.name=t commit -qam "$1" --allow-empty && "$REPO_ROOT/hack/version-bump-check.sh" main $bc_dirs) > "$WORK/bc.out" 2>&1 || rc=$?
  [ "$rc" -eq "$2" ] || bc_detail="$bc_detail [$1: exit $rc, want $2: $(tail -1 "$WORK/bc.out")]"
}
bc_dirs="charts/a charts/b"
bc_case unchanged 0
printf 'x: 1\n' > "$G/charts/a/values.yaml"; git -C "$G" add charts/a/values.yaml
bc_case changed-no-bump 1
# The same, with the chart directory given as charts/a/: Chart.yaml must still
# be found on the base, not read as a new chart.
bc_slash() {
  local rc=0
  (cd "$G" && "$REPO_ROOT/hack/version-bump-check.sh" main charts/a/ charts/b) > "$WORK/bc.out" 2>&1 || rc=$?
  [ "$rc" -eq 1 ] && grep -q 'charts/a: changed but still at version' "$WORK/bc.out" \
    || bc_detail="$bc_detail [charts/a/ changed without a bump: exit $rc, want 1 naming the missing bump: $(tail -1 "$WORK/bc.out")]"
}
bc_slash
# An absolute path and a directory that exists nowhere fail; neither is a new chart.
bc_path() { # bc_path <label> <dir> <message>
  local rc=0
  (cd "$G" && "$REPO_ROOT/hack/version-bump-check.sh" main "$2") > "$WORK/bc.out" 2>&1 || rc=$?
  [ "$rc" -eq 1 ] && grep -q -- "$3" "$WORK/bc.out" \
    || bc_detail="$bc_detail [$1: exit $rc: $(tail -1 "$WORK/bc.out")]"
}
bc_path absolute "$G/charts/a" 'relative to the repository root'
bc_path missing charts/nope 'no such chart directory'
sed -i.bak 's/^version: 0.1.0/version: 0.1.1/' "$G/charts/a/Chart.yaml" && rm -f "$G/charts/a/Chart.yaml.bak"
bc_case changed-with-bump 0
mkdir -p "$G/charts/c" && printf 'name: c\nversion: 0.0.1\n' > "$G/charts/c/Chart.yaml" && git -C "$G" add charts/c
bc_dirs="charts/a charts/b charts/c"
bc_case new-chart 0
# A directory on the base without a readable Chart.yaml is an error, not a
# new chart that passes.
bc_nochart() {
  local rc=0
  git -C "$G" switch -q main && mkdir -p "$G/charts/d" && printf 'x: 1\n' > "$G/charts/d/values.yaml" \
    && git -C "$G" add charts/d && git -C "$G" -c user.email=t@t -c user.name=t commit -qm d \
    && git -C "$G" switch -q pr && git -C "$G" -c user.email=t@t -c user.name=t merge -q --no-edit main >/dev/null \
    && printf 'x: 2\n' > "$G/charts/d/values.yaml" && printf 'name: d\nversion: 0.0.1\n' > "$G/charts/d/Chart.yaml" \
    && git -C "$G" add charts/d && git -C "$G" -c user.email=t@t -c user.name=t commit -qm d2 \
    || { bc_detail="$bc_detail [could not build the charts/d case]"; return; }
  (cd "$G" && "$REPO_ROOT/hack/version-bump-check.sh" main charts/d) > "$WORK/bc.out" 2>&1 || rc=$?
  [ "$rc" -eq 1 ] && grep -q 'has no readable Chart.yaml' "$WORK/bc.out" \
    || bc_detail="$bc_detail [charts/d without a Chart.yaml on the base: exit $rc: $(tail -1 "$WORK/bc.out")]"
}
bc_nochart
[ -z "$bc_detail" ] || bc_ok=1
check bumpcheck "$bc_ok" "$bc_detail"

# fullnames — a kubectl command in the docs, the Makefile or a script
# names template-operator's kinds with their API group. On OpenShift the short
# names templateinstance and template are OpenShift's own template.openshift.io
# kinds: a delete then fails with NotFound, or with --ignore-not-found does
# nothing, and the parent TemplateInstance stays.
fn_ok=0; fn_detail=""
fn_files="$(cd "$REPO_ROOT" && git ls-files --cached --others --exclude-standard -- '*.md' 'Makefile' '*.sh')"
fn_seen=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ "$f" = hack/chart-render-tests.sh ] && continue
  case "$f" in docs/spikes/*) continue ;; esac  # the C.0 record, kept as it ran
  fn_seen=$((fn_seen + 1))
  # grep: 0 = a short name, 1 = none, anything else is an error.
  rc=0
  hits="$(grep -n -E '(kubectl|[^a-z]oc |\$\((KC|KUBECTL)\)|kc ).* (get|delete|wait|describe|edit|patch|label|annotate)([ ,].*)?[ ,](templateinstances?|templates?)([ ,]|$)' "$REPO_ROOT/$f")" || rc=$?
  case "$rc" in
    0) fn_ok=1; fn_detail="$fn_detail [$f: $(tr '\n' ' ' <<<"$hits" | cut -c1-200)]" ;;
    1) ;;
    *) fn_ok=1; fn_detail="$fn_detail [cannot read $f]" ;;
  esac
done <<<"$fn_files"
[ "$fn_seen" -gt 0 ] || { fn_ok=1; fn_detail="$fn_detail [no Markdown, Makefile or script found — the check proves nothing]"; }
check fullnames "$fn_ok" "$fn_detail"

exit "$fail"
