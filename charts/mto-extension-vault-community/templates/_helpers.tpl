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
