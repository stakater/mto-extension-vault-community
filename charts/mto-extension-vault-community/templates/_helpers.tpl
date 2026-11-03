{{/*
Returns "true" when the given component should render in this pass, "" when
it should not. Every template block belongs to exactly one component (core,
eso); component=all renders both. Fails the render on an unrecognized
.Values.component so a typo surfaces loudly instead of silently emitting
nothing.
Usage:  {{ if include "vault.componentEnabled" (dict "component" "eso" "ctx" $) }}
*/}}
{{- define "vault.componentEnabled" -}}
{{- $valid := list "all" "core" "eso" -}}
{{- if not (has .ctx.Values.component $valid) -}}
{{- fail (printf "unknown component %q — must be one of: %s" .ctx.Values.component (join ", " $valid)) -}}
{{- end -}}
{{- /* Helm ignores unknown values, so a values file still setting a removed
       feature would believe it is on. Checked here because every template
       calls this first; the file named in the error is incidental. */ -}}
{{- if hasKey .ctx.Values "networkPolicy" -}}
{{- fail "networkPolicy was removed: a default-deny egress policy for tenant workloads is not this chart's to own (use MTO's network policies). Delete networkPolicy from your values" -}}
{{- end -}}
{{- if hasKey ((.ctx.Values.sso | default dict).oidc | default dict) "perTenantClient" -}}
{{- fail "sso.oidc.perTenantClient was removed: every tenant uses the one shared IdP client sso.oidc.clientId. Delete sso.oidc.perTenantClient from your values" -}}
{{- end -}}
{{- if hasKey (.ctx.Values.sso | default dict) "audience" -}}
{{- fail "sso.audience was removed: every SSO role accepts sso.oidc.clientId as the audience, because an ID token's aud is the client ID it was issued to. Delete sso.audience from your values (set sso.oidc.clientId to your IdP client instead)" -}}
{{- end -}}
{{- /* Vault Community has one namespace: a Vault namespace setting would be
       silently ignored by Vault and would make the chart's paths wrong. */ -}}
{{- if hasKey (.ctx.Values.vco | default dict) "namespace" -}}
{{- fail "vco.namespace is not supported: Vault Community Edition has no namespaces, so every path starts with the tenant's name instead. Delete vco.namespace from your values" -}}
{{- end -}}
{{- /* A sliced render only happens under the bootstrap's per-tenant
       TemplateInstance convention (mto-extension-vault-community-<tenant>[.eso]), and
       template-operator-v2 stamps that TI name as a label value on every
       rendered resource — Kubernetes caps label values at 63 chars. Fail with a
       clear message instead of letting every object bounce off server-side
       dry-run with an opaque invalid-label error. component=all (standalone,
       no TI) is exempt. */ -}}
{{- if ne .ctx.Values.component "all" -}}
{{- $suffix := index (dict "core" "" "eso" ".eso") .ctx.Values.component -}}
{{- $tiName := printf "mto-extension-vault-community-%s%s" (.ctx.Values.tenant | default "") $suffix -}}
{{- if gt (len $tiName) 63 -}}
{{- fail (printf "tenant name %q (%d chars) makes TemplateInstance name %q %d chars; it is stamped as a label value on every rendered resource and label values cap at 63 — shorten the tenant name (budget: ≤33 core, ≤29 .eso). Checked in every template, so the file named above is incidental." .ctx.Values.tenant (len .ctx.Values.tenant) $tiName (len $tiName)) -}}
{{- end -}}
{{- end -}}
{{- if or (eq .ctx.Values.component "all") (eq .ctx.Values.component .component) -}}true{{- end -}}
{{- end -}}

{{/*
Returns "true" when a toggle is on, "" when it is off. A boolean, or the string
"true"/"false"; absent or null is off. Anything else fails. Never test a toggle
with a bare `if .Values.x.enabled`: the string "false" is non-empty, so it is
TRUE to Go templates, and the schema accepts it (it has to — t-op-v2 and
--set-string send strings).
Usage: {{ if include "vault.on" (dict "name" "sso.enabled" "value" .Values.sso.enabled) }}
*/}}
{{- define "vault.on" -}}
{{- $v := .value -}}
{{- if kindIs "invalid" $v -}}
{{- else -}}
{{- $s := toString $v -}}
{{- if not (has $s (list "true" "false")) -}}
{{- fail (printf "%s must be true or false — got %q" .name $s) -}}
{{- end -}}
{{- if eq $s "true" -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Common labels stamped on every chart-emitted resource. The tenant label is the
same key the parent's namespaceSelector uses.
*/}}
{{- define "vault.labels" -}}
{{- $t := toString (required ".Values.tenant must be set by the parent" .Values.tenant) -}}
{{- /* A DNS label: it is the first segment of every Vault path the tenant
       owns, a label value, and a part of dot-joined names that must stay
       unambiguous. The Tenant CRD itself does not restrict names. */ -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $t) -}}
{{- fail (printf "tenant name %q is not a DNS label (lowercase letters, digits and hyphens, no dots)" $t) -}}
{{- end -}}
{{- if gt (len $t) 63 -}}
{{- fail (printf "tenant name %q is %d chars; it is stamped as the %q label value on every resource and a Kubernetes label value must be <=63 chars" $t (len $t) .Values.tenantLabelKey) -}}
{{- end -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: helm-via-template-operator-v2
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ .Values.tenantLabelKey }}: {{ $t | quote }}
{{- end -}}

{{/*
Fails the render if a generated resource name exceeds the 253-char Kubernetes
metadata.name limit, naming the offender. Returns the name unchanged.
*/}}
{{- define "vault.assertName" -}}
{{- if gt (len .) 253 -}}
{{- fail (printf "generated resource name %q is %d chars, over the 253-char Kubernetes name limit — shorten the tenant, namespace, service-account, or peer name" . (len .)) -}}
{{- end -}}
{{- . -}}
{{- end -}}

{{/*
Per-SA own-tenant role/policy name: kv.<tenant>.<saNs>.<sa>.

Joined with dots because none of the parts can contain one: the tenant is
checked by vault.labels, a namespace is a DNS label, and saFacts rejects a
dotted ServiceAccount name. With hyphens, namespace t-web + ServiceAccount api-x
and namespace t-web-api + ServiceAccount x gave the same name, and two tenants
whose names are prefixes of each other could collide in configNamespace.

The `kv.` prefix keeps the name families apart: kv.* has 4 parts, sso.* 3 and
share.* 6, so no name of one family can equal a name of another. Without it,
tenant "sso" with namespace "acme" and ServiceAccount "admin" rendered Policy
sso.acme.admin, the name of tenant acme's SSO admin Policy. On Community
Edition every policy is in Vault's one namespace, so this is the only thing
that keeps two tenants' policies apart by name.

The role annotation is deliberately not part of it: a role change would become
a rename.
*/}}
{{- define "vault.roleName" -}}
{{- include "vault.assertName" (printf "kv.%s.%s.%s" .tenant .saNs .saName) -}}
{{- end -}}

{{/*
The spec.authentication block of every VCO CR. Vault Community has one
namespace, so there is no namespace and no targetNamespace: VCO logs in at
vco.authPath and writes every object in that one namespace, at a path that
starts with the tenant's name.
Usage:
  spec:
    {{- include "vault.vcoAuth" $ | nindent 2 }}
*/}}
{{- define "vault.vcoAuth" -}}
{{- $v := .Values.vco -}}
authentication:
  path: {{ required "vco.authPath must be set" $v.authPath }}
  role: {{ required "vco.role must be set" $v.role }}
  serviceAccount:
    name: {{ required "vco.serviceAccount must be set" $v.serviceAccount }}
{{- end -}}

{{/*
The tenant's workload kubernetes auth mount, as Vault sees it, without the
auth/ prefix: <tenant>/<path>/<name>, for example team-a/kubernetes/workloads.
This is what VAULT_K8S_MOUNT, every role's spec.path and the SecretStores
carry. The AuthEngineMount takes it in two parts: spec.path <tenant>/<path>
and spec.name <name>.
*/}}
{{- define "vault.k8sAuthMount" -}}
{{- printf "%s/%s/%s" .Values.tenant (trimAll "/" .Values.kubernetesAuth.path) (trimAll "/" .Values.kubernetesAuth.name) -}}
{{- end -}}

{{/*
The scope check (docs/design.md §4, ADR-0003) on one policy body, at render.
Community Edition has no namespace wall: a policy path one character too wide
reaches another tenant (P1, P2). So every line of every policy the chart
renders must be:
  - a comment, or a one-line stanza: path "<p>" { capabilities = ["a", "b"] },
    with no sudo — the check sees every path, and nothing can hide one;
  - a path inside the policy's own scope, by its name family:
      kv.<t>.… and sso.<t>.…  <t>/kv/(data|metadata|delete|undelete|destroy)/<env>/…
                              (an sso policy may also list <t>/kv/metadata)
      share.<t>.….out.<p>     shared/kv/(data|metadata)/<env>/from-<t>/to-<p>/*
      share.<t>.….in.<p>      shared/kv/(data|metadata)/<env>/from-<p>/to-<t>/*, read and list only
  - with no `+`, and `*` only as the last character, after a `/`.
The tenant segment is always followed by "/", so tenant "team" never matches
"team-a/". A violation fails the render: it is the chart's own mistake, and
the admission policies would refuse the object anyway.
Usage: {{ include "vault.assertPolicyScope" (dict "name" $name "policy" $body "ctx" $) }}
*/}}
{{- define "vault.assertPolicyScope" -}}
{{- $name := .name -}}
{{- $parts := splitList "." $name -}}
{{- $fam := index $parts 0 -}}
{{- $t := toString .ctx.Values.tenant -}}
{{- $env := toString .ctx.Values.env -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $env) -}}
{{- fail (printf "env %q is not a DNS label: it is a segment of every policy path" $env) -}}
{{- end -}}
{{- if or (lt (len $parts) 2) (ne (index $parts 1) $t) -}}
{{- fail (printf "scope check: policy %q does not belong to tenant %q" $name $t) -}}
{{- end -}}
{{- $stanza := "^path \"([^\"]+)\" +[{] capabilities = \\[\"[a-z]+\"(, \"[a-z]+\")*\\] [}]$" -}}
{{- $scope := "" -}}
{{- if or (eq $fam "kv") (eq $fam "sso") -}}
{{- $scope = printf "^%s/kv/(data|metadata|delete|undelete|destroy)/%s/([a-z0-9_][-a-z0-9_.]*/)*[*]$" $t $env -}}
{{- else if and (eq $fam "share") (eq (len $parts) 6) (eq (index $parts 4) "out") -}}
{{- $scope = printf "^shared/kv/(data|metadata)/%s/from-%s/to-%s/[*]$" $env $t (index $parts 5) -}}
{{- else if and (eq $fam "share") (eq (len $parts) 6) (eq (index $parts 4) "in") -}}
{{- $scope = printf "^shared/kv/(data|metadata)/%s/from-%s/to-%s/[*]$" $env (index $parts 5) $t -}}
{{- else -}}
{{- fail (printf "scope check: policy %q is in no name family (kv. 4 parts, share. 6, sso. 3)" $name) -}}
{{- end -}}
{{- range $raw := splitList "\n" .policy -}}
{{- $l := trim $raw -}}
{{- if and $l (not (hasPrefix "#" $l)) -}}
{{- if not (regexMatch $stanza $l) -}}
{{- fail (printf "scope check: policy %q has a line that is not a one-line path stanza: %q" $name $l) -}}
{{- end -}}
{{- if contains "\"sudo\"" $l -}}
{{- fail (printf "scope check: policy %q grants sudo: %q" $name $l) -}}
{{- end -}}
{{- $p := regexReplaceAll $stanza $l "${1}" -}}
{{- $ok := regexMatch $scope $p -}}
{{- if and (not $ok) (eq $fam "sso") (eq $p (printf "%s/kv/metadata" $t)) -}}{{- $ok = true -}}{{- end -}}
{{- if not $ok -}}
{{- fail (printf "scope check: policy %q names path %q, outside its scope %s" $name $p $scope) -}}
{{- end -}}
{{- if and (eq $fam "share") (eq (index $parts 4) "in") (regexMatch "\"(create|update|patch|delete)\"" $l) -}}
{{- fail (printf "scope check: import policy %q writes: %q" $name $l) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
A workload token duration, in the integer seconds VCO's KubernetesAuthEngineRole
takes. A duration string ("1h") would render fine and then fail server-side
validation of the whole TemplateInstance apply, so it is rejected here with the
fix in the message. Returns "" for 0, meaning "omit, use Vault's default".
Usage: {{ include "vault.tokenSeconds" (dict "name" "token.ttl" "value" $.Values.token.ttl) }}
*/}}
{{- define "vault.tokenSeconds" -}}
{{- $v := .value -}}
{{- /* sprig `get` returns "" for a missing key, so "" means unset. */ -}}
{{- if or (kindIs "invalid" $v) (and (kindIs "string" $v) (eq $v "")) -}}
{{- else if kindIs "string" $v -}}
{{- fail (printf "%s must be an integer number of seconds — got the string %q. vault-config-operator's KubernetesAuthEngineRole takes seconds (3600, not \"1h\")." .name $v) -}}
{{- else -}}
{{- $n := int64 $v -}}
{{- if ne (float64 $n) (float64 $v) -}}
{{- fail (printf "%s must be a whole number of seconds — got %v" .name $v) -}}
{{- end -}}
{{- if lt $n 0 -}}
{{- fail (printf "%s must not be negative — got %d" .name $n) -}}
{{- end -}}
{{- if gt $n 0 -}}{{- $n -}}{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Token type stamped on every KubernetesAuthEngineRole.

  service  Vault persists the token: it can be renewed and REVOKED, and it is
           enumerable through its accessor.
  batch    never written to storage; far cheaper per login, but it cannot be
           renewed, revoked or listed — its TTL is the only way to retire it.

token.period is rejected with batch: Vault accepts period on a batch token and
ignores it, so a grant that reads as periodic would not be.
*/}}
{{- define "vault.tokenType" -}}
{{- $token := .Values.token | default dict -}}
{{- $t := "service" -}}
{{- if hasKey $token "type" -}}
{{- $t = get $token "type" | toString -}}
{{- end -}}
{{- if not (has $t (list "service" "batch")) -}}
{{- fail (printf "token.type must be \"service\" or \"batch\" — got %q. Vault also accepts default/default-service/default-batch, which resolve against the auth mount's tune and so make the token semantics depend on state this chart does not own; they are rejected here." $t) -}}
{{- end -}}
{{- if and (eq $t "batch") (include "vault.tokenSeconds" (dict "name" "token.period" "value" (get $token "period"))) -}}
{{- fail (printf "token.type=batch with token.period=%v: a batch token cannot be renewed, and Vault silently ignores period on one. Set token.period to 0 or use token.type=service." (get $token "period")) -}}
{{- end -}}
{{- $t -}}
{{- end -}}

{{/*
The token fields of a KubernetesAuthEngineRole spec, shared by the own-tenant
and share roles so they cannot drift.
*/}}
{{- define "vault.roleTokenFields" -}}
tokenType: {{ include "vault.tokenType" . }}
{{- with include "vault.tokenSeconds" (dict "name" "token.ttl" "value" .Values.token.ttl) }}
tokenTTL: {{ . }}
{{- end }}
{{- with include "vault.tokenSeconds" (dict "name" "token.maxTTL" "value" .Values.token.maxTTL) }}
tokenMaxTTL: {{ . }}
{{- end }}
{{- with include "vault.tokenSeconds" (dict "name" "token.period" "value" .Values.token.period) }}
tokenPeriod: {{ . }}
{{- end }}
{{- end -}}

{{/*
The namespace binding of every workload role (KubernetesAuthEngineRole
spec.targetNamespaces): the ServiceAccount's namespace by its name AND the
tenant label. VCO resolves the selector to namespace names and watches
namespaces (V10). Bound by name alone, a namespace of the same name created
later by another tenant would get the role (Q13): Kubernetes does not reserve
namespace names per tenant (K1), and Vault binds names only.
Usage: {{ include "vault.roleNamespaces" (dict "ns" $saNs "ctx" $) | nindent 2 }}
*/}}
{{- define "vault.roleNamespaces" -}}
targetNamespaces:
  targetNamespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: {{ .ns | quote }}
      {{ .ctx.Values.tenantLabelKey }}: {{ .ctx.Values.tenant | quote }}
{{- end -}}

{{/*
The complete set of `vault.stakater.com/` keys this chart reads on a
ServiceAccount, so an unrecognised one is reported rather than ignored. A new
annotation must be added here too, or it is rejected as unknown — loud, and the
safe direction to fail.
*/}}
{{- define "vault.saAnnotationKeys" -}}
{{- $keys := list "kv" "role" "app" -}}
{{- toYaml $keys -}}
{{- end -}}

{{/*
Resolves and validates every `vault.stakater.com/` annotation on one
ServiceAccount, returning a YAML dict the caller parses with `fromYaml`. One
helper, so validation and the values used to render cannot drift apart.

Returns: name, ns, app, role, kvOn, caps, and `errors`. A non-empty `errors`
means the caller renders the error ConfigMap and nothing else for this
ServiceAccount.

Reported per ServiceAccount rather than failed: one TemplateInstance renders
every namespace a tenant owns, so `fail` would produce zero objects for the
tenant and freeze unrelated namespaces.
*/}}
{{- define "vault.saFacts" -}}
{{- /* Both maps are required. Defaulting them would leave the app-collision and
       foreign-namespace checks inert for a caller that forgot to thread them. */ -}}
{{- if not (hasKey . "appClaims") -}}
{{- fail "vault.saFacts requires an appClaims argument (see vault.appClaims); omitting it would silently disable the app-collision check" -}}
{{- end -}}
{{- if not (hasKey . "tenantNamespaces") -}}
{{- fail "vault.saFacts requires a tenantNamespaces argument (see vault.tenantNamespaces); omitting it would silently disable the foreign-namespace check" -}}
{{- end -}}
{{- $sa := .sa -}}
{{- $v := .ctx.Values -}}
{{- $p := "vault.stakater.com/" -}}
{{- $known := include "vault.saAnnotationKeys" . | fromYamlArray -}}
{{- $name := dig "metadata" "name" "" $sa -}}
{{- $ns := dig "metadata" "namespace" "" $sa -}}
{{- $ann := dig "metadata" "annotations" (dict) $sa -}}
{{- $errs := list -}}

{{- /* Unknown key, checked first: a misspelled key means nothing read below
       reflects what the user meant. transit and pki are named separately: they
       exist in the OpenBao extension and are a likely thing to try here. */ -}}
{{- $hasVault := false -}}
{{- range $k, $_ := $ann -}}
{{- if hasPrefix $p $k -}}
{{- $hasVault = true -}}
{{- $short := trimPrefix $p $k -}}
{{- if or (hasPrefix "transit" $short) (hasPrefix "pki" $short) -}}
{{- $errs = append $errs (printf "annotation %q is not supported: this extension configures KV only — transit and PKI are not available yet" $k) -}}
{{- else if not (has $short $known) -}}
{{- $errs = append $errs (printf "unknown annotation %q — this chart reads none of that name, so it has no effect. Valid keys: %s" $k (join ", " (sortAlpha $known))) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* Rendered ConfigMap and SecretStore names embed this name and reserve
       dot-separated suffixes (.error, .deploy-error, .share-<peer>-vault). */ -}}
{{- if and $hasVault (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name)) -}}
{{- $errs = append $errs (printf "ServiceAccount name %q cannot be used with Vault: rendered ConfigMap and SecretStore names embed it and reserve dot-separated suffixes (.error, .share-<peer>-vault), so it must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ (lowercase letters, digits and hyphens — no dots). Rename the ServiceAccount" $name) -}}
{{- end -}}

{{- /* A misspelled boolean would leave KV off with no message. */ -}}
{{- $kvRaw := lower (trim (toString (dig "metadata" "annotations" (printf "%skv" $p) "" $sa))) -}}
{{- if and $kvRaw (not (has $kvRaw (list "true" "false"))) -}}
{{- $errs = append $errs (printf "%skv must be \"true\" or \"false\", got %q" $p $kvRaw) -}}
{{- end -}}
{{- $kvOn := eq $kvRaw "true" -}}

{{- $role := trim (toString (dig "metadata" "annotations" (printf "%srole" $p) "" $sa)) -}}
{{- $app := trim (toString (dig "metadata" "annotations" (printf "%sapp" $p) "" $sa)) -}}
{{- if not $app -}}{{- $app = $name -}}{{- end -}}

{{- /* Every pod that omits serviceAccountName runs as `default`, so granting it
       hands one identity and one prefix to all of them. */ -}}
{{- if and (eq $name "default") $kvOn -}}
{{- $errs = append $errs (printf "the `default` ServiceAccount cannot be granted Vault access: every pod that omits serviceAccountName runs as `default`, so they would all share one identity and the prefix %s/kv/data/%s/%s/default/. Give each workload its own ServiceAccount and annotate that instead" $v.tenant $v.env $ns) -}}
{{- end -}}

{{- /* An engine without a role grants nothing, and a role without an engine
       grants nothing. */ -}}
{{- if and $role (not $kvOn) -}}
{{- $errs = append $errs (printf "%srole is set to %q but %skv is not \"true\", so nothing is granted" $p $role $p) -}}
{{- end -}}
{{- if and $kvOn (not $role) -}}
{{- $errs = append $errs (printf "%skv is \"true\" but %srole is not set, so no capabilities can be granted. Set a role: %s" $p $p (join ", " (keys $v.roleCaps | sortAlpha))) -}}
{{- end -}}
{{- if and (dig "metadata" "annotations" (printf "%sapp" $p) "" $sa) (not $kvOn) -}}
{{- $errs = append $errs (printf "%sapp is set but %skv is not \"true\", so no app identity is registered — it only names the prefix a KV grant would use" $p $p) -}}
{{- end -}}

{{- /* An unknown role makes the capability lookup nil, which would skip the
       ServiceAccount with no signal. */ -}}
{{- if and $role (not (hasKey $v.roleCaps $role)) -}}
{{- $errs = append $errs (printf "%srole %q is not a known role. Valid roles: %s" $p $role (join ", " (keys $v.roleCaps | sortAlpha))) -}}
{{- end -}}
{{- $caps := "" -}}
{{- if hasKey $v.roleCaps $role -}}
{{- $caps = index $v.roleCaps $role -}}
{{- end -}}
{{- if and $kvOn $role (hasKey $v.roleCaps $role) (or (not $caps) (eq $caps "[]")) -}}
{{- $errs = append $errs (printf "%skv is enabled but role %q grants no KV capabilities" $p $role) -}}
{{- end -}}

{{- /* The app name becomes a path segment inside an HCL policy body.
       Unvalidated it is not a name but a policy the tenant writes: a value with
       a quote and a brace closes our `path "..."` block and opens another, and
       `+` is Vault's single-segment wildcard. Underscore-prefixed names are
       reserved for chart-owned prefixes such as `_shared`. */ -}}
{{- if $kvOn -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $app) -}}
{{- $errs = append $errs (printf "%sapp %q is not a valid app name — it must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ (lowercase letters, digits and hyphens; no leading or trailing hyphen). It is used as a path segment in the Vault policy" $p $app) -}}
{{- else if gt (len $app) 63 -}}
{{- $errs = append $errs (printf "%sapp %q is %d characters; keep it to 63 or fewer" $p $app (len $app)) -}}
{{- end -}}
{{- end -}}

{{- /* Two ServiceAccounts resolving to one app share a prefix. Compared on
       RESOLVED names, so an SA that declared no `app` still defends its own
       name against another claiming it. */ -}}
{{- $claim := index .appClaims (printf "%s/%s" $ns $app) -}}
{{- if and $kvOn $claim (gt (len $claim) 1) -}}
{{- $errs = append $errs (printf "app %q in namespace %s is claimed by more than one ServiceAccount (%s). Each app owns its own secret prefix, so the name must be unique within the namespace — change %sapp on all but one" $app $ns (join ", " $claim) $p) -}}
{{- end -}}

{{- $out := dict
      "name" $name "ns" $ns "app" $app "role" $role
      "kvOn" $kvOn "caps" $caps
      "errors" $errs -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Builds the (namespace, resolved app) claim map: "<ns>/<app>" -> sorted
ServiceAccount names resolving to it. Only ServiceAccounts with KV on claim an
app. Sorted so the message is stable whatever order the parent lists them in.
*/}}
{{- define "vault.appClaims" -}}
{{- $p := "vault.stakater.com/" -}}
{{- $claims := dict -}}
{{- range $sa := (ternary .Values.serviceAccounts (list) (kindIs "slice" .Values.serviceAccounts)) -}}
{{- $name := dig "metadata" "name" "" $sa -}}
{{- $ns := dig "metadata" "namespace" "" $sa -}}
{{- $on := eq (lower (trim (toString (dig "metadata" "annotations" (printf "%skv" $p) "" $sa)))) "true" -}}
{{- if and $on $name $ns -}}
{{- $app := trim (toString (dig "metadata" "annotations" (printf "%sapp" $p) "" $sa)) -}}
{{- if not $app -}}{{- $app = $name -}}{{- end -}}
{{- $k := printf "%s/%s" $ns $app -}}
{{- $_ := set $claims $k (append (index $claims $k | default (list)) $name | sortAlpha) -}}
{{- end -}}
{{- end -}}
{{- toYaml $claims -}}
{{- end -}}

{{/*
Reports a misconfiguration next to the object that carries it. No
`vault-config-<sa>` is rendered for a ServiceAccount with errors, so the pod
fails to start on the missing `configMapRef` and this object, beside it in the
same namespace, says why.
*/}}
{{- define "vault.errorConfigMap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .name }}
  namespace: {{ .ns }}
  labels:
    {{- .labels | nindent 4 }}
data:
  ERROR: |
    Vault access has NOT been configured for {{ .subject }}.
    {{- range $i, $e := .errors }}
    {{ add1 $i }}. {{ $e }}
    {{- end }}
{{- end -}}

{{/*
Set of every Kubernetes namespace this tenant owns, from the ServiceAccount and
Deployment lists the child TI resolves through its namespaceSelector.
*/}}
{{- define "vault.tenantNamespaces" -}}
{{- $ns := dict -}}
{{- range $sa := (ternary .Values.serviceAccounts (list) (kindIs "slice" .Values.serviceAccounts)) -}}
{{- $n := dig "metadata" "namespace" "" $sa -}}
{{- if $n }}{{- $_ := set $ns $n true -}}{{- end -}}
{{- end -}}
{{- range $d := (ternary .Values.deployments (list) (kindIs "slice" .Values.deployments)) -}}
{{- $n := dig "metadata" "namespace" "" $d -}}
{{- if $n }}{{- $_ := set $ns $n true -}}{{- end -}}
{{- end -}}
{{- toYaml $ns -}}
{{- end -}}
