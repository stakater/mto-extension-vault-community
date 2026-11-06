"""Every guard listed here, weakened in turn, must make the check it names fail.

A check that stays green when its guard is removed proves nothing, and a
guard "killed" by some other failure (a template crash, an unrelated check)
proves nothing about the check that should have caught it. So each mutation
names the check that must fail, and is killed only when that check reports
FAIL, through the mutation's own case, and not because something crashed:

  render     hack/chart-render-tests.sh   expect: the check's name  (FAIL  <name>)
  admission  hack/admission-offline.sh    expect: text of the FAIL line (a case's description, or "compile")
  method     unittest discover -s hack    expect: the test's name   (FAIL: <name>)
  go         go test ./hack/admission-eval/   expect: the test's name   (--- FAIL: <name>)

A render check's FAIL line lists its failed cases. With `detail`, the text of
the mutation's own case (for example "[platform-one rendered"), the line is a
kill when that case is in it and did not crash; that case refused with
another guard's message is a kill, as the guard's own message is gone.
Without `detail`, a line that holds another guard's message, Helm's `fail`
output, a refused near miss, a fixture that did not render or a crash is no
kill (WEAK). An admission case failed by a policy that refused on an
evaluation error or failed to configure, a method test that errors, and a go
test that panics are crashes, never kills. A parse error
in a chart never reaches a check: the harness renders each chart before the
first check that reads it, and stops there. A mutation of hack/admission-eval
in the admission suite would run the evaluator built from the mutated copy;
the evaluator's own rules are the go suite's.

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


# In a render check's FAIL line: a template or shell crash, never a kill.
CRASH = ('executing "', "parse error", "syntax error", "nil pointer", "can't evaluate field", "wrong type for value",
         "index out of range", "command not found", "can't iterate")
# Without detail, no kill either: another guard's message, Helm's fail output,
# a refused near miss, a fixture that did not render.
WEAK = CRASH + ("failed elsewhere", "execution error at", "was refused", "did not render")
# In an admission FAIL line: a policy refused on an evaluation error, or failed
# to configure (a crash), whichever case it is.
EVAL_ERROR = ("on an evaluation error", "resulted in error", "failed to configure")
EVALUATOR = "hack/admission-eval/"
EVAL = EVALUATOR + "main.go"
SCAFFOLD = "charts/mto-extension-vault-community/templates/01-tenant-scaffolding.yaml"
OIDC = "charts/mto-extension-vault-community/templates/06-oidc-auth.yaml"
ESO = "charts/mto-extension-vault-community/templates/05-deployment-externalsecrets.yaml"
PARENT_TPL = "charts/mto-extension-vault-community-bootstrap/templates/30-parent-template.yaml"
POLICY_HEAD = ('  name: mto-extension-vault-community-vco-{}\nspec:\n  failurePolicy: Fail\n  matchConstraints:\n'
               '    namespaceSelector:\n      matchLabels: {{ kubernetes.io/metadata.name: {{{{ $cfg | quote }}}} }}\n'
               '    resourceRules:\n      - apiGroups: ["redhatcop.redhat.io"]\n        apiVersions: ["*"]\n'
               '        operations: ["CREATE", "UPDATE"]\n        resources: ["*"]\n')
DELETION_C17 = '    - name: not-deleting\n      expression: "!has(object.metadata.deletionTimestamp)"\n'


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
    m("cel-connection", "admission", ADM, "!variables.ours || !has(object.spec) || !has(object.spec.connection)", "true",
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
      "      {{ .ctx.Values.tenantLabelKey | quote }}: {{ .ctx.Values.tenant | quote }}\n", "", "rolebind"),
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
    m("runner-detail", "method", "hack/mutation_tests.py", '        case = own_case(line, mut["detail"])\n',
      "        case = line\n", "test_a_detail_not_in_the_line_is_no_kill"),
    # ── C.21: each admission rule the review found unpinned, by its own case ──
    m("cel-stanza", "admission", ADM,
      """l.matches('^path\\\\s+"[^"]+"\\\\s*\\\\{\\\\s*capabilities\\\\s*=\\\\s*\\\\[\\\\s*"[a-z]+"(\\\\s*,\\\\s*"[a-z]+")*\\\\s*\\\\]\\\\s*\\\\}$') && """,
      "", "two stanzas on one line"),
    m("cel-sso-policies", "admission", ADM, "          object.spec.tokenPolicies == [variables.vname] &&\n", "",
      "an SSO role that attaches vco-admin"),
    m("cel-name-shared", "admission", ADM, " && variables.t != {{ $shared | squote }} && (", " && (",
      "a kv policy for the shared name"),
    m("cel-name-family", "admission", ADM, "variables.t != {{ $shared | squote }} && (\n",
      "variables.t != {{ $shared | squote }} && (true ||\n", "a name outside the families"),
    m("cel-name-kv-parts", "admission", ADM, "(variables.fam == 'kv' && size(variables.parts) == 4 &&",
      "(variables.fam == 'kv' &&", "a kv name with three parts"),
    m("cel-role-namespace-list", "admission", ADM, "          !has(object.spec.targetNamespaces.targetNamespaces) &&\n", "",
      "a role that also binds a namespace list"),
    m("cel-role-match-expressions", "admission", ADM,
      "          !has(object.spec.targetNamespaces.targetNamespaceSelector.matchExpressions) &&\n", "",
      "a role whose namespace selector also has matchExpressions"),
    m("cel-sso-path", "admission", ADM, "          object.spec.path == variables.t + '/{{ $ssoPath }}/{{ $ssoName }}' &&\n", "",
      "an SSO role on another tenant's mount"),
    m("cel-kvmount-name", "admission", ADM, "object.spec.type == 'kv' && object.spec.name == 'kv' &&",
      "object.spec.type == 'kv' &&", "a kv mount with another name than kv"),
    m("cel-kvmount-object-name", "admission", ADM,
      "          object.metadata.name == object.spec.path + '-kv' && variables.noAuditHeaders)",
      "          variables.noAuditHeaders)", "a kv mount whose object is not named"),
    m("cel-kvmount-path", "admission", ADM,
      "object.spec.path.matches('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') && !(object.spec.path in variables.reserved) &&",
      "!(object.spec.path in variables.reserved) &&", "a kv mount at a path that is not a tenant name"),
    m("cel-authmount-name", "admission", ADM, "&& object.spec.name == {{ $k8sName | squote }} && object.spec.type == 'kubernetes')",
      "&& object.spec.type == 'kubernetes')", "a Kubernetes auth mount with another name"),
    m("cel-authmount-reserved", "admission", ADM,
      "          !(object.spec.path.split('/')[0] in variables.reserved) && object.spec.path.split('/')[0] != {{ $shared | squote }} &&",
      "          object.spec.path.split('/')[0] != {{ $shared | squote }} &&", "a Kubernetes auth mount under a reserved name"),
    m("cel-oidc-path", "admission", ADM,
      "          object.spec.path.matches('^[a-z0-9]([-a-z0-9]*[a-z0-9])?/{{ $ssoPath }}/{{ $ssoName }}$') &&\n", "",
      "an OIDC config on another mount"),
    m("cel-cluster-path", "admission", ADM,
      "\n        object.spec.path.matches('^[a-z0-9]([-a-z0-9]*[a-z0-9])?/{{ $k8sPath }}$') && object.spec.name == {{ $k8sName | squote }} &&",
      "\n        object.spec.name == {{ $k8sName | squote }} &&", "a config on another auth path"),
    m("cel-cluster-name", "admission", ADM,
      "{{ $k8sPath }}$') && object.spec.name == {{ $k8sName | squote }} &&\n        (!has(object.spec.kubernetesCACert)",
      "{{ $k8sPath }}$') &&\n        (!has(object.spec.kubernetesCACert)", "a config for another mount name"),
    m("cel-cluster-own-ca", "admission", ADM,
      "(!has(object.spec.kubernetesCACert) || object.spec.kubernetesCACert == params.data['ca.crt'])",
      "!has(object.spec.kubernetesCACert)", "a config with the cluster's own CA"),
    m("cel-cluster-reviewer-empty", "admission", ADM, " object.spec.tokenReviewerServiceAccount.name == '' ||", "",
      "a config with an empty reviewer name"),
    m("cel-origin-delete", "admission", ADM, NOT_DELETING + "  variables:\n    - name: source\n",
      DELETION_C17 + "  variables:\n    - name: source\n", "Template Operator moves a deleting object"),
    m("cel-cluster-delete", "admission", ADM,
      NOT_DELETING + "    - name: has-spec\n      expression: has(object.spec)\n  validations:\n",
      DELETION_C17 + "    - name: has-spec\n      expression: has(object.spec)\n  validations:\n",
      "a config whose API host changes during a deletion"),
    m("cel-kinds-scope", "admission", ADM, POLICY_HEAD.format("kinds") + "        scope: Namespaced\n",
      POLICY_HEAD.format("kinds"), "a cluster-scoped redhatcop.redhat.io object of another operator"),
    m("cel-origin-scope", "admission", ADM, POLICY_HEAD.format("origin") + "        scope: Namespaced\n",
      POLICY_HEAD.format("origin"), "a cluster-scoped object of another operator, written by Template Operator"),
    m("cel-auth-path", "admission", ADM, "          object.spec.authentication.path == {{ $vcoPath | squote }} &&\n", "",
      "a policy that logs in at another auth mount"),
    # The re-review of C.21: more rules, each by its own case.
    m("cel-sso-path-scope", "admission", ADM,
      "variables.fam == 'sso' ? (p.matches(variables.kvRe) || p == variables.t + '/kv/metadata') :",
      "variables.fam == 'sso' ? true :", "an SSO policy on every path"),
    m("cel-sso-metadata-root", "admission", ADM, " || p == variables.t + '/kv/metadata')", ")", "an SSO role's policy"),
    m("cel-name-labels", "admission", ADM,
      "          variables.parts.all(p, p.matches('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')) &&\n", "",
      "a kv policy whose spec.name puts a regex in the tenant part"),
    m("cel-name-dir", "admission", ADM, " && variables.dir in ['in', 'out']", "",
      "a share policy with another direction than in or out"),
    m("cel-name-kv-kind", "admission", ADM, "size(variables.parts) == 4 && variables.kind != 'JWTOIDCAuthEngineRole')",
      "size(variables.parts) == 4)", "an SSO role with a kv name"),
    m("cel-name-share-kind", "admission", ADM,
      "variables.dir in ['in', 'out'] && variables.kind != 'JWTOIDCAuthEngineRole')", "variables.dir in ['in', 'out'])",
      "an SSO role with a share name"),
    m("cel-authmount-oidc-type", "admission", ADM,
      "&& object.spec.name == {{ $ssoName | squote }} && object.spec.type == 'oidc')",
      "&& object.spec.name == {{ $ssoName | squote }})", "a userpass mount in the OIDC mount's place"),
    m("cel-audit-response", "admission", ADM, " || has(object.spec.config.auditNonHMACResponseKeys)", "",
      "a tenant mount that logs response data in clear"),
    m("cel-kv-verbs", "admission", ADM, "'/kv/(data|metadata|delete|undelete|destroy)/", "'/kv/[a-z]+/",
      "a path under kv/subkeys"),
    m("cel-authmount-oidc-name", "admission", ADM,
      "/{{ $ssoPath }}$') && object.spec.name == {{ $ssoName | squote }} && object.spec.type == 'oidc')",
      "/{{ $ssoPath }}$') && object.spec.type == 'oidc')", "an OIDC auth mount with another name"),
    m("cel-authmount-k8s-path", "admission", ADM,
      "((object.spec.path.matches('^[a-z0-9]([-a-z0-9]*[a-z0-9])?/{{ $k8sPath }}$') &&",
      "((object.spec.path.endsWith('/{{ $k8sPath }}') &&", "a Kubernetes auth mount below a path that is not a tenant"),
    m("cel-scope-delete", "admission", ADM,
      "    # A finalizer update during a deletion passes; a spec change does not.\n" + NOT_DELETING,
      "    # A finalizer update during a deletion passes; a spec change does not.\n" + DELETION_C17,
      "a spec widened during a deletion"),
    # ── C.21: the offline evaluator's own rules (main_test.go) ──
    m("eval-message", "go", EVAL, "\tcase !strings.Contains(d.Error(), c.message):\n", "\tcase false:\n",
      "TestRefusedByAnotherRuleFails"),
    m("eval-others", "go", EVAL, "\tcase len(others) > 0:\n", "\tcase false:\n", "TestAlsoRefusedByAnotherPolicyFails"),
    m("eval-error", "go", EVAL, "\tcase !refusedByPolicy(d):\n", "\tcase false:\n", "TestEvaluationErrorIsNoRefusal"),
    m("eval-admitted", "go", EVAL, "\tcase d == nil:\n", "\tcase false:\n", "TestAdmittedFails"),
    m("eval-admit", "go", EVAL, "\t\tif len(denials) == 0 {\n", "\t\tif true {\n", "TestAdmitWithADenialFails"),
    m("eval-count", "go", EVAL, "\tif got == want {\n", "\tif true {\n", "TestCountMismatchFails"),
    m("eval-compile-version", "go", EVAL, "var oldestAPIServer = version.MajorMinor(1, 29)",
      "var oldestAPIServer = version.MajorMinor(1, 36)", "TestTooNewExpressionFailsToCompile"),
    m("eval-message-required", "go", EVAL, ' || (c.want == "refuse") != (c.message != "")', "",
      "TestARefusalWithoutAMessageIsRefused"),
    m("eval-cluster-scope", "go", EVAL, '\t\t\tcase c.scope != "cluster" && d.GetNamespace() == "":',
      '\t\t\tcase d.GetNamespace() == "":', "TestAClusterScopedCaseKeepsNoNamespace"),
    # ── C.21: null toggles, quoting, trimming, the SSO token, the defaults ──
    m("null-default", "render", BOOT_HELPERS, "{{- $s = toString .default -}}", '{{- $s = "false" -}}', "nulltoggle",
      detail="[admission: {enabled: null} renders other than the default"),
    m("eso-null-default", "render", BOOT_HELPERS, '{{- $s = "enabled" -}}', '{{- $s = "disabled" -}}', "nulltoggle",
      detail="[parent: {eso: null} renders other than the default"),
    m("feature-default", "render", BOOT_HELPERS,
      '(printf "tenantValues.%s.enabled" .feature) "value" $v "default" "false")',
      '(printf "tenantValues.%s.enabled" .feature) "value" $v "default" "true")', "rbacgate"),
    m("quote-vco-role", "render", HELPERS, '  role: {{ required "vco.role must be set" $v.role | quote }}',
      '  role: {{ required "vco.role must be set" $v.role }}', "typeprobe", detail="spec.authentication.role: !!str -> !!int"),
    m("quote-vco-path", "render", HELPERS,
      '  path: {{ trimAll "/" (toString (required "vco.authPath must be set" $v.authPath)) | quote }}',
      '  path: {{ trimAll "/" (toString (required "vco.authPath must be set" $v.authPath)) }}', "typeprobe",
      detail="spec.authentication.path: !!str -> !!int"),
    m("quote-reviewer", "render", SCAFFOLD, "    name: {{ . | quote }}", "    name: {{ . }}", "typeprobe",
      detail="spec.tokenReviewerServiceAccount.name: !!str -> !!int"),
    m("quote-host", "render", SCAFFOLD, "  kubernetesHost: {{ .Values.kubernetesAuth.kubernetesHost | quote }}",
      "  kubernetesHost: {{ .Values.kubernetesAuth.kubernetesHost }}", "typeprobe", detail="spec.kubernetesHost: !!str -> !!int"),
    m("quote-password-key", "render", OIDC, "    passwordKey: {{ .Values.sso.oidc.clientSecretRef.key | quote }}",
      "    passwordKey: {{ .Values.sso.oidc.clientSecretRef.key }}", "typeprobe",
      detail="spec.OIDCCredentials.passwordKey: !!str -> !!int"),
    m("quote-refresh", "render", ESO, "  refreshInterval: {{ $refresh | quote }}", "  refreshInterval: {{ $refresh }}",
      "typeprobe", detail="spec.refreshInterval: !!str -> !!int"),
    m("quote-slice-key", "render", ESO, "    - secretKey: {{ $r.sliceKey | quote }}", "    - secretKey: {{ $r.sliceKey }}",
      "typeprobe", detail="spec.data.0.secretKey: !!str -> !!int"),
    m("quote-slice-property", "render", ESO, "        property: {{ $r.sliceKey | quote }}", "        property: {{ $r.sliceKey }}",
      "typeprobe", detail="spec.data.0.remoteRef.property: !!str -> !!int"),
    m("quote-vault-server", "render", [OWN, SHARE_IN], "{{ $.Values.vaultServer | quote }}",
      "{{ $.Values.vaultServer }}", "typeprobe", count="all", detail="data.VAULT_ADDR: !!str -> !!int"),
    m("quote-label-key", "render", HELPERS, "{{ .Values.tenantLabelKey | quote }}: {{ $t | quote }}",
      "{{ .Values.tenantLabelKey }}: {{ $t | quote }}", "typeprobe", detail="[tenant chart: a map key is not a string"),
    m("quote-role-label-key", "render", HELPERS, "      {{ .ctx.Values.tenantLabelKey | quote }}: {{ .ctx.Values.tenant | quote }}",
      "      {{ .ctx.Values.tenantLabelKey }}: {{ .ctx.Values.tenant | quote }}", "typeprobe",
      detail="[tenant chart: a map key is not a string"),
    m("quote-parent-auth", "render", PARENT,
      "(.parameters.vcoAuthPath | quote) (.parameters.vcoRole | quote) (.parameters.vcoServiceAccount | quote)",
      ".parameters.vcoAuthPath .parameters.vcoRole .parameters.vcoServiceAccount", "typeprobe",
      detail="[parent: a field changed its type"),
    m("quote-parent-ti-label", "render", PARENT, "              {{ $tenantLabel | quote }}: {{ $name | quote }}",
      "              {{ $tenantLabel }}: {{ $name | quote }}", "typeprobe", count="all",
      detail="[parent: a map key is not a string"),
    m("quote-vco-sa", "render", HELPERS, '    name: {{ required "vco.serviceAccount must be set" $v.serviceAccount | quote }}',
      '    name: {{ required "vco.serviceAccount must be set" $v.serviceAccount }}', "typeprobe",
      detail="spec.authentication.serviceAccount.name: !!str -> !!int"),
    m("quote-k8s-name", "render", SCAFFOLD, '  name: {{ trimAll "/" .Values.kubernetesAuth.name | quote }}',
      '  name: {{ trimAll "/" .Values.kubernetesAuth.name }}', "typeprobe", count="all",
      detail="[tenant chart: a field changed its type: AuthEngineMount/team-a-kubernetes spec.name: !!str -> !!int"),
    m("quote-sso-mount-name", "render", OIDC, '  name: {{ trimAll "/" .Values.sso.mount.name | quote }}',
      '  name: {{ trimAll "/" .Values.sso.mount.name }}', "typeprobe", detail="AuthEngineMount/team-a-oidc spec.name: !!str -> !!int"),
    m("install-host-required", "render", BOOT_HELPERS,
      'list (list "kubernetesAuth.kubernetesHost" .Values.kubernetesAuth.kubernetesHost) (list "tenantChart.version"',
      'list (list "tenantChart.version"', "installvalues", detail="[a null API host rendered with the schema removed"),
    m("install-version-required", "render", BOOT_HELPERS,
      ' (list "tenantChart.version" (.Values.tenantChart | default dict).version) -}}', " -}}", "installvalues",
      detail="[a null tenant chart version rendered with the schema removed"),
    m("quote-parent-label", "render", PARENT, "labels: { {{ $tenantLabel | quote }}: {{ $name | quote }} } }",
      "labels: { {{ $tenantLabel }}: {{ $name | quote }} } }", "typeprobe", detail="[parent: a map key is not a string"),
    m("trim-vco-path-tenant", "render", HELPERS,
      '  path: {{ trimAll "/" (toString (required "vco.authPath must be set" $v.authPath)) | quote }}',
      '  path: {{ required "vco.authPath must be set" $v.authPath | toString | quote }}', "mountagree",
      detail="[ma-slash.raw vco.authPath"),
    m("trim-vco-path-parent", "render", PARENT_TPL, '      value: {{ trimAll "/" (toString .Values.vco.authPath) | quote }}',
      "      value: {{ .Values.vco.authPath | quote }}", "mountagree", detail="[the parent's vcoAuthPath"),
    m("trim-vco-path-cel", "render", ADM, '{{- $vcoPath := trimAll "/" (toString .Values.vco.authPath) }}',
      "{{- $vcoPath := toString .Values.vco.authPath }}", "mountagree",
      detail="[the admission policies expect another vco.authPath"),
    m("sso-token-install", "render", BOOT_HELPERS,
      "{{- if and (gt (float64 $smax) 0.0) (gt (float64 $sttl) (float64 $smax)) -}}", "{{- if false -}}", "ssotoken",
      detail="[bootstrap two-hours rendered"),
    m("sso-token-install-default", "render", BOOT_HELPERS,
      '{{- $seff := include "mto-extension-vault-community-bootstrap.defaultSsoToken" . | fromYaml -}}',
      "{{- $seff := dict -}}", "ssotoken", detail="[bootstrap max-ten-minutes rendered"),
    m("sso-token-tenant", "render", SSO, "{{- if and (gt (float64 $smax) 0.0) (gt (float64 $sttl) (float64 $smax)) }}",
      "{{- if false }}", "ssotoken", detail="[tenant two-hours rendered"),
    # An hour ten times too long: the defaults (15m, 1h) still render, 61m
    # against the default 1h does not.
    m("duration-hours-tenant", "render", HELPERS, '"h" 3600.0', '"h" 36000.0', "ssotoken",
      detail="[tenant minutes-over-an-hour rendered"),
    m("duration-hours-boot", "render", BOOT_HELPERS, '"h" 3600.0', '"h" 36000.0', "ssotoken",
      detail="[bootstrap minutes-over-an-hour rendered"),
    m("duration-days-tenant", "render", HELPERS, '{{- else if regexMatch "^[+]?[0-9]+d$" $s -}}', "{{- else if false -}}",
      "ssotoken", detail="[tenant days failed elsewhere"),
    m("duration-days-boot", "render", BOOT_HELPERS, '{{- else if regexMatch "^[+]?[0-9]+d$" $s -}}', "{{- else if false -}}",
      "ssotoken", detail="[bootstrap days failed elsewhere"),
    m("duration-seconds-tenant", "render", HELPERS, '{{- else if regexMatch "^[+]?[0-9]+$" $s -}}', "{{- else if false -}}",
      "ssotoken", detail="[tenant seconds failed elsewhere"),
    m("duration-seconds-boot", "render", BOOT_HELPERS, '{{- else if regexMatch "^[+]?[0-9]+$" $s -}}', "{{- else if false -}}",
      "ssotoken", detail="[bootstrap seconds failed elsewhere"),
    m("sso-roles-empty", "render", BOOT_HELPERS,
      '{{- if and (eq (len $roles) 0) (eq (include "mto-extension-vault-community-bootstrap.ssoEnabled" .) "true") -}}',
      "{{- if false -}}", "ssogroups",
      detail="[bootstrap roles-empty rendered"),
    m("sso-roles-empty-sso", "render", BOOT_HELPERS,
      '(eq (len $roles) 0) (eq (include "mto-extension-vault-community-bootstrap.ssoEnabled" .) "true")',
      "(eq (len $roles) 0) true", "ssogroups", detail="[bootstrap roles-empty-sso-off failed"),
    m("sso-roles-empty-tenant", "render", SSO, "{{- if not .Values.sso.roles }}", "{{- if false }}", "ssogroups",
      detail="[tenant chart roles-empty rendered"),
    m("sso-role-dns", "render", BOOT_HELPERS, '{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $role) -}}',
      "{{- if false -}}", "ssogroups", detail="[bootstrap badrole-caps rendered"),
    m("sso-collision-same-split", "render", BOOT_HELPERS, '{{- if hasPrefix "same:" $hit -}}', "{{- if false -}}",
      "ssogroups", detail="[bootstrap one-group failed elsewhere"),
    m("sso-collision-swap", "render", BOOT_HELPERS, "{{- if lt (len $p2) (len $p1) -}}", "{{- if false -}}", "ssogroups",
      detail="[bootstrap prefix rendered"),
    m("sso-collision-overlap-cross", "render", BOOT_HELPERS, "{{- if and $meet (ne $t1 $t2) -}}", "{{- if false -}}",
      "ssogroups", detail="[bootstrap overlap rendered"),
    m("install-vco-role-quote", "render", BOOT_HELPERS,
      '(contains "\'" (toString .Values.vco.role)) (contains "\\\\" (toString .Values.vco.role))', "false false",
      "installvalues", detail="[a quote in vco.role rendered with the schema removed"),
    m("install-keep-zero", "render", BOOT_HELPERS,
      '{{- if and (hasKey $tok $k) (not (kindIs "invalid" (get $tok $k))) -}}', "{{- if get $tok $k -}}", "installvalues",
      detail="[parent: {token: {ttl: 20000, maxTTL: 0}} was refused"),
    m("install-mount-k8s-prefix", "render", BOOT_HELPERS, '(hasPrefix (printf "%s/" $k8s) $sso)', "(hasPrefix $k8s $sso)",
      "installvalues", detail="[tenantValues: {sso: {mount: {path: kubernetes, name: workloadsx}}} was refused"),
    m("install-reviewer", "render", BOOT_HELPERS,
      '{{- $checks = append $checks (list "kubernetesAuth.tokenReviewerServiceAccount" . $sub) -}}',
      '{{- $checks = append $checks (list "kubernetesAuth.tokenReviewerServiceAccount" "x" $sub) -}}', "installvalues",
      detail="[kubernetesAuth.tokenReviewerServiceAccount rendered with the schema removed"),
    m("default-sso-token", "render", BOOT_HELPERS, '(dict "ttl" "15m" "maxTTL" "1h")', '(dict "ttl" "15m" "maxTTL" "2h")',
      "tenantvaluekeys"),
    m("default-sso-mount", "render", BOOT_HELPERS, '(dict "path" "oidc" "name" "sso")', '(dict "path" "oidc" "name" "ssox")',
      "tenantvaluekeys"),
    m("default-group-template", "render", BOOT_HELPERS, "{tenant}-{role}s\n{{- end -}}", "{tenant}-{role}\n{{- end -}}",
      "tenantvaluekeys"),
    # The schema's tenantValues types, each by its own case.
    m("schema-ssotoken-object", "render", BOOT_SCHEMA,
      '"description": "Tenant chart ssoToken: duration strings, as the OIDC role takes them.",\n          "type": "object",',
      '"description": "Tenant chart ssoToken: duration strings, as the OIDC role takes them.",', "installvalues",
      detail='[the schema accepted tenantValues: {ssoToken: ""}'),
    m("schema-ssotoken-ttl", "render", BOOT_SCHEMA,
      '"ttl": {\n              "type": "string"\n            },\n            "maxTTL": {\n              "type": "string"',
      '"ttl": {},\n            "maxTTL": {\n              "type": "string"', "installvalues",
      detail="[the schema accepted tenantValues: {ssoToken: {ttl: 900}}"),
    m("schema-secretref-object", "render", BOOT_SCHEMA, '"clientSecretRef": {\n                  "type": "object",',
      '"clientSecretRef": {', "installvalues", detail="[the schema accepted tenantValues: {sso: {oidc: {clientSecretRef: x}}}"),
    m("schema-secretref-name", "render", BOOT_SCHEMA,
      '"name": {\n                      "type": "string",\n                      "minLength": 1\n                    },\n                    "key"',
      '"name": {\n                      "minLength": 1\n                    },\n                    "key"', "installvalues",
      detail="[the schema accepted tenantValues: {sso: {oidc: {clientSecretRef: {name: 1}}}}"),
    m("schema-clientid-min", "render", BOOT_SCHEMA,
      '"clientId": {\n                  "type": "string",\n                  "minLength": 1\n                },',
      '"clientId": {\n                  "type": "string"\n                },', "installvalues",
      detail='[the schema accepted tenantValues: {sso: {oidc: {clientId: ""}}}'),
    m("schema-cabundle", "render", BOOT_SCHEMA, '"caBundlePem": {\n                  "type": "string"\n                },',
      '"caBundlePem": {},', "installvalues", detail="[the schema accepted tenantValues: {sso: {oidc: {caBundlePem: 123}}}"),
    m("schema-vaultcabundle", "render", BOOT_SCHEMA, '"vaultCABundle": {\n          "type": "string"\n        },',
      '"vaultCABundle": {},', "installvalues", detail="[the schema accepted tenantValues: {vaultCABundle: 123}"),
    m("schema-group-template", "render", BOOT_SCHEMA, '"tenantGroupTemplate": {\n              "type": "string"\n            },',
      '"tenantGroupTemplate": {},', "installvalues",
      detail="[the schema accepted tenantValues: {sso: {tenantGroupTemplate: [x]}}"),
    m("schema-mount-name", "render", BOOT_SCHEMA,
      '"name": {\n                  "type": "string"\n                }\n              },\n              "additionalProperties": false\n            },\n            "oidc": {',
      '"name": {}\n              },\n              "additionalProperties": false\n            },\n            "oidc": {', "installvalues",
      detail="[the schema accepted tenantValues: {sso: {mount: {name: 1}}}"),
    m("schema-prometheus-ns", "render", BOOT_SCHEMA, '"prometheusNamespace": {\n              "type": "string"\n            }',
      '"prometheusNamespace": {}', "installvalues",
      detail="[the schema accepted tenantValues: {monitoring: {prometheusNamespace: 1}}"),
    m("schema-mapping-object", "render", BOOT_SCHEMA,
      '"type": "object",\n              "additionalProperties": {\n                "type": [\n                  "object",',
      '"additionalProperties": {\n                "type": [\n                  "object",', "installvalues",
      detail="[the schema accepted tenantValues: {sso: {tenantRoleMapping: []}}"),
    m("schema-mapping-pattern", "render", BOOT_SCHEMA, '"pattern": {\n                    "type": "string"\n                  }',
      '"pattern": {}', "installvalues",
      detail='[the schema accepted tenantValues: {sso: {tenantRoleMapping: {admin: {pattern: ["{tenant}-x"]}}}}'),
    # ── C.21: this runner's own new rules ──
    m("runner-crash-own", "method", "hack/mutation_tests.py", "        crash = next((w for w in CRASH if w in case), None)\n",
      "        crash = None\n", "test_a_crash_on_the_own_case_is_no_kill"),
    m("runner-eval-error", "method", "hack/mutation_tests.py",
      '        hit = next((w for w in EVAL_ERROR if w in line), None)\n', "        hit = None\n",
      "test_an_admission_evaluation_error_is_no_kill"),
    m("runner-weak-words", "method", "hack/mutation_tests.py",
      '\nWEAK = CRASH + ("failed elsewhere", "execution error at", "was refused", "did not render")',
      '\nWEAK = CRASH + ("failed elsewhere",)', "test_helm_fail_output_without_detail_is_no_kill"),
    m("runner-method-error", "method", "hack/mutation_tests.py", '\n        if suite == "method" and line.startswith("FAIL:")',
      '\n        if suite == "method" and line.startswith(("FAIL:", "ERROR:"))', "test_a_method_error_is_no_kill"),
    m("runner-go-panic", "method", "hack/mutation_tests.py", '        return "a test panicked" if "panic:" in out else None\n',
      "        return None\n", "test_a_go_panic_is_no_kill"),
    m("runner-evaluator-env", "method", "hack/mutation_tests.py",
      "    if any(f.startswith(EVALUATOR) for f in mut[\"files\"]):\n", "    if False:\n",
      "test_a_mutation_of_the_evaluator_runs_its_own_build"),
]


def suite_cmd(suite):
    if suite == "render":
        return ["./hack/chart-render-tests.sh"]
    if suite == "admission":
        return ["./hack/admission-offline.sh"]
    if suite == "go":
        return ["go", "test", "-count=1", "./" + EVALUATOR]
    return [sys.executable, "-m", "unittest", "discover", "-s", "hack", "-p", "test_*.py"]


def suite_env(mut, env):
    """The suite's environment: without the prebuilt evaluator when the
    mutation changes the evaluator, so the copy's own one runs."""
    if any(f.startswith(EVALUATOR) for f in mut["files"]):
        return {k: v for k, v in env.items() if k != "ADMISSION_EVAL"}
    return env


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
        if suite == "method" and line.startswith("FAIL:") and expect in line:
            return line
        if suite == "go" and line.strip().startswith(f"--- FAIL: {expect} "):
            return line
    return None


def own_case(line, detail):
    """The mutation's own case in a render FAIL line: from its detail to the
    end of its [...], or None."""
    i = line.find(detail)
    if i < 0:
        return None
    j = line.find("] [", i)
    return line[i:] if j < 0 else line[i:j + 1]


def weak(mut, line, out=""):
    """Why a FAIL line is no evidence for the mutation, or None."""
    if mut["suite"] == "admission":
        if mut["expect"] == "compile":
            return None
        hit = next((w for w in EVAL_ERROR if w in line), None)
        return f"a policy refused on an evaluation error ({hit!r}), not by a rule" if hit else None
    if mut["suite"] == "go":
        return "a test panicked" if "panic:" in out else None
    if mut["suite"] != "render":
        return None
    if mut["detail"] is not None:
        case = own_case(line, mut["detail"])
        if case is None:
            return f"the line does not hold the mutation's own case {mut['detail']!r}"
        crash = next((w for w in CRASH if w in case), None)
        return f"the mutation's own case crashed ({crash!r})" if crash else None
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
        rc, out = run(repo, mut["suite"], suite_env(mut, env))
        if rc is None:
            return "TIMEOUT", f"the {mut['suite']} suite ran over {SUITE_TIMEOUT}s"
        line = killed_by(mut["suite"], mut["expect"], out)
        if line:
            why = weak(mut, line, out)
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
        for suite in ("render", "admission", "method", "go"):
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
