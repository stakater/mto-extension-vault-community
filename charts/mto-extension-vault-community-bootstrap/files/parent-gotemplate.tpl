{{- $cfgNs := .parameters.configNamespace }}
{{- $childTemplate := .parameters.childTemplateName }}
{{- $tenantLabel := .parameters.tenantLabelKey }}
{{- $shared := .parameters.sharedTenantName }}
{{- $eso := .parameters.eso }}
{{- $k8sPath := .parameters.k8sAuthPath }}
{{- $k8sName := .parameters.k8sAuthName }}
{{- $reviewer := .parameters.tokenReviewerServiceAccount }}
{{- $reserved := splitList "," .parameters.reservedNames }}
{{- /* The spec.authentication block every CR here carries. The tenant chart
       renders the same block from the same values. Vault Community has no
       namespaces, so there is no namespace and no targetNamespace: every
       object lands in Vault's one namespace, at a path that starts with the
       tenant's name. */ -}}
{{- $auth := printf "path: %s\n    role: %s\n    serviceAccount:\n      name: %s" .parameters.vcoAuthPath .parameters.vcoRole .parameters.vcoServiceAccount }}
{{- /* Namespaces per tenant, counted from the <tenantLabel> label: the ONLY
       fact MTO and this chart both agree on. MTO puts that label on a
       namespace whether it is listed in the Tenant spec or adopted by label,
       and it is exactly what the child TI's namespaceSelector resolves. */ -}}
{{- $nsCount := dict }}
{{- range $ns := (default list .parameters.tenantNamespaces) }}
{{- $owner := dig "metadata" "labels" $tenantLabel "" $ns }}
{{- if $owner }}
{{- $_ := set $nsCount $owner (add1 (int (get $nsCount $owner))) }}
{{- end }}
{{- end }}
{{- /* Tenants this parent renders for. Skipped, and listed in the
       skipped-tenants ConfigMap with the reason, so a skip is visible:
         - a name that is not a DNS label: the Tenant CRD does not restrict
           names, and a dot or an uppercase letter breaks the mount path, the
           label value and the dot-joined object names;
         - a name longer than 63 characters: it is the tenant label value on
           the kv mount CR below and in the child TI's namespaceSelector, and a
           label value caps at 63. Rendered, it would fail the apply of this
           whole render, for every tenant;
         - a reserved name: the first segment of a path Vault or the platform
           already uses. The tenant's mount <tenant>/kv and its auth mounts
           auth/<tenant>/... would nest under that path, and Vault refuses a
           mount nested under another. The shared name is one of them: its
           mounts are the shared ones, and two renders would fight over them. */ -}}
{{- $tenants := list }}
{{- $skipped := dict }}
{{- range $t := (default list .parameters.tenants) }}
{{- $n := toString $t.metadata.name }}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $n) }}
{{- $_ := set $skipped $n "the name is not a DNS label (lowercase letters, digits and hyphens, no dots): nothing is rendered for this tenant" }}
{{- else if gt (len $n) 63 }}
{{- $_ := set $skipped $n (printf "the name is %d characters: it is a label value, and label values cap at 63: nothing is rendered for this tenant" (len $n)) }}
{{- else if eq $n $shared }}
{{- $_ := set $skipped $n (printf "the name is the shared prefix %q (shared/kv, auth/%s/...): nothing is rendered for this tenant" $shared $shared) }}
{{- else if has $n $reserved }}
{{- $_ := set $skipped $n (printf "the name is reserved: %s/ or auth/%s/ is a path Vault or the platform already uses, and Vault refuses a mount nested under another: nothing is rendered for this tenant" $n $n) }}
{{- else }}
{{- $tenants = append $tenants $n }}
{{- end }}
{{- end }}
{{- /* Comma-separated roster of tenant names a share can usefully target: those
       with a labelled namespace, because only they get a workload render. It
       self-heals when a tenant gets its first labelled namespace. */ -}}
{{- $withNs := list }}
{{- range $n := $tenants }}
{{- if gt (int (get $nsCount $n)) 0 }}{{ $withNs = append $withNs $n }}{{ end }}
{{- end }}
{{- $knownTenants := join "," $withNs }}
{{- if $skipped }}
---
apiVersion: v1
kind: ConfigMap
metadata: { name: mto-extension-vault-community-skipped-tenants, namespace: {{ $cfgNs }} }
data:
  {{- range $n, $reason := $skipped }}
  {{ $n | quote }}: {{ $reason | quote }}
  {{- end }}
{{- end }}
{{- /* The shared mount shared/kv, where cross-tenant shares land. */}}
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: SecretEngineMount
metadata: { name: {{ printf "%s-kv" $shared | quote }}, namespace: {{ $cfgNs }} }
spec:
  authentication:
    {{ $auth }}
  path: {{ $shared | quote }}
  name: kv
  type: kv
  # VCO adds its finalizer with an update that sends every config field, and
  # an unset listingVisibility goes as "", which VCO's own CRD enum refuses.
  # The CR then has no finalizer, and deleting it never deletes the mount in
  # Vault. "hidden" is Vault's default.
  config:
    listingVisibility: hidden
  options:
    version: "2"
{{- /* The share roles' auth mount auth/<shared>/<path>/<name>. One for every
       tenant: a share role is bound to its own ServiceAccount, namespace name
       and tenant label, so the mount is not the wall. */}}
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: AuthEngineMount
metadata: { name: {{ printf "%s-kubernetes" $shared | quote }}, namespace: {{ $cfgNs }} }
spec:
  authentication:
    {{ $auth }}
  path: {{ printf "%s/%s" $shared $k8sPath | quote }}
  name: {{ $k8sName }}
  type: kubernetes
  # listingVisibility: see the shared kv mount above.
  config:
    listingVisibility: hidden
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: KubernetesAuthEngineConfig
metadata: { name: {{ printf "%s-kubernetes-config" $shared | quote }}, namespace: {{ $cfgNs }} }
spec:
  authentication:
    {{ $auth }}
  path: {{ printf "%s/%s" $shared $k8sPath | quote }}
  name: {{ $k8sName }}
  kubernetesHost: {{ .parameters.kubernetesHost }}
{{- if $reviewer }}
  tokenReviewerServiceAccount:
    name: {{ $reviewer }}
{{- end }}
{{- range $name := $tenants }}
{{- /* Every tenant's kv mount <tenant>/kv, rendered HERE rather than in the
       tenant chart, so it lives as long as the Tenant CR. The child TIs below
       exist only while the tenant has a labelled namespace; had the mount been
       in them, deleting the tenant's last namespace would have deleted every
       secret in it. */}}
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: SecretEngineMount
metadata: { name: {{ printf "%s-kv" $name | quote }}, namespace: {{ $cfgNs }}, labels: { {{ $tenantLabel }}: {{ $name | quote }} } }
spec:
  authentication:
    {{ $auth }}
  path: {{ $name | quote }}
  name: kv
  type: kv
  # listingVisibility: see the shared kv mount above.
  config:
    listingVisibility: hidden
  options:
    version: "2"
{{- /* The workload render, only for a tenant with a labelled namespace: its
       child TI resolves serviceAccounts/deployments through a namespaceSelector
       on the tenant label, and with zero matching namespaces t-op-v2 fails it
       (NamespaceSelectorMatchedZero). It self-heals when the first namespace is
       labelled. One TI per enabled component; the optional suffix uses a dot
       because tenant names are DNS labels (checked above), so the core TI of
       tenant "<x>-eso" cannot collide with the eso TI of tenant "<x>". */ -}}
{{- if gt (int (get $nsCount $name)) 0 }}
{{- $slices := list (dict "suffix" "" "tmpl" "") }}
{{- if eq $eso "enabled" }}{{- $slices = append $slices (dict "suffix" ".eso" "tmpl" "-eso") }}{{- end }}
{{- range $slice := $slices }}
---
apiVersion: templates.v2.stakater.com/v2alpha1
kind: TemplateInstance
metadata:
  name: {{ printf "mto-extension-vault-community-%s%s" $name $slice.suffix | quote }}
  namespace: {{ $cfgNs }}
spec:
  templateRef:
    name: {{ $childTemplate }}{{ $slice.tmpl }}
    namespace: {{ $cfgNs }}
  parameters:
    - name: tenant
      value: {{ $name | quote }}
    - name: knownTenants
      value: {{ $knownTenants | quote }}
    - name: serviceAccounts
      valueFrom:
        objectFieldRef:
          apiVersion: v1
          kind: ServiceAccount
          jsonPath: .items
          namespaceSelector:
            matchLabels:
              {{ $tenantLabel }}: {{ $name | quote }}
    - name: deployments
      valueFrom:
        objectFieldRef:
          apiVersion: apps/v1
          kind: Deployment
          jsonPath: .items
          namespaceSelector:
            matchLabels:
              {{ $tenantLabel }}: {{ $name | quote }}
{{- end }}
{{- end }}
{{- end }}
