#!/usr/bin/env bash
# Print the workload contract of a tenant chart: what an app team writes and
# reads, with every fixture value replaced by a placeholder, one sorted line
# per item. Run on this chart and on the Enterprise chart with the SAME
# fixture (embedded here), so the two outputs compare line by line.
#
#   annotation.serviceaccount <key>    the keys the chart accepts on a ServiceAccount
#   annotation.deployment <form>       the forms it accepts on a Deployment
#   role <name>                        the roleCaps keys
#   object <Kind> <namespace>/<name>   every object rendered
#   configmap.key <KEY>                every key of a vault-config-<sa> ConfigMap
#
# The annotation lists are read from the chart's own refusal of an unknown key,
# so they are the lists the chart enforces, not a copy.
#
# Usage: hack/contract.sh <tenant-chart-dir>
set -euo pipefail

CHART="${1:?usage: hack/contract.sh <tenant-chart-dir>}"
HELM="${HELM:-helm}"
YQ="${YQ:-yq}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/fixture.yaml" <<'EOF'
tenant: team-a
knownTenants: "team-a,team-b"
eso: enabled
vaultCABundle: |
  -----BEGIN CERTIFICATE-----
  CONTRACTFIXTURE
  -----END CERTIFICATE-----
sso:
  enabled: true
  oidc:
    issuerUrl: "https://idp.example.com"
monitoring:
  enabled: true
# One ServiceAccount per feature, so a feature a chart lacks drops only its
# own lines.
serviceAccounts:
  - metadata: { name: app-a, namespace: team-a-dev, annotations: { vault.stakater.com/kv: "true", vault.stakater.com/role: editor, vault.stakater.com/app: payments } }
  - metadata: { name: app-b, namespace: team-a-tools, annotations: { vault.stakater.com/kv: "true", vault.stakater.com/role: admin } }
  - metadata: { name: app-sub, namespace: team-a-dev, annotations: { vault.stakater.com/kv: "true", vault.stakater.com/role: viewer, vault.stakater.com/kv-subscribe-ns: team-a-tools } }
  - metadata: { name: app-out, namespace: team-a-dev, annotations: { vault.stakater.com/kv: "true", vault.stakater.com/role: editor, vault.stakater.com/kv-export-tenant: team-b } }
  - metadata: { name: app-in, namespace: team-a-dev, annotations: { vault.stakater.com/kv: "true", vault.stakater.com/role: viewer, vault.stakater.com/kv-import-tenant: team-b } }
  - metadata: { name: probe, namespace: team-a-dev, annotations: { vault.stakater.com/kv: "true", vault.stakater.com/role: editor, vault.stakater.com/zz-probe: x } }
deployments:
  - metadata: { name: web, namespace: team-a-dev, annotations: { vault.stakater.com/kv-secret.web-db: "db#password" } }
    spec: { template: { spec: { serviceAccountName: app-a } } }
  - metadata: { name: sub-d, namespace: team-a-dev, annotations: { vault.stakater.com/kv-subscribe.tools-shared: "team-a-tools/item" } }
    spec: { template: { spec: { serviceAccountName: app-sub } } }
  - metadata: { name: imp-d, namespace: team-a-dev, annotations: { vault.stakater.com/kv-import.partner: "team-b/item" } }
    spec: { template: { spec: { serviceAccountName: app-in } } }
  - metadata: { name: probe-d, namespace: team-a-dev, annotations: { vault.stakater.com/zz.probe: x } }
    spec: { template: { spec: { serviceAccountName: app-a } } }
EOF

# Render on its own line: a failed render must not become an empty contract.
"$HELM" template contract "$CHART" -n vault-config -f "$WORK/fixture.yaml" > "$WORK/r.yaml" 2>"$WORK/r.err" \
  || { echo "contract: $CHART did not render: $(head -1 "$WORK/r.err")" >&2; exit 1; }

placeholders() {
  sed -E \
    -e 's/mto-extension-vault-(enterprise|community)/<extension>/g' \
    -e 's/TEAM_A_TOOLS/<NS>/g; s/TEAM_A_DEV/<NS>/g; s/TEAM_B/<PEER>/g' \
    -e 's/team-a-(dev|tools)/<ns>/g; s/team-a/<tenant>/g; s/team-b/<peer>/g' \
    -e 's/app-(a|b|sub|out|in)/<sa>/g; s/payments/<app>/g' \
    -e 's/-(web-db|tools-shared|partner)$/-<name>/'
}

{
  sa_err="$("$YQ" e -N 'select(.kind == "ConfigMap" and .metadata.name == "vault-config-probe.error") | .data.ERROR' "$WORK/r.yaml")"
  keys="$(grep -o 'Valid keys: .*' <<<"$sa_err" | sed 's/^Valid keys: //')"
  [ -n "$keys" ] || { echo "contract: no 'Valid keys' in the probe ServiceAccount's error" >&2; exit 1; }
  tr ',' '\n' <<<"$keys" | sed -e 's/^ *//' -e 's/ *$//' | grep . | sed 's/^/annotation.serviceaccount /'

  d_err="$("$YQ" e -N 'select(.kind == "ConfigMap" and .metadata.name == "vault-config-probe-d.deploy-error") | .data.ERROR' "$WORK/r.yaml")"
  forms="$(grep -oE 'vault\.stakater\.com/[a-z-]+\.<name>' <<<"$d_err" | sed 's#vault.stakater.com/##' | sort -u)"
  [ -n "$forms" ] || { echo "contract: no Deployment forms in the probe Deployment's error" >&2; exit 1; }
  sed 's/^/annotation.deployment /' <<<"$forms"

  "$YQ" e -N '.roleCaps | keys | .[]' "$CHART/values.yaml" | sed 's/^/role /'

  "$YQ" e -N 'select(.kind != null) | select(.metadata.name | test("^vault-config-probe") | not) | "object " + .kind + " " + .metadata.namespace + "/" + .metadata.name' "$WORK/r.yaml" | placeholders

  "$YQ" e -N 'select(.kind == "ConfigMap" and (.metadata.name | test("^vault-config-")) and (.metadata.name | test("[.]") | not)) | .data | keys | .[]' "$WORK/r.yaml" \
    | placeholders | sed 's/^/configmap.key /'
} | sort -u
