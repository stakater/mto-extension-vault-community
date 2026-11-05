"""Every guard listed here, weakened in turn, must make the check it names fail.

A check that stays green when its guard is removed proves nothing, and a
guard "killed" by some other failure (a template crash, an unrelated check)
proves nothing about the check that should have caught it. So each mutation
names the check that must fail, and is killed only when that check reports
FAIL:

  render     hack/chart-render-tests.sh   expect: the check's name  (FAIL  <name>)
  admission  hack/admission-offline.sh    expect: text of the FAIL line (a case's description, or "compile")
  method     unittest discover -s hack    expect: the test's name   (FAIL: <name> / ERROR: <name>)

A render check's FAIL line lists its failed cases. A case that failed with
another message ("failed elsewhere") or a template or shell crash is no
evidence for the mutation: such a line is a kill only when it also holds the
mutation's `detail`, the text of its own case (for example "[platform-one
rendered"). A parse error in a chart never reaches a check: the harness
renders every chart at setup and stops there.

Each mutation is an exact text replacement in a copy of the working tree. It
must apply, or the run fails: a guard that moved needs its mutation moved too.
count=1 replaces the only match, and a text that matches more than once fails
the run (the mutation would weaken one copy of several, unseen);
count="all" replaces every match. A suite that hangs is stopped after
SUITE_TIMEOUT seconds and counts as a failure of the run.

A new guard adds its mutation here (docs/method.md, "Every guard
mutation-tested"): the docs promise mutation-tested guards only for the
guards listed here.

Usage: HELM=helm YQ=yq python3 hack/mutation_tests.py [-j N] [id ...]
"""

import argparse
import concurrent.futures
import os
import queue
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUITE_TIMEOUT = 900
ADM = "charts/mto-extension-vault-community-bootstrap/templates/50-admission.yaml"
BOOT_HELPERS = "charts/mto-extension-vault-community-bootstrap/templates/_helpers.tpl"
BOOT_SCHEMA = "charts/mto-extension-vault-community-bootstrap/values.schema.json"
PARENT = "charts/mto-extension-vault-community-bootstrap/files/parent-gotemplate.tpl"
HELPERS = "charts/mto-extension-vault-community/templates/_helpers.tpl"
OWN = "charts/mto-extension-vault-community/templates/04-sa-own-tenant.yaml"
SHARE_IN = "charts/mto-extension-vault-community/templates/04-sa-share-in.yaml"
SSO = "charts/mto-extension-vault-community/templates/07-sso-policies.yaml"
VCO_POLICIES = ["charts/examples/vco-admin-policy.hcl", "hack/lab/vco-admin-policy.hcl"]
NOT_DELETING = "    - name: not-deleting\n      expression: {{ $notDeleting | quote }}\n"
# The deletion exemption as C.20 writes it, and as C.18 wrote it (a CR
# without a spec on both sides was refused).
EXEMPT = ('"!has(object.metadata.deletionTimestamp) || has(object.spec) != has(oldObject.spec) || '
          '(has(object.spec) && object.spec != oldObject.spec)"')
EXEMPT_C18 = '"!has(object.metadata.deletionTimestamp) || !has(object.spec) || !has(oldObject.spec) || object.spec != oldObject.spec"'


# In a render check's FAIL line: a case refused by another guard, or a crash.
WEAK = ("failed elsewhere", 'executing "', "parse error", "syntax error", "nil pointer", "can't evaluate field",
        "wrong type for value", "index out of range", "command not found")


def m(mid, suite, files, old, new, expect, count=1, detail=None):
    return {"id": mid, "suite": suite, "files": files if isinstance(files, list) else [files],
            "old": old, "new": new, "expect": expect, "count": count, "detail": detail}


def install_entry(name):
    """Replace one entry of installChecks' list with one that always passes,
    keeping the line's end (the last entry closes the list)."""
    line = next(l for l in open(os.path.join(ROOT, BOOT_HELPERS), encoding="utf-8")
                if l.strip().startswith(f'(list "{name}" '))
    indent = line[:len(line) - len(line.lstrip())]
    end = " -}}" if line.rstrip().endswith("-}}") else ""
    return m(f"install-{name}", "render", BOOT_HELPERS, line, f'{indent}(list "removed" "x" $label){end}\n', "installvalues")


MUTATIONS = [
    # ── The admission CEL (50-admission.yaml) ──
    m("cel-kv-prefix", "admission", ADM, "variables.fam == 'kv' ? p.matches(variables.kvRe) :",
      "variables.fam == 'kv' ? p.startsWith(variables.t) :", "a tenant segment not closed by /"),
    m("cel-sudo", "admission", ADM, " && !l.contains('\"sudo\"'))", ")", "sudo on its own path"),
    m("cel-role-label", "admission", ADM, "object.spec.targetNamespaces.targetNamespaceSelector.matchLabels ==",
      "true || object.spec.targetNamespaces.targetNamespaceSelector.matchLabels ==", "a namespace bound with another tenant's label"),
    m("cel-sso-group", "admission", ADM, "object.spec.boundClaims.groups ==", "true || object.spec.boundClaims.groups ==",
      "an SSO role for another tenant's group"),
    m("cel-any-kind", "admission", ADM, "    - expression: variables.ours\n", "    - expression: \"true\"\n",
      "a kind the extension does not render"),
    m("cel-has-spec", "admission", ADM, '"!variables.ours || has(object.spec)"', '"true"', "a VCO CR without a spec"),
    m("cel-connection", "admission", ADM, "!variables.ours || !has(object.spec.connection)", "true",
      "a policy in scope that sends VCO's login to another Vault"),
    m("cel-auth-role", "admission", ADM, "object.spec.authentication.role == {{ $vcoRole | squote }} &&", "",
      "a policy that logs in with another role"),
    m("cel-auth-sa", "admission", ADM, "object.spec.authentication.serviceAccount.name == {{ $vcoSA | squote }} &&", "",
      "a policy that logs in as another ServiceAccount"),
    m("cel-auth-namespace", "admission", ADM, "!has(object.spec.authentication.namespace) && ", "",
      "a policy that logs in to a Vault namespace"),
    m("cel-auth-target", "admission", ADM, " && !has(object.spec.authentication.targetNamespace))", ")",
      "a policy that writes into a Vault namespace"),
    m("cel-origin-label", "admission", ADM,
      "- expression: variables.source == '' || variables.source == {{ $cfg | squote }}", "- expression: \"true\"",
      "written by another identity"),
    m("cel-origin-tov", "admission", ADM,
      "- expression: request.userInfo.username != {{ $tovSA | squote }} || variables.source == {{ $cfg | squote }}",
      "- expression: request.userInfo.username != {{ $tovSA | squote }} || true",
      "Template Operator's object without its source label"),
    m("cel-kinds-create-only", "admission", ADM,
      '  name: mto-extension-vault-community-vco-kinds\nspec:\n  failurePolicy: Fail\n  matchConstraints:\n    namespaceSelector:\n'
      '      matchLabels: { kubernetes.io/metadata.name: {{ $cfg | quote }} }\n    resourceRules:\n'
      '      - apiGroups: ["redhatcop.redhat.io"]\n        apiVersions: ["*"]\n        operations: ["CREATE", "UPDATE"]',
      '  name: mto-extension-vault-community-vco-kinds\nspec:\n  failurePolicy: Fail\n  matchConstraints:\n    namespaceSelector:\n'
      '      matchLabels: { kubernetes.io/metadata.name: {{ $cfg | quote }} }\n    resourceRules:\n'
      '      - apiGroups: ["redhatcop.redhat.io"]\n        apiVersions: ["*"]\n        operations: ["CREATE"]',
      "an update that adds a connection"),
    m("cel-origin-create-only", "admission", ADM,
      '  name: mto-extension-vault-community-vco-origin\nspec:\n  failurePolicy: Fail\n  matchConstraints:\n    namespaceSelector:\n'
      '      matchLabels: { kubernetes.io/metadata.name: {{ $cfg | quote }} }\n    resourceRules:\n'
      '      - apiGroups: ["redhatcop.redhat.io"]\n        apiVersions: ["*"]\n        operations: ["CREATE", "UPDATE"]',
      '  name: mto-extension-vault-community-vco-origin\nspec:\n  failurePolicy: Fail\n  matchConstraints:\n    namespaceSelector:\n'
      '      matchLabels: { kubernetes.io/metadata.name: {{ $cfg | quote }} }\n    resourceRules:\n'
      '      - apiGroups: ["redhatcop.redhat.io"]\n        apiVersions: ["*"]\n        operations: ["CREATE"]',
      "Template Operator moves an object to a tenant's TemplateInstance"),
    # The kinds policy's own not-deleting condition: the one before its
    # variable "ours".
    m("cel-kinds-delete", "admission", ADM, NOT_DELETING + "  variables:\n    - name: ours\n",
      "    - name: not-deleting\n      expression: \"!has(object.metadata.deletionTimestamp)\"\n"
      "  variables:\n    - name: ours\n",
      "a connection added during a deletion"),
    m("cel-delete-nospec", "admission", ADM, EXEMPT,
      '"!has(object.metadata.deletionTimestamp) || (has(object.spec) && has(oldObject.spec) && object.spec != oldObject.spec)"',
      "a spec with a connection put back during a deletion"),
    m("cel-delete-both-nospec", "admission", ADM, EXEMPT, EXEMPT_C18,
      "a finalizer removed during a deletion of a CR without a spec"),
    m("cel-policy-type", "admission", ADM, "variables.kind != 'Policy' || !has(object.spec.type)",
      "variables.kind != 'Policy' || true", "a policy with a type"),
    m("cel-cluster-ca", "admission", ADM,
      "(!has(object.spec.kubernetesCACert) || object.spec.kubernetesCACert == params.data['ca.crt'])", "true",
      "a config that trusts another CA"),
    m("cel-cluster-pem", "admission", ADM, "!has(object.spec.PEMKeys) && ", "", "trusts another issuer's keys"),
    m("cel-cluster-issuer", "admission", ADM, "!has(object.spec.issuer) &&", "", "a config that names another issuer"),
    m("cel-cluster-reviewer", "admission", ADM,
      "object.spec.tokenReviewerServiceAccount.name == {{ $reviewer | squote }})", "true)",
      "reviews tokens as another ServiceAccount"),
    m("cel-cluster-local-ca", "admission", ADM,
      "(!has(object.spec.disableLocalCAJWT) || !object.spec.disableLocalCAJWT)", "true", "drops the local CA"),
    m("cel-jwks", "admission", ADM, "!has(object.spec.JWTValidationPubKeys) && !has(object.spec.JWKSURL))", "true)",
      "also trusts another key set"),
    m("cel-auth-headers", "admission", ADM,
      "object.spec.path.split('/')[0] != {{ $shared | squote }} &&\n          variables.noAuditHeaders)",
      "object.spec.path.split('/')[0] != {{ $shared | squote }} &&\n          true)",
      "an auth mount that passes request headers through"),
    m("cel-issuer", "admission", ADM, "object.spec.OIDCDiscoveryURL == {{ $issuer | squote }}", "true",
      "an OIDC config at another issuer"),
    # The runner itself: an expression that does not compile, and one that
    # compiles only on a CEL newer than Kubernetes 1.30's.
    m("cel-compile", "admission", ADM, "messageExpression: \"'name ' + variables.vname",
      "messageExpression: \"'name ' + + variables.vname", "compile"),
    m("cel-too-new", "admission", ADM, "    - expression: variables.ours\n",
      "    - expression: variables.ours && ip('10.0.0.1') != ip('10.0.0.2')\n", "compile"),
    # ── The tenant chart's render-time guards ──
    m("core-only-wildcard", "render", OWN, "  policy: |\n    {{- $body | nindent 4 }}\n",
      "  policy: |\n    {{- $body | nindent 4 }}\n"
      "    {{- if eq $.Values.component \"core\" }}\n    path \"*\" { capabilities = [\"read\"] }{{ end }}\n", "union"),
    m("scope-part-count", "render", HELPERS,
      "{{- if or (not (hasKey $families $fam)) (ne (len $parts) (int (get $families $fam))) -}}",
      "{{- if not (hasKey $families $fam) -}}", "scopebranches", detail="[kv-parts rendered"),
    m("scope-tenant", "render", HELPERS, "{{- if or (lt (len $parts) 2) (ne (index $parts 1) $t) -}}",
      "{{- if lt (len $parts) 2 -}}", "scopebranches"),
    m("scope-part-label", "render", HELPERS, "{{- if not (regexMatch $label $p) -}}", "{{- if false -}}", "scopebranches"),
    m("scope-shared-label", "render", HELPERS, "{{- if not (regexMatch $label $shared) -}}", "{{- if false -}}", "scopebranches"),
    m("scope-stanza", "render", HELPERS, "{{- if not (regexMatch $stanza $l) -}}", "{{- if false -}}", "scopebranches",
      detail="[stanza-bare rendered"),
    m("scope-sudo", "render", HELPERS, '{{- if contains "\\"sudo\\"" $l -}}', "{{- if false -}}", "scopebranches"),
    m("scope-path", "render", HELPERS, "{{- if not $ok -}}", "{{- if false -}}", "scopebranches"),
    m("scope-import-write", "render", HELPERS, '(regexMatch "\\"(create|update|patch|delete)\\"" $l)', "false", "scopebranches"),
    m("scope-share-direction", "render", HELPERS,
      '{{- fail (printf "scope check: share policy %q is neither .out. nor .in." $name) -}}', "", "scopebranches"),
    m("ssogroup-tenant", "render", HELPERS, '{{- if ne (len (splitList "{tenant}" (toString $pattern))) 2 -}}',
      "{{- if false -}}", "ssogroups"),
    m("ssogroup-map", "render", HELPERS,
      '{{- if or (not (kindIs "map" $roleEntry)) (not (eq (len (without (keys $roleEntry) "pattern")) 0)) (and (hasKey $roleEntry "pattern") (not $roleEntry.pattern)) -}}',
      "{{- if false -}}", "ssogroups"),
    m("sso-one-group-tenant", "render", SSO, "{{- if hasKey $groups $group }}", "{{- if false }}", "ssogroups"),
    m("token-max-tenant", "render", HELPERS, "{{- if and $ttl $max (gt (int64 $ttl) (int64 $max)) -}}",
      "{{- if false -}}", "ssogroups"),
    m("quote-sa", "render", OWN, "    - {{ $saName | quote }}", "    - {{ $saName }}", "quoting"),
    m("quote-ns", "render", OWN, "  namespace: {{ $saNs | quote }}", "  namespace: {{ $saNs }}", "quoting", count="all"),
    m("quote-share-sa", "render", SHARE_IN, "    - {{ $saName | quote }}", "    - {{ $saName }}", "quoting"),
    m("mount-name-trim", "render", "charts/mto-extension-vault-community/templates/01-tenant-scaffolding.yaml",
      '  name: {{ trimAll "/" .Values.kubernetesAuth.name | quote }}\n', "  name: {{ .Values.kubernetesAuth.name | quote }}\n",
      "mountagree", count="all"),
    m("sso-mount-name-trim", "render", "charts/mto-extension-vault-community/templates/06-oidc-auth.yaml",
      '  name: {{ trimAll "/" .Values.sso.mount.name | quote }}\n', "  name: {{ .Values.sso.mount.name | quote }}\n",
      "mountagree"),
    m("role-tenant-label", "render", HELPERS,
      "      {{ .ctx.Values.tenantLabelKey }}: {{ .ctx.Values.tenant | quote }}\n", "", "rolebind"),
    # ── The bootstrap's install-time guards ──
    m("sso-pattern-tenant", "render", BOOT_HELPERS, '{{- if ne (len (splitList "{tenant}" $p)) 2 -}}',
      "{{- if false -}}", "ssogroups", detail="[bootstrap platform-one rendered"),
    m("sso-pattern-control", "render", BOOT_HELPERS, '{{- if regexMatch "[[:cntrl:]]" $p -}}', "{{- if false -}}",
      "ssogroups"),
    m("sso-pattern-quote", "render", BOOT_HELPERS,
      '{{- if or (contains "\'" $p) (contains "\\"" $p) (contains "\\\\" $p) -}}', "{{- if false -}}", "installvalues"),
    m("sso-collision", "render", BOOT_HELPERS,
      '{{- $hit := include "mto-extension-vault-community-bootstrap.ssoCollision" (dict "a" $a "b" $b) -}}',
      '{{- $hit := "" -}}', "ssogroups"),
    m("sso-collision-same", "render", BOOT_HELPERS, "{{- if and (not $d) (not $e) -}}", "{{- if false -}}", "ssogroups",
      detail="[bootstrap one-group rendered"),
    m("sso-collision-case1", "render", BOOT_HELPERS,
      "{{- if and (or $d $e) (regexMatch $head $d) (regexMatch $tail $e) -}}", "{{- if false -}}", "ssogroups"),
    m("sso-collision-case2", "render", BOOT_HELPERS,
      '{{- if and (regexMatch $head $d) (regexMatch $tail $e) -}}\n{{- printf "cross:%s%sx%s%s" $p1 $d $e $s2 -}}\n{{- else -}}',
      "{{- if false -}}\n{{- else -}}", "ssogroups", detail="[bootstrap suffix-2 rendered"),
    m("sso-collision-overlap", "render", BOOT_HELPERS, "{{- $meet := and (not $found) (hasPrefix $o $e)",
      "{{- $meet := and false (hasPrefix $o $e)", "ssogroups"),
    m("sso-collision-overlap-one", "render", BOOT_HELPERS, "{{- if and $meet (eq $t1 $t2) -}}", "{{- if false -}}",
      "ssogroups", detail="[bootstrap overlap-one rendered"),
    m("sso-mapping", "render", BOOT_HELPERS,
      '{{- else if or (not (kindIs "map" $e)) (not (eq (len (without (keys $e) "pattern")) 0)) (and (hasKey $e "pattern") (not $e.pattern)) -}}',
      "{{- else if false -}}", "ssogroups"),
    m("sso-mapping-role", "render", BOOT_HELPERS, "{{- else if not (has $k $roles) -}}", "{{- else if false -}}",
      "ssogroups"),
    m("sso-fallback", "render", BOOT_HELPERS, '{{- if ne (toString $e) "deny" -}}', "{{- if false -}}", "ssogroups"),
    m("sso-role-fallback", "render", BOOT_HELPERS, '{{- if eq $role "fallback" -}}', "{{- if false -}}", "ssogroups",
      detail="[bootstrap role-fallback rendered"),
    m("sso-role-twice", "render", BOOT_HELPERS, "{{- if hasKey $seen $role -}}", "{{- if false -}}", "ssogroups",
      detail="[bootstrap role-twice rendered"),
    m("sso-role-caps", "render", BOOT_HELPERS, "{{- if not (has $role $capRoles) -}}", "{{- if false -}}", "ssogroups"),
    m("sso-caps-shape", "render", BOOT_HELPERS,
      '{{- if not (regexMatch "^\\\\[\\"[a-z]+\\"(, \\"[a-z]+\\")*\\\\]$" $cs) -}}', "{{- if false -}}", "ssogroups"),
    m("sso-caps-sudo", "render", BOOT_HELPERS, '{{- if contains "\\"sudo\\"" $cs -}}', "{{- if false -}}", "ssogroups"),
    m("sso-empty-template", "render", BOOT_HELPERS,
      '{{- if and (hasKey $tsso "tenantGroupTemplate") (not $tsso.tenantGroupTemplate) -}}', "{{- if false -}}", "ssogroups"),
    m("install-shared-reserved", "render", BOOT_HELPERS,
      '{{- if or (has $shared $builtin) (has $shared (.Values.parent.reservedPaths | default list)) -}}',
      "{{- if false -}}", "installvalues"),
    m("install-ttl", "render", BOOT_HELPERS,
      "{{- if and $eff.ttl $eff.maxTTL (gt (int64 $eff.ttl) (int64 $eff.maxTTL)) -}}", "{{- if false -}}", "installvalues"),
    m("install-ttl-default", "render", BOOT_HELPERS,
      '{{- $eff := include "mto-extension-vault-community-bootstrap.defaultToken" . | fromYaml -}}',
      "{{- $eff := dict -}}", "installvalues"),
    m("install-mount-overlap", "render", BOOT_HELPERS,
      '{{- if or (eq $k8s $sso) (hasPrefix (printf "%s/" $k8s) $sso) (hasPrefix (printf "%s/" $sso) $k8s) -}}',
      "{{- if false -}}", "installvalues"),
    m("install-mount-nested", "render", BOOT_HELPERS,
      '(hasPrefix (printf "%s/" $k8s) $sso) (hasPrefix (printf "%s/" $sso) $k8s)', "false false", "installvalues"),
    m("install-mount-segment", "render", BOOT_HELPERS, '(hasPrefix (printf "%s/" $sso) $k8s)', "(hasPrefix $sso $k8s)",
      "installvalues", detail="[kubernetesAuth: {path: oidc, name: ssox} was refused"),
    m("install-sso-mount", "render", BOOT_HELPERS, '{{- if hasKey $ssoMount $k -}}', "{{- if false -}}", "installvalues"),
    m("install-vco-role", "render", BOOT_HELPERS,
      '{{- if or (contains "\'" (toString .Values.vco.role)) (contains "\\\\" (toString .Values.vco.role)) (not .Values.vco.role) -}}',
      "{{- if false -}}", "installvalues"),
    *[install_entry(n) for n in ["configNamespace", "templateOperator.namespace", "templateOperator.serviceAccountName",
                                  "vco.serviceAccount", "vco.authPath", "parent.env", "parent.sharedTenantName",
                                  "parent.tenantLabelKey", "kubernetesAuth.path", "kubernetesAuth.name"]],
    m("token-zero", "render", BOOT_HELPERS, '{{- if and (hasKey $src $k) (not (kindIs "invalid" (get $src $k))) -}}',
      "{{- if get $src $k -}}", "parentplumb"),
    m("schema-strict", "render", BOOT_SCHEMA, '"additionalProperties": false', '"additionalProperties": true',
      "schemakeys", count="all"),
    m("schema-strict-sso", "render", BOOT_SCHEMA,
      '"audience": {\n              "description": "Removed: its guard names the fix."\n            }\n          },\n'
      '          "additionalProperties": false',
      '"audience": {\n              "description": "Removed: its guard names the fix."\n            }\n          },\n'
      '          "additionalProperties": true', "schemakeys"),
    m("schema-required", "render", BOOT_SCHEMA, '    "tenantChart",\n', "", "schemakeys"),
    m("schema-tenant-keys", "render", BOOT_SCHEMA, '"knownTenants": {},', "", "tenantvaluekeys"),
    # A closed object replaced by a bare type: it has no properties, so the
    # walk no longer lists it.
    m("schema-node-typed", "render", BOOT_SCHEMA,
      '"clientSecretRef": {\n                  "type": "object",\n                  "properties": {\n'
      '                    "name": {\n                      "type": "string",\n                      "minLength": 1\n'
      '                    },\n                    "key": {\n                      "type": "string",\n'
      '                      "minLength": 1\n                    }\n                  },\n'
      '                  "additionalProperties": false\n                },',
      '"clientSecretRef": {\n                  "type": ["object", "null"]\n                },', "schemakeys"),
    m("schema-tenant-types", "render", BOOT_SCHEMA,
      '"type": "object",\n          "additionalProperties": {\n            "type": "string"\n          }',
      '"additionalProperties": {}', "installvalues"),
    m("default-roles", "render", BOOT_HELPERS, '(list "admin" "editor" "viewer" "audit-read")',
      '(list "admin" "editor" "viewer" "audit-read" "auditor")', "tenantvaluekeys"),
    m("default-token", "render", BOOT_HELPERS, '(dict "ttl" 3600 "maxTTL" 14400)', '(dict "ttl" 3600 "maxTTL" 14401)',
      "tenantvaluekeys"),
    m("parent-name-budget", "render", PARENT, "{{- else if gt (len $n) 29 }}", "{{- else if gt (len $n) 63 }}", "reserved"),
    m("dns-regex-loosened", "render", PARENT, '"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"', '"^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$"',
      "dnsregex"),
    m("dns-regex-respelt", "render", HELPERS, 'regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $t)',
      'regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" $t)', "dnsregex"),
    m("vco-policies-acl", "render", VCO_POLICIES, 'path "sys/mounts" {',
      'path "sys/policies/acl/*" { capabilities = ["update"] }\npath "sys/mounts" {', "vcopolicy"),
    m("vco-policy-plus", "render", VCO_POLICIES, 'path "sys/mounts" {',
      'path "sys/policy/+" { capabilities = ["update"] }\npath "sys/mounts" {', "vcopolicy"),
    # ── The release and PR scripts ──
    m("release-content", "render", "hack/release-chart.sh",
      'if diff -r "$cmp_dir/published/$name" "$cmp_dir/local/$name" > "$cmp_dir/diff" 2>&1; then', "if true; then",
      "release"),
    m("bump-slash", "render", "hack/version-bump-check.sh", 'while [ "${dir%/}" != "$dir" ]; do dir="${dir%/}"; done',
      ":", "bumpcheck"),
    m("bump-missing-chart", "render", "hack/version-bump-check.sh",
      'if git cat-file -e "$base:$dir" 2>/dev/null; then\n      echo "$dir: exists',
      'if false; then\n      echo "$dir: exists', "bumpcheck"),
    m("bump-absolute", "render", "hack/version-bump-check.sh",
      '    /*) echo "$dir: give the chart directory relative to the repository root" >&2; fail=1; continue ;;\n', "",
      "bumpcheck"),
    m("bump-missing-dir", "render", "hack/version-bump-check.sh",
      '      echo "$dir: no such chart directory, here or on $base" >&2; fail=1\n', '      echo "$dir: unchanged"\n',
      "bumpcheck"),
    # ── The method's own tools ──
    m("adr-renames", "method", "hack/check_method.py", '"--no-renames", ', "", "test_renamed_and_edited_accepted_adr_fails"),
    m("hook-boundary", "method", "hack/claude-post-edit.sh", '[ "$inside" = yes ] || exit 0', ":",
      "test_markdown_edit_outside_the_repo_runs_nothing"),
    # ── This runner's own rules ──
    m("runner-ambiguous", "method", "hack/mutation_tests.py", '\n    if mut["count"] == 1 and n > 1:\n',
      "\n    if False:\n", "test_count_one_with_two_matches_fails"),
    m("runner-weak", "method", "hack/mutation_tests.py", "\n    hit = next((w for w in WEAK if w in line), None)\n",
      "\n    hit = None\n", "test_a_case_refused_by_another_guard_is_no_kill"),
    m("runner-detail", "method", "hack/mutation_tests.py", '\n        return None if mut["detail"] in line else',
      "\n        return None if True else", "test_a_detail_not_in_the_line_is_no_kill"),
]


def suite_cmd(suite):
    if suite == "render":
        return ["./hack/chart-render-tests.sh"]
    if suite == "admission":
        return ["./hack/admission-offline.sh"]
    return [sys.executable, "-m", "unittest", "discover", "-s", "hack", "-p", "test_*.py"]


def run(repo, suite, env):
    """(exit code, output); a timeout is exit code None."""
    try:
        r = subprocess.run(suite_cmd(suite), cwd=repo, env=env, capture_output=True, text=True, timeout=SUITE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, ""
    return r.returncode, r.stdout + r.stderr


def killed_by(suite, expect, out):
    """The FAIL line of the named check, or None."""
    for line in out.splitlines():
        if suite == "render" and (line.startswith(f"FAIL  {expect} ") or line == f"FAIL  {expect}"):
            return line
        if suite == "admission" and line.startswith("FAIL") and expect in line:
            return line
        if suite == "method" and line.startswith(("FAIL:", "ERROR:")) and expect in line:
            return line
    return None


def weak(mut, line):
    """Why a render check's FAIL line is no evidence for the mutation, or None."""
    if mut["suite"] != "render":
        return None
    if mut["detail"] is not None:
        return None if mut["detail"] in line else f"the line does not hold the mutation's own case {mut['detail']!r}"
    hit = next((w for w in WEAK if w in line), None)
    if hit:
        return f"the line holds {hit!r} (another guard or a crash): name the mutation's own case in detail="
    return None


def matches(mut, text):
    """None when the mutation applies to text, else why not."""
    n = text.count(mut["old"])
    if n == 0:
        return "no match (the guard moved: update hack/mutation_tests.py)"
    if mut["count"] == 1 and n > 1:
        return f"{n} matches for count=1: anchor the text on one, or use count=\"all\""
    return None


def try_mutation(mut, repo, env):
    """Apply, run, restore. Returns (verdict, detail)."""
    saved = {}
    try:
        for f in mut["files"]:
            path = os.path.join(repo, f)
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            why = matches(mut, text)
            if why:
                return "NOT-APPLIED", f"{f}: {why}"
            saved[path] = text
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text.replace(mut["old"], mut["new"], -1 if mut["count"] == "all" else 1))
        rc, out = run(repo, mut["suite"], env)
        if rc is None:
            return "TIMEOUT", f"the {mut['suite']} suite ran over {SUITE_TIMEOUT}s"
        line = killed_by(mut["suite"], mut["expect"], out)
        if line:
            why = weak(mut, line)
            if why:
                return "WEAK-KILL", f"{why}: {line[:200]}"
            return "KILLED", line[:150]
        if rc:
            first = next((l for l in out.splitlines() if l.startswith(("FAIL", "ERROR"))), "exit %d" % rc)
            return "WRONG-CHECK", f"want {mut['expect']!r} to fail; the suite failed elsewhere: {first[:150]}"
        return "SURVIVED", f"the {mut['suite']} suite stays green"
    finally:
        for path, text in saved.items():
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)


def make_copy(work, i):
    repo = os.path.join(work, f"repo{i}")
    shutil.copytree(ROOT, repo, ignore=shutil.ignore_patterns(".git", "bin", "e2e-logs", "node_modules", "__pycache__", "dist"))
    # The fullnames check lists files with git ls-files: an index, no history.
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True)
    return repo


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-j", type=int, default=min(4, os.cpu_count() or 1), help="mutations run at once, each in its own copy")
    ap.add_argument("ids", nargs="*")
    args = ap.parse_args()
    ids = [x["id"] for x in MUTATIONS]
    dup = {i for i in ids if ids.count(i) > 1}
    if dup:
        sys.exit(f"duplicate mutation id(s): {', '.join(sorted(dup))}")
    unknown = set(args.ids) - set(ids)
    if unknown:
        sys.exit(f"unknown mutation id(s): {', '.join(sorted(unknown))}")
    todo = [x for x in MUTATIONS if not args.ids or x["id"] in args.ids]
    work = tempfile.mkdtemp()
    try:
        env = dict(os.environ)
        env.setdefault("HELM", "helm")
        env.setdefault("YQ", "yq")
        env["ADMISSION_EVAL"] = os.path.join(work, "admission-eval")
        b = subprocess.run(["go", "build", "-o", env["ADMISSION_EVAL"], "./hack/admission-eval"], cwd=ROOT,
                           capture_output=True, text=True)
        if b.returncode:
            sys.exit(f"FAIL  infra — cannot build hack/admission-eval: {b.stderr.strip()}")
        copies = queue.Queue()
        for i in range(max(1, args.j)):
            copies.put(make_copy(work, i))
        # The unmutated copy must pass every suite, or every mutation fails
        # of the same unrelated failure.
        base = copies.get()
        for suite in ("render", "admission", "method"):
            rc, out = run(base, suite, env)
            if rc != 0:
                first = next((l for l in out.splitlines() if l.startswith(("FAIL", "ERROR"))), out.strip()[-200:])
                sys.exit(f"FAIL  baseline — the {suite} suite fails without any mutation: {first}")
        copies.put(base)

        def one(mut):
            repo = copies.get()
            try:
                return mut, try_mutation(mut, repo, env)
            finally:
                copies.put(repo)

        bad = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.j)) as pool:
            for mut, (verdict, detail) in pool.map(one, todo):
                if verdict != "KILLED":
                    bad += 1
                print(f"{verdict:<11} {mut['id']} ({mut['suite']} → {mut['expect']}) — {detail}", flush=True)
        print(f"== {len(todo)} mutations, {len(todo) - bad} killed by their named check, {bad} not")
        sys.exit(1 if bad else 0)
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
