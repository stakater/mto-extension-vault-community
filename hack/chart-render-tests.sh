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
#   golden       — component=all is object-set identical to the committed golden.
#   disjoint     — no object is emitted by both slices (two TIs would fight over it via SSA).
#   union        — core ∪ eso emits exactly the all set.
#   empty        — the eso slice with no opt-ins renders zero objects.
#   badvalue     — an unknown component fails the render with the helper's message.
#   namebudget   — a sliced render fails when the TI name would exceed 63 chars;
#                  component=all is exempt.
#   policyscope  — every Policy of every fixture passes the scope check, read from
#                  the rendered output: one-line stanzas, no sudo, no +, every path
#                  inside its tenant's mount (or its share), the tenant segment
#                  closed by /. A self-test proves the checker flags a bad line,
#                  and a hostile roleCaps fails the render itself.
#   rolebind     — every workload role binds exactly its own policy, its tenant's
#                  mount, its own ServiceAccount, and a selector of exactly its
#                  namespace name and the tenant label: a namespace name reused by
#                  another tenant gets nothing.
#   mountagree   — the auth mount path agrees across the AuthEngineMount, its
#                  config, every role and VAULT_K8S_MOUNT; VAULT_NAMESPACE is empty.
#   guards       — every misconfigured ServiceAccount gets an error ConfigMap and
#                  nothing else; the correct ones in another namespace still
#                  render; hostile values never reach a spec.
#   tokenseconds — token durations are integers on every role; a duration string
#                  fails the render with the schema removed, and the schema
#                  rejects it too.
#   tokentype    — every role pins tokenType; batch + period fails.
#   namecollide  — no two objects of one render share an identity, and parts
#                  that glued to one name with hyphens now give distinct names.
#
# Bootstrap and parent:
#   emission     — the parent emits one TI per enabled slice per tenant with a
#                  labelled namespace, none for a tenant without one, and a roster
#                  of exactly the rendered tenants.
#   reserved     — a tenant name that is not a DNS label, over 63 chars, the
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
#                  stripped AND via the helpers with the schema removed.
#   nullfields   — no rendered field is YAML null, in the bootstrap, the parent,
#                  or the tenant chart with no workloads.
#   parentplumb  — install-wide knobs reach the child valuesTemplate; an unset
#                  token block is omitted, not empty.
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
#   removedkeys  — tenantValues still setting a removed key fails.
#   listingvis   — every mount the tenant chart and the parent render sets
#                  config.listingVisibility.
#                  Unset, VCO's finalizer update sends "" and its CRD enum refuses
#                  it: the CR gets no finalizer, and deleting it never deletes the
#                  mount in Vault.
#   admission    — the bootstrap renders the three admission policies and their
#                  bindings, with the install's values in their CEL: Template
#                  Operator's ServiceAccount, the config namespace, the tenant
#                  label, the API host, the issuer, the group pattern and the
#                  reserved names; admission.enabled=false renders none, and a
#                  near-miss value fails.
#   vcopolicy    — charts/examples/vco-admin-policy.hcl (production) and the lab
#                  policy differ only by delete on the kv mounts; neither grants
#                  a wildcard over sys/policy, sys/mounts, sys/auth or auth, nor
#                  VCO's own login mount or policy; every mount pins its type.
#   release      — hack/release-chart.sh, against a stub helm: a published
#                  version is skipped (no push), an explicit not-found is
#                  pushed, anything else fails without pushing.
#   bumpcheck    — hack/version-bump-check.sh in a scratch git repo.
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

# union
sort "$WORK/core.ids" "$WORK/eso.ids" > "$WORK/union.ids"
diff "$WORK/union.ids" "$WORK/all.ids" > /dev/null \
  && check union 0 \
  || check union 1 "core ∪ eso ≠ all: $(diff "$WORK/union.ids" "$WORK/all.ids" | head -4 | tr '\n' ' ')"

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
for f in all.raw fx-guards.raw fx-no-optins.raw fx-no-workloads.raw; do
  v="$(scope_violations "$WORK/$f" dev)"
  [ -z "$v" ] || { ps_ok=1; ps_detail="$ps_detail [$f: $(tr '\n' '|' <<<"$v")]"; }
done
yqs npol 'select(.kind == "Policy") | .metadata.name' "$WORK/all.raw"
[ "$(lines "$npol")" -ge 4 ] || { ps_ok=1; ps_detail="$ps_detail [values-full rendered $(lines "$npol") policies — the check proves nothing]"; }
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

# mountagree
ma_ok=0; ma_detail=""
yqs m_auth 'select(.kind == "AuthEngineMount" and .spec.type == "kubernetes") | .spec.path + "/" + .spec.name' "$WORK/all.raw"
yqs m_cfg 'select(.kind == "KubernetesAuthEngineConfig") | .spec.path + "/" + .spec.name' "$WORK/all.raw"
yqs m_roles 'select(.kind == "KubernetesAuthEngineRole") | .spec.path' "$WORK/all.raw"
yqs m_cms 'select(.kind == "ConfigMap" and (.data | has("VAULT_K8S_MOUNT"))) | .data.VAULT_K8S_MOUNT' "$WORK/all.raw"
for pair in "AuthEngineMount:$m_auth" "KubernetesAuthEngineConfig:$m_cfg" "roles:$(sort -u <<<"$m_roles")" "VAULT_K8S_MOUNT:$(sort -u <<<"$m_cms")"; do
  [ "${pair#*:}" = team-a/kubernetes/workloads ] || { ma_ok=1; ma_detail="$ma_detail [${pair%%:*}: '$(echo "${pair#*:}" | tr '\n' ' ')']"; }
done
yqs vns 'select(.kind == "ConfigMap" and (.metadata.name | test("^vault-config-")) and (.data | has("VAULT_K8S_MOUNT"))) | .metadata.name + "=" + (.data.VAULT_NAMESPACE | tostring)' "$WORK/all.raw"
[ -n "$vns" ] || { ma_ok=1; ma_detail="$ma_detail [no vault-config ConfigMap — the check proves nothing]"; }
bad="$(grep -v '=$' <<<"$vns" || true)"
[ -z "$bad" ] || { ma_ok=1; ma_detail="$ma_detail [VAULT_NAMESPACE not empty: $(tr '\n' ' ' <<<"$bad")]"; }
check mountagree "$ma_ok" "$ma_detail"

# guards
gd_ok=0; gd_detail=""
for pair in \
  "g-role-only:kv is not" "g-no-role:role is not set" "g-bad-role:is not a known role" \
  "g-transit:is not supported" "g-injection:is not a valid app name" "g-wildcard:is not a valid app name" \
  "g-reserved:is not a valid app name" "g-claimed:claimed by more than one" "g-claimer:claimed by more than one" \
  "default:cannot be granted Vault access" "g-unknown-key:unknown annotation" "g-bad-bool:must be" \
  "g-app-only:no app identity is registered" "g.dotted:cannot be used with Vault"; do
  sa="${pair%%:*}"; msg="${pair#*:}"
  yqs err "select(.kind == \"ConfigMap\" and .metadata.name == \"vault-config-$sa.error\") | .data.ERROR" "$WORK/fx-guards.raw"
  grep -q -- "$msg" <<<"$err" \
    || { gd_ok=1; gd_detail="$gd_detail [$sa: no error ConfigMap saying '$msg']"; }
  yqs hit "select(.kind == \"Policy\" and (.metadata.name | test(\"[.]$sa\$\"))) | .metadata.name" "$WORK/fx-guards.raw"
  [ -n "$hit" ] \
    && { gd_ok=1; gd_detail="$gd_detail [$sa: a Policy rendered despite the error]"; }
done
# Positive controls in the other namespace.
for sa in good-sa hostile-sa; do
  yqs hit "select(.kind == \"Policy\" and .metadata.name == \"kv.team-a.team-a-prod.$sa\") | .metadata.name" "$WORK/fx-guards.raw"
  [ -n "$hit" ] \
    || { gd_ok=1; gd_detail="$gd_detail [$sa: correct SA rendered no Policy — one namespace's error froze another]"; }
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
check namecollide "$nc_ok" "$nc_detail"

# ─── The parent gotemplate, through a shim chart ─────────────────────────────
mkdir -p "$WORK/shim/templates" "$WORK/shim/files"
cp "$BOOTSTRAP/files/parent-gotemplate.tpl" "$WORK/shim/files/"
printf 'apiVersion: v2\nname: shim\nversion: 0.0.1\n' > "$WORK/shim/Chart.yaml"
printf '{{ tpl ($.Files.Get "files/parent-gotemplate.tpl") (dict "parameters" .Values.parameters) }}\n' > "$WORK/shim/templates/render.yaml"
# The parameters are the bootstrap's own: read from its rendered parent
# Template, so a parameter renamed on one side cannot pass here.
"$HELM" template b "$BOOTSTRAP" -n "$NS" > "$WORK/boot-default.yaml" 2>"$WORK/boot.err" \
  || { echo "FAIL  setup — the bootstrap did not render: $(first "$WORK/boot.err")"; exit 1; }
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
    # a DNS label of 64 characters (over the 63-char label value cap)
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
want_skipped="agent-registry auth cubbyhole has.dot identity kubernetes secret shared sys tenant-name-of-sixty-four-characters-which-is-one-over-the-cap-x token "
[ "$(sort <<<"$skipped" | tr '\n' ' ')" = "$want_skipped" ] || { rs_ok=1; rs_detail="$rs_detail [skipped-tenants lists '$(sort <<<"$skipped" | tr '\n' ' ')', want $want_skipped]"; }
yqs why "select(.kind == \"ConfigMap\" and .metadata.name == \"$P-skipped-tenants\") | .data.kubernetes" "$WORK/emit-enabled.yaml"
grep -q 'Vault refuses a mount nested under another' <<<"$why" || { rs_ok=1; rs_detail="$rs_detail [the reason for kubernetes does not name the nesting: '$why']"; }
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
  "SecretEngineMount/empty-tenant-kv empty-tenant/kv" "SecretEngineMount/1234-kv 1234/kv" | sort | tr '\n' ' ')"
[ "$(sort <<<"$pkinds" | tr '\n' ' ')" = "$want_pm" ] || { pm_ok=1; pm_detail="$pm_detail [parent VCO objects: want $want_pm got $(sort <<<"$pkinds" | tr '\n' ' ')]"; }
yqs pmtypes 'select(.kind == "SecretEngineMount") | .spec.type + "/" + .spec.options.version' "$WORK/emit-enabled.yaml"
[ "$(sort -u <<<"$pmtypes")" = "kv/2" ] || { pm_ok=1; pm_detail="$pm_detail [a secrets mount is not kv version 2: $(sort -u <<<"$pmtypes" | tr '\n' ' ')]"; }
yqs pmlabels 'select(.kind == "SecretEngineMount" and .metadata.name != "shared-kv") | .metadata.name + "=" + .metadata.labels."stakater.com/tenant"' "$WORK/emit-enabled.yaml"
for t in team-a team-b empty-tenant 1234; do
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
tg_case() { # tg_case <chart-dir-name> <values-arg> <label>
  for variant in noschema notpl; do
    if "$HELM" template x "$WORK/$variant/$1" -n "$NS" $2 > /dev/null 2>"$WORK/tg.err"; then
      tg_ok=1; tg_detail="$tg_detail [$3 accepted with $variant]"
    fi
  done
}
tg_case boot "--set parent.eso=true" "parent.eso=true"
tg_case boot "--set parent.sso.enabled=yes" "parent.sso.enabled=yes"
tg_case boot "--set-string sync.mode=on" "sync.mode=on"
for variant in noschema notpl; do
  "$HELM" template x "$WORK/$variant/boot" -n "$NS" --set parent.eso=disabled --set-string parent.sso.enabled=true --set parent.sso.issuerUrl=https://idp > /dev/null 2>"$WORK/tg.err" \
    || { tg_ok=1; tg_detail="$tg_detail [canonical bootstrap values rejected with $variant: $(first "$WORK/tg.err")]"; }
done
check toggles "$tg_ok" "$tg_detail"

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
printf 'parent:\n  sso: null\n  token: null\n' > "$WORK/pp-null.yaml"
"$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/pp-null.yaml" > "$WORK/pp-null.out" 2>&1 \
  || { pp_ok=1; pp_detail="$pp_detail [a nulled parent.sso/token failed the render: $(first "$WORK/pp-null.out")]"; }
check parentplumb "$pp_ok" "$pp_detail"

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
printf 'tenantValues:\n  sso:\n    tenantGroupTemplate: "{{ .x }}"\n' > "$WORK/tv-braces.yaml"
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
for p in origin scope cluster; do
  grep -qx "$P-vco-$p" <<<"$vaps" || { ad_ok=1; ad_detail="$ad_detail [no admission policy $P-vco-$p]"; }
  grep -qx "$P-vco-$p=$P-vco-$p=Deny" <<<"$vapbs" || { ad_ok=1; ad_detail="$ad_detail [no Deny binding for $P-vco-$p]"; }
done
yqs fp 'select(.kind == "ValidatingAdmissionPolicy") | .spec.failurePolicy' "$WORK/boot-default.yaml"
[ "$(sort -u <<<"$fp")" = Fail ] || { ad_ok=1; ad_detail="$ad_detail [failurePolicy is not Fail everywhere: $(sort -u <<<"$fp" | tr '\n' ' ')]"; }
cat > "$WORK/ad.yaml" <<'YAML'
configNamespace: cfg-x
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
  "https://idp.example.com/realms/x" "'admin': 'ops-{tenant}'" "'editor': 'grp-{tenant}-{role}'" "'platform-x'" "'rev-sa'"; do
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
for f in "$PROD" "$LAB"; do
  paths="$(grep -oE '^path "[^"]+"' "$f" | sed -e 's/^path "//' -e 's/"$//')"
  [ "$(lines "$paths")" -ge 15 ] || { vp_ok=1; vp_detail="$vp_detail [$(basename "$f"): only $(lines "$paths") paths — the check proves nothing]"; }
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
          published) echo "name: x"; exit 0 ;;
          notfound)  echo "Error: ghcr.io/x: not found" >&2; exit 1 ;;
          *)         echo "Error: unauthorized: authentication required" >&2; exit 1 ;;
        esac ;;
  package) mkdir -p "$4"; touch "$4/$(awk '/^name:/{print $2; exit}' "$2/Chart.yaml")-$(awk '/^version:/{print $2; exit}' "$2/Chart.yaml").tgz" ;;
  push) exit 0 ;;
esac
STUB
chmod +x "$WORK/stub/helm"
rl_case() { # rl_case <mode> <expect-exit 0|1> <expect-push yes|no>
  local rc=0
  : > "$WORK/stub.log"
  (cd "$WORK" && STUB_MODE="$1" STUB_LOG="$WORK/stub.log" HELM="$WORK/stub/helm" \
     bash -e "$REPO_ROOT/hack/release-chart.sh" "$CHART" ghcr.io/example/charts) > "$WORK/rl.out" 2>&1 || rc=$?
  [ "$rc" -eq "$2" ] || rl_detail="$rl_detail [$1: exit $rc, want $2: $(first "$WORK/rl.out")]"
  if grep -q '^push ' "$WORK/stub.log"; then pushed=yes; else pushed=no; fi
  [ "$pushed" = "$3" ] || rl_detail="$rl_detail [$1: pushed=$pushed, want $3]"
}
rl_case published 0 no
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
  (cd "$G" && git -c user.email=t@t -c user.name=t commit -qam "$1" --allow-empty && "$REPO_ROOT/hack/version-bump-check.sh" main charts/a charts/b charts/c) > "$WORK/bc.out" 2>&1 || rc=$?
  [ "$rc" -eq "$2" ] || bc_detail="$bc_detail [$1: exit $rc, want $2: $(tail -1 "$WORK/bc.out")]"
}
bc_case unchanged 0
printf 'x: 1\n' > "$G/charts/a/values.yaml"; git -C "$G" add charts/a/values.yaml
bc_case changed-no-bump 1
sed -i.bak 's/^version: 0.1.0/version: 0.1.1/' "$G/charts/a/Chart.yaml" && rm -f "$G/charts/a/Chart.yaml.bak"
bc_case changed-with-bump 0
mkdir -p "$G/charts/c" && printf 'name: c\nversion: 0.0.1\n' > "$G/charts/c/Chart.yaml" && git -C "$G" add charts/c
bc_case new-chart 0
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
