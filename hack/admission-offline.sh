#!/usr/bin/env bash
# The bootstrap chart's admission policies, offline: render them, write the
# cases of hack/lab/admission-cases.sh (EMIT mode), and run the cases through
# k8s.io/apiserver's own ValidatingAdmissionPolicy plugin (hack/admission-eval).
# No cluster: this is what `make verify` runs, so a CEL change that breaks a
# rule fails here, not only on the lab.
#
# The install's values are the chart defaults plus SSO with an issuer, so the
# OIDC cases run. ADMISSION_EVAL names a prebuilt hack/admission-eval binary
# (hack/mutation_tests.py builds it once); otherwise it is built here.
#
# CASES is the exact number of cases admission-cases.sh writes: a case lost
# (a function that stops early, a section skipped) fails the run. Change it
# with the cases.
#
# Usage: hack/admission-offline.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELM="${HELM:-helm}"
ISSUER=https://idp.example.com/realms/mto
TOV_USER=system:serviceaccount:stakater-template-operator:template-operator-template-operator-v2
CASES=77

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$HELM" template b "$REPO_ROOT/charts/mto-extension-vault-community-bootstrap" -n vault-config \
  --set parent.sso.enabled=true --set "parent.sso.issuerUrl=$ISSUER" > "$WORK/boot.yaml" 2>"$WORK/err" \
  || { echo "FAIL  infra — the bootstrap did not render: $(head -1 "$WORK/err")"; exit 1; }
# The cases name Template Operator by the chart's default identity.
grep -qF "'$TOV_USER'" "$WORK/boot.yaml" \
  || { echo "FAIL  infra — the rendered policies do not name $TOV_USER: the origin cases would prove nothing"; exit 1; }
EMIT="$WORK/cases" ISSUER="$ISSUER" TOV_USER="$TOV_USER" bash "$REPO_ROOT/hack/lab/admission-cases.sh" > "$WORK/emit.out" \
  || { echo "FAIL  infra — admission-cases.sh did not write its cases: $(tail -3 "$WORK/emit.out")"; exit 1; }
if [ -n "${ADMISSION_EVAL:-}" ]; then
  "$ADMISSION_EVAL" -cases "$CASES" "$WORK/boot.yaml" "$WORK/cases"
else
  (cd "$REPO_ROOT" && go run ./hack/admission-eval -cases "$CASES" "$WORK/boot.yaml" "$WORK/cases")
fi
