#!/usr/bin/env bash
# The bootstrap chart's admission policies, offline: render them, write the
# cases of hack/lab/admission-cases.sh (EMIT mode), and run the cases through
# k8s.io/apiserver's own ValidatingAdmissionPolicy plugin (hack/admission-eval).
# No cluster: this is what `make verify` runs, so a CEL change that breaks a
# rule fails here, not only on the lab.
#
# The install's values are the chart defaults plus SSO with an issuer, so the
# OIDC cases run, and a reviewer ServiceAccount. ADMISSION_EVAL names a
# prebuilt hack/admission-eval binary (hack/mutation_tests.py builds it once);
# otherwise it is built here.
#
# CASES is the exact number of cases admission-cases.sh writes: a case lost
# (a function that stops early, a section skipped) fails the run. Change it
# with the cases.
#
# Then the charts' own render meets the same CEL: for each install value set
# below, the bootstrap, the parent and the tenant chart (core and eso, with
# the workloads of hack/render-fixtures/values-full.yaml) render as Template
# Operator renders them, and every VCO CR runs as an admit case, written by
# Template Operator with its source label. A value the install accepts must
# give objects the policies admit (C.21).
#
# Usage: hack/admission-offline.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM:-helm}"
YQ="${YQ:-$(command -v "$REPO_ROOT/bin/yq" || command -v yq || true)}"
[ -n "$YQ" ] || { echo "FAIL  infra — no yq: set YQ, or run make yq"; exit 1; }
BOOT="$REPO_ROOT/charts/mto-extension-vault-community-bootstrap"
TENANT_CHART="$REPO_ROOT/charts/mto-extension-vault-community"
ISSUER=https://idp.example.com/realms/mto
TOV_USER=system:serviceaccount:stakater-template-operator:template-operator-template-operator-v2
CASES=109

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

EVAL="${ADMISSION_EVAL:-}"
if [ -z "$EVAL" ]; then
  EVAL="$WORK/admission-eval"
  (cd "$REPO_ROOT" && go build -o "$EVAL" ./hack/admission-eval) \
    || { echo "FAIL  infra — cannot build hack/admission-eval"; exit 1; }
fi

# A reviewer ServiceAccount is set, so the rule that admits the CRD's default
# empty reviewer name is not the same as the one that admits the install's.
"$HELM" template b "$BOOT" -n vault-config \
  --set parent.sso.enabled=true --set "parent.sso.issuerUrl=$ISSUER" \
  --set kubernetesAuth.tokenReviewerServiceAccount=vault-token-reviewer > "$WORK/boot.yaml" 2>"$WORK/err" \
  || { echo "FAIL  infra — the bootstrap did not render: $(head -1 "$WORK/err")"; exit 1; }
# The cases name Template Operator by the chart's default identity.
grep -qF "'$TOV_USER'" "$WORK/boot.yaml" \
  || { echo "FAIL  infra — the rendered policies do not name $TOV_USER: the origin cases would prove nothing"; exit 1; }
EMIT="$WORK/cases" ISSUER="$ISSUER" TOV_USER="$TOV_USER" bash "$REPO_ROOT/hack/lab/admission-cases.sh" > "$WORK/emit.out" \
  || { echo "FAIL  infra — admission-cases.sh did not write its cases: $(tail -3 "$WORK/emit.out")"; exit 1; }
"$EVAL" -cases "$CASES" "$WORK/boot.yaml" "$WORK/cases"

# ── The charts' own render ──────────────────────────────────────────────────
# The parent renders through helm's tpl, as the render tests render it.
mkdir -p "$WORK/shim/templates" "$WORK/shim/files"
cp "$BOOT/files/parent-gotemplate.tpl" "$WORK/shim/files/"
printf 'apiVersion: v2\nname: shim\nversion: 0.0.1\n' > "$WORK/shim/Chart.yaml"
printf '{{ tpl ($.Files.Get "files/parent-gotemplate.tpl") (dict "parameters" .Values.parameters) }}\n' > "$WORK/shim/templates/render.yaml"
# One tenant's own values, as the parent fills them in each child valuesTemplate.
"$YQ" e '{"tenant": .tenant, "knownTenants": .knownTenants, "serviceAccounts": .serviceAccounts, "deployments": .deployments}' \
  "$REPO_ROOT/hack/render-fixtures/values-full.yaml" > "$WORK/tenant.yaml"
tenant=$("$YQ" e '.tenant' "$WORK/tenant.yaml")

rendered() { # rendered <label> <bootstrap values file> <VCO CRs it must render>
  local label=$1 d="$WORK/r-$1" cfg tov lk slice n f
  mkdir -p "$d/cases" "$d/docs"
  "$HELM" template b "$BOOT" -n vault-config --set parent.sso.enabled=true --set "parent.sso.issuerUrl=$ISSUER" \
    -f "$2" > "$d/boot.yaml" 2>"$d/err" \
    || { echo "FAIL  infra — $label: the bootstrap did not render: $(head -1 "$d/err")"; exit 1; }
  # Read to the end, then the first line: a pipe into head would stop yq,
  # and pipefail would read that as a failure.
  cfg=$("$YQ" e -N 'select(.kind == "ValidatingAdmissionPolicy") | .spec.matchConstraints.namespaceSelector.matchLabels."kubernetes.io/metadata.name"' "$d/boot.yaml")
  cfg=${cfg%%$'\n'*}
  tov=$(grep -o -m1 "system:serviceaccount:[a-z0-9.-]*:[a-z0-9.-]*" "$d/boot.yaml" || true)
  [ -n "$cfg" ] && [ -n "$tov" ] || { echo "FAIL  infra — $label: no config namespace or Template Operator identity in the policies"; exit 1; }
  : >"$d/all.yaml"
  for slice in mto-extension-vault-community mto-extension-vault-community-eso; do
    "$YQ" e "select(.kind == \"Template\" and .metadata.name == \"$slice\") | .spec.helm.valuesTemplate" "$d/boot.yaml" \
      | { grep -v '{{' || true; } > "$d/iw.yaml"
    [ -s "$d/iw.yaml" ] || { echo "FAIL  rendered $label: no child Template $slice"; exit 1; }
    "$HELM" template mto-extension-vault-community "$TENANT_CHART" -n "$cfg" -f "$d/iw.yaml" -f "$WORK/tenant.yaml" \
      >> "$d/all.yaml" 2>"$d/err" \
      || { echo "FAIL  rendered $label: the tenant chart ($slice) did not render: $(head -1 "$d/err")"; exit 1; }
    echo "---" >> "$d/all.yaml"
  done
  # The parent: the bootstrap's own parameters, the tenant, and one namespace
  # carrying the install's tenant label.
  "$YQ" e -N "select(.kind == \"Template\" and .metadata.name == \"mto-extension-vault-community-parent\")
           | {\"parameters\": (.spec.parameters | map(select(has(\"value\"))) | map({\"key\": .name, \"value\": .value}) | from_entries)}" \
    "$d/boot.yaml" > "$d/parent-values.yaml"
  lk=$("$YQ" e '.parameters.tenantLabelKey' "$d/parent-values.yaml")
  LK="$lk" T="$tenant" "$YQ" e -n '.parameters.tenants = [{"metadata": {"name": strenv(T)}}]
    | .parameters.tenantNamespaces = [{"metadata": {"name": strenv(T) + "-dev", "labels": {}}}]
    | .parameters.tenantNamespaces[0].metadata.labels[strenv(LK)] = strenv(T)' > "$d/parent-tenants.yaml"
  "$HELM" template shim "$WORK/shim" -f "$d/parent-values.yaml" -f "$d/parent-tenants.yaml" >> "$d/all.yaml" 2>"$d/err" \
    || { echo "FAIL  rendered $label: the parent did not render: $(head -1 "$d/err")"; exit 1; }
  # Every VCO CR, as Template Operator writes it: with its source label.
  (cd "$d/docs" && CFG="$cfg" "$YQ" e "select(.apiVersion == \"redhatcop.redhat.io/v1alpha1\")
      | .metadata.labels.\"templates.v2.stakater.com/instance-namespace\" = strenv(CFG)" ../all.yaml \
    | "$YQ" e -s '"d" + ($index | tostring)' -)
  n=0
  for f in "$d"/docs/*.yml; do
    [ -e "$f" ] || break
    n=$((n + 1))
    { printf '# want: admit\n# what: rendered %s: %s\n# as: %s\n---\n' "$label" "$("$YQ" e '.kind + "/" + .metadata.name' "$f")" "$tov"
      cat "$f"; } > "$d/cases/$(printf '%03d' "$n").yaml"
  done
  # The exact number, as CASES: a render that lost its parent, its SSO or a
  # workload's CRs, and still passes, proves nothing.
  [ "$n" = "$3" ] || { echo "FAIL  rendered $label: $n VCO CRs rendered, want exactly $3"; exit 1; }
  echo "== rendered $label: $n VCO CRs"
  "$EVAL" -cases "$n" "$d/boot.yaml" "$d/cases"
}

printf 'kubernetesAuth: {tokenReviewerServiceAccount: vault-token-reviewer}\n' > "$WORK/v-default.yaml"
# Install values that reach a rendered object or the CEL, away from their
# defaults: other names, mounts with a / around them, a role that YAML reads
# as a number, another API host, label key, shared name, reserved path, group
# pattern and role list. The issuer stays the cases' own.
cat > "$WORK/v-custom.yaml" <<'EOF'
configNamespace: vault-system
templateOperator: { namespace: tov-ns, serviceAccountName: tov-sa }
vco: { authPath: /vault-login/, role: "123", serviceAccount: vco-x }
kubernetesAuth: { path: /k8s/, name: apps/, tokenReviewerServiceAccount: reviewer-x, kubernetesHost: "https://api.example.com:6443" }
parent: { env: prod, tenantLabelKey: example.com/team, sharedTenantName: commons, externalSecretRefreshInterval: "0", reservedPaths: [platform] }
tenantValues:
  roleCaps: { ops: '["read", "list"]' }
  sso:
    roles: [admin, ops]
    tenantGroupTemplate: "grp_{tenant}.{role}"
    tenantRoleMapping: { admin: { pattern: "{tenant}_admins" } }
    mount: { path: /sso-x/, name: login/ }
EOF
# default: the parent's 2 kv mounts; 2 auth mounts, 2 configs, 6 workload
# roles and policies each, 4 SSO roles and policies each.
rendered default "$WORK/v-default.yaml" 26
# custom: as default, with 2 SSO roles.
rendered custom "$WORK/v-custom.yaml" 22
