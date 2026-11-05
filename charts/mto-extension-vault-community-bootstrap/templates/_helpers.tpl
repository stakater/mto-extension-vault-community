{{/*
Integration toggles, validated and normalised in one place.

Every toggle is consumed as a STRING comparison (`eq … "true"` /
`eq … "enabled"`), because it travels through a t-op-v2 Template parameter,
which is typed string. That makes a typo silent: `yes`, `on`, `True` and `1`
all fail the comparison, so the integration renders nothing and says nothing.

These helpers `fail` on anything that is not a canonical value. For every value
they accept, the canonical form equals what `.Values.<toggle> | quote` would
have produced — the point is the guard, not the conversion. They are what
survive `--skip-schema-validation` and SDK render paths that do not apply
values.schema.json, and they give files/parent-gotemplate.tpl (rendered by
t-op-v2, where this chart's validation cannot reach) the guarantee that its
parameters are only ever "true"/"false" or "enabled"/"disabled".

Never compare .Values.<toggle> directly — go through the named helper.
*/}}
{{- define "mto-extension-vault-community-bootstrap.boolValue" -}}
{{- $raw := .value -}}
{{- $s := "" -}}
{{- if kindIs "invalid" $raw -}}
{{- $s = "false" -}}
{{- else -}}
{{- $s = toString $raw -}}
{{- end -}}
{{- if not (has $s (list "true" "false")) -}}
{{- fail (printf "%s must be a boolean true or false — got %q. Quoted \"true\"/\"false\" also work; anything else (yes, on, 1, True, TRUE) is silently NOT enabled, so it is rejected here instead." .name $s) -}}
{{- end -}}
{{- $s -}}
{{- end -}}

{{- define "mto-extension-vault-community-bootstrap.esoMode" -}}
{{- $raw := .Values.parent.eso -}}
{{- $s := "" -}}
{{- if kindIs "invalid" $raw -}}
{{- $s = "disabled" -}}
{{- else -}}
{{- $s = toString $raw -}}
{{- end -}}
{{- if not (has $s (list "enabled" "disabled")) -}}
{{- fail (printf "parent.eso must be \"enabled\" or \"disabled\" — got %q. It is a string, not a boolean: true/false/yes/on are silently NOT enabled, so they are rejected here instead." $s) -}}
{{- end -}}
{{- $s -}}
{{- end -}}

{{/* parent.sso is nullable, and a chained deref through it nil-pointers the
     whole render. `parent` itself is required by values.schema.json. */}}
{{- define "mto-extension-vault-community-bootstrap.parentSso" -}}
{{- toYaml ((.Values.parent | default dict).sso | default dict) -}}
{{- end -}}

{{- define "mto-extension-vault-community-bootstrap.ssoEnabled" -}}
{{- $sso := include "mto-extension-vault-community-bootstrap.parentSso" . | fromYaml -}}
{{- include "mto-extension-vault-community-bootstrap.boolValue" (dict "name" "parent.sso.enabled" "value" $sso.enabled) -}}
{{- end -}}

{{/*
Drift-protection block (t-op-v2 Template spec.sync) from .Values.sync. An absent
or null mode falls back to the chart default; an explicit empty string fails, so
a wrapper passing an unset variable cannot silently ship without drift
protection. Emits nothing for "off".
*/}}
{{- define "mto-extension-vault-community-bootstrap.templateSync" -}}
{{- $sync := .Values.sync | default dict -}}
{{- $mode := "revert" -}}
{{- if hasKey $sync "mode" -}}
{{- $mode = $sync.mode | toString -}}
{{- end -}}
{{- if not (has $mode (list "off" "revert" "strict")) -}}
{{- fail (printf "sync.mode must be one of off, revert, strict — got %q (unquoted on/yes/true parse as YAML booleans; quote the value)" $mode) -}}
{{- end -}}
{{- if ne $mode "off" -}}
sync:
  mode: {{ $mode }}
{{- with $sync.ignoreFields }}
  ignoreFields:
    {{- toYaml . | nindent 4 }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
The redhatcop.redhat.io kinds the tenant chart and the parent render. One list,
so the RBAC ClusterRole, the RBAC Role and the Template outputs cannot drift.
Each entry: resource (plural, for RBAC) and kind (for outputs). There is no
Namespace kind: Vault Community Edition has no namespaces.
*/}}
{{- define "mto-extension-vault-community-bootstrap.vcoKinds" -}}
- { resource: secretenginemounts,          kind: SecretEngineMount,          output: engines }
- { resource: authenginemounts,            kind: AuthEngineMount,            output: authMounts }
- { resource: kubernetesauthengineconfigs, kind: KubernetesAuthEngineConfig, output: k8sAuthConfigs }
- { resource: kubernetesauthengineroles,   kind: KubernetesAuthEngineRole,   output: k8sAuthRoles }
- { resource: policies,                    kind: Policy,                     output: policies }
- { resource: jwtoidcauthengineconfigs,    kind: JWTOIDCAuthEngineConfig,    output: oidcConfigs }
- { resource: jwtoidcauthengineroles,      kind: JWTOIDCAuthEngineRole,      output: oidcRoles }
{{- end -}}

{{/*
t-op-v2 status outputs for the VCO kinds, one output per kind.

VCO's status cannot say whether an object is healthy NOW. It sets two condition
types side by side — ReconcileSuccessful (always status True) and
ReconcileFailed (always status False) — and both lastTransitionTime values
freeze after their first write, because a condition's transition time only
moves when its status changes and these never do. So:
  <output>Succeeded  "True" once the object has been written to Vault at least
                     once; "[]" means never — the one unambiguous failure.
  <output>LastError  the message of the most recent failed reconcile, EVER. It
                     stays after the object recovers.
Field names carry the output name because t-op-v2 rejects a field name that
repeats across outputs, and then resolves none of them. Both are filter paths,
never scalars: a filter matching nothing resolves to "[]", a scalar matching
nothing fails the whole field.
Usage: {{ include "mto-extension-vault-community-bootstrap.vcoOutputs" (dict "ns" $ns "kinds" $kinds) }}
*/}}
{{- define "mto-extension-vault-community-bootstrap.vcoOutputs" -}}
{{- range $k := .kinds }}
- name: {{ $k.output }}
  fromAll:
    apiVersion: redhatcop.redhat.io/v1alpha1
    kind: {{ $k.kind }}
    namespace: {{ $.ns }}
  keyTemplate: "{.metadata.name}"
  fields:
    - { name: {{ $k.output }}Succeeded, jsonPath: "{.status.conditions[?(@.type=='ReconcileSuccessful')].status}" }
    - { name: {{ $k.output }}LastError, jsonPath: "{.status.conditions[?(@.type=='ReconcileFailed')].message}" }
{{- end }}
{{- end -}}

{{/*
The install-wide part of every child TemplateInstance's values, as YAML: the
tenant chart values that are the same for every tenant. Only tenant,
knownTenants, serviceAccounts and deployments differ per tenant; the child
valuesTemplate adds those as t-op-v2 placeholders.

.Values.tenantValues is merged in as given, so any tenant chart value can be set
install-wide (vaultCABundle, monitoring, sso.oidc.*, sso.roles, roleCaps, …).
A key this chart already owns fails the render instead of being silently
overridden, naming the bootstrap value to set instead. values.schema.json
refuses a key the tenant chart does not have (render test tenantvaluekeys).

t-op-v2 renders the valuesTemplate as a Go template, so a value containing "{{"
would be executed there; that fails here too.
*/}}
{{- define "mto-extension-vault-community-bootstrap.installWideValues" -}}
{{- $tv := deepCopy (.Values.tenantValues | default dict) -}}
{{- $owned := dict
      "component" "set per slice by this chart"
      "tenant" "set per tenant by the parent"
      "knownTenants" "set per tenant by the parent"
      "serviceAccounts" "set per tenant by the parent"
      "deployments" "set per tenant by the parent"
      "env" "parent.env"
      "vaultServer" "parent.vaultServer"
      "eso" "parent.eso"
      "externalSecretRefreshInterval" "parent.externalSecretRefreshInterval"
      "configNamespace" "configNamespace"
      "vco" "vco"
      "kubernetesAuth" "kubernetesAuth"
      "tenantLabelKey" "parent.tenantLabelKey"
      "sharedTenant" "parent.sharedTenantName"
      "token" "parent.token" -}}
{{- range $k, $use := $owned -}}
{{- if hasKey $tv $k -}}
{{- fail (printf "tenantValues.%s is set by this chart — use %s instead" $k $use) -}}
{{- end -}}
{{- end -}}
{{- if hasKey $tv "networkPolicy" -}}
{{- fail "tenantValues.networkPolicy: the tenant chart's NetworkPolicy feature was removed — tenant egress policy belongs to MTO. Delete it" -}}
{{- end -}}
{{- $parentSso := include "mto-extension-vault-community-bootstrap.parentSso" . | fromYaml -}}
{{- /* Checked here, once, rather than left to the tenant chart: there it fails
       every tenant's core render while this install reports success. */ -}}
{{- if and (eq (include "mto-extension-vault-community-bootstrap.ssoEnabled" .) "true") (not $parentSso.issuerUrl) -}}
{{- fail "parent.sso.enabled=true requires parent.sso.issuerUrl — without it every tenant's render fails" -}}
{{- end -}}
{{- $sso := $tv.sso | default dict -}}
{{- range $k, $use := dict "enabled" "parent.sso.enabled" "allowedRedirectUris" "parent.sso.allowedRedirectUris" -}}
{{- if hasKey $sso $k -}}
{{- fail (printf "tenantValues.sso.%s is set by this chart — use %s instead" $k $use) -}}
{{- end -}}
{{- end -}}
{{- if hasKey $sso "audience" -}}
{{- fail "tenantValues.sso.audience was removed — every SSO role accepts tenantValues.sso.oidc.clientId as the audience, because an ID token's aud is the client ID. Delete it (set sso.oidc.clientId to your IdP client instead)" -}}
{{- end -}}
{{- $oidc := $sso.oidc | default dict -}}
{{- if hasKey $oidc "perTenantClient" -}}
{{- fail "tenantValues.sso.oidc.perTenantClient: the per-tenant client option was removed — every tenant uses the one shared IdP client sso.oidc.clientId. Delete it" -}}
{{- end -}}
{{- if hasKey $oidc "issuerUrl" -}}
{{- fail "tenantValues.sso.oidc.issuerUrl is set by this chart — use parent.sso.issuerUrl instead" -}}
{{- end -}}
{{- $_ := set $oidc "issuerUrl" ($parentSso.issuerUrl | default "") -}}
{{- $_ := set $sso "oidc" $oidc -}}
{{- $_ := set $sso "enabled" (eq (include "mto-extension-vault-community-bootstrap.ssoEnabled" .) "true") -}}
{{- with $parentSso.allowedRedirectUris }}{{ $_ := set $sso "allowedRedirectUris" . }}{{ end -}}
{{- $_ := set $tv "sso" $sso -}}
{{- $_ := set $tv "env" .Values.parent.env -}}
{{- $_ := set $tv "vaultServer" .Values.parent.vaultServer -}}
{{- $_ := set $tv "eso" (include "mto-extension-vault-community-bootstrap.esoMode" .) -}}
{{- $_ := set $tv "externalSecretRefreshInterval" .Values.parent.externalSecretRefreshInterval -}}
{{- $_ := set $tv "configNamespace" .Values.configNamespace -}}
{{- $_ := set $tv "vco" .Values.vco -}}
{{- $_ := set $tv "kubernetesAuth" .Values.kubernetesAuth -}}
{{- $_ := set $tv "tenantLabelKey" .Values.parent.tenantLabelKey -}}
{{- $_ := set $tv "sharedTenant" (dict "name" .Values.parent.sharedTenantName) -}}
{{- /* Built key-by-key and set only when one is given: an empty token map would
       wipe the tenant chart's own defaults. A given 0 is kept: it means
       "Vault's default" to the tenant chart, and `if $v` dropped it, so the
       tenant chart's 3600 applied instead. period is not plumbed on purpose. */ -}}
{{- $ptok := dict -}}
{{- $src := ((.Values.parent | default dict).token | default dict) -}}
{{- range $k := (list "type" "ttl" "maxTTL") -}}
{{- if and (hasKey $src $k) (not (kindIs "invalid" (get $src $k))) -}}
{{- $_ := set $ptok $k (get $src $k) -}}
{{- end -}}
{{- end -}}
{{- with $ptok }}{{ $_ := set $tv "token" . }}{{ end -}}
{{- $out := toYaml $tv -}}
{{- if contains "{{" $out -}}
{{- fail "a tenant value contains \"{{\": t-op-v2 renders the child valuesTemplate as a Go template and would execute it. Remove it from tenantValues (or the value it came from)" -}}
{{- end -}}
{{- $out -}}
{{- end -}}

{{/*
"true" when an optional tenant-chart feature is switched on install-wide in
tenantValues. Used to gate the RBAC `create` that feature needs.
Usage: {{ include "mto-extension-vault-community-bootstrap.tenantFeature" (dict "ctx" . "feature" "monitoring") }}
*/}}
{{- define "mto-extension-vault-community-bootstrap.tenantFeature" -}}
{{- $f := get (.ctx.Values.tenantValues | default dict) .feature | default dict -}}
{{- $v := ternary (get $f "enabled") nil (hasKey $f "enabled") -}}
{{- include "mto-extension-vault-community-bootstrap.boolValue" (dict "name" (printf "tenantValues.%s.enabled" .feature) "value" $v) -}}
{{- end -}}

{{/*
Tenant names the parent skips, comma-separated, because the name is the first
segment of a path Vault or the platform already uses. A tenant's KV mount is
<tenant>/kv and its auth mounts are auth/<tenant>/..., and Vault refuses a mount
nested under another mount, in the secrets table and in the auth table alike.
  - sys, auth, identity, cubbyhole: Vault's own paths;
  - agent-registry: Vault 2.1.1 mounts it by itself;
  - token: the token auth method, always at auth/token;
  - the first segment of vco.authPath: VCO's own login mount (auth/kubernetes);
  - the shared name: the prefix of the shared mount shared/kv;
  - parent.reservedPaths: the platform's own mount prefixes, which the parent
    cannot read from Vault.
*/}}
{{- define "mto-extension-vault-community-bootstrap.reservedNames" -}}
{{- $names := list "sys" "auth" "identity" "cubbyhole" "agent-registry" "token" -}}
{{- $names = append $names (first (splitList "/" (trimAll "/" (required "vco.authPath must be set" .Values.vco.authPath)))) -}}
{{- $names = append $names (required "parent.sharedTenantName must be set" .Values.parent.sharedTenantName) -}}
{{- range $p := (.Values.parent.reservedPaths | default list) -}}
{{- $s := toString $p -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $s) -}}
{{- fail (printf "parent.reservedPaths entry %q is not a DNS label; list the first segment of the mount path only (secret, not secret/)" $s) -}}
{{- end -}}
{{- $names = append $names $s -}}
{{- end -}}
{{- join "," (uniq $names) -}}
{{- end -}}

{{/*
The tenant chart's default SSO roles: its sso.roles and its roleCaps keys
(values.yaml), which tenantValues.sso.roles and tenantValues.roleCaps extend.
Pinned to the tenant chart by the render test tenantvaluekeys.
*/}}
{{- define "mto-extension-vault-community-bootstrap.defaultRoles" -}}
{{- toYaml (list "admin" "editor" "viewer" "audit-read") -}}
{{- end -}}

{{/*
The tenant chart's default workload token ttl and maxTTL (values.yaml
token.*), which a parent.token that sets one side only keeps for the other.
Pinned to the tenant chart by the render test tenantvaluekeys.
*/}}
{{- define "mto-extension-vault-community-bootstrap.defaultToken" -}}
{{- toYaml (dict "ttl" 3600 "maxTTL" 14400) -}}
{{- end -}}

{{/*
The SSO roles and the group pattern of each, resolved as the tenant chart's
07-sso-policies.yaml and vault.ssoGroup resolve them, and validated once at
install: in the tenant chart a bad value fails every tenant's render while
this install reports success, and the admission policies embed the patterns
in CEL.
  - every role is a DNS label (a part of sso.<tenant>.<role>), listed once,
    not "fallback" (the name of Enterprise's role without a group binding),
    with a roleCaps entry;
  - every roleCaps value is one capability list, ["a", "b"], without sudo;
  - every tenantRoleMapping entry is {} (the default pattern) or
    {pattern: <pattern>}, for a listed role; its "fallback" is "deny";
  - a tenantGroupTemplate that is set is not empty;
  - every pattern holds {tenant} exactly once — without it one group gets the
    role in EVERY tenant (platform-admins as admin of all), which is not a
    tenant's SSO; a platform team uses a Vault admin policy instead — no
    quote, double quote or backslash, which the CEL can't embed, and no
    control character, which the policies' YAML folds to a space;
  - (tenant, role) -> group is one to one: no two roles' patterns give two
    tenants, or one tenant's two roles, the same group (ssoCollision).
Returns a YAML list of {role, pattern}.
*/}}
{{- define "mto-extension-vault-community-bootstrap.ssoPatterns" -}}
{{- $tv := .Values.tenantValues | default dict -}}
{{- $tsso := $tv.sso | default dict -}}
{{- $defaultRoles := include "mto-extension-vault-community-bootstrap.defaultRoles" . | fromYamlArray -}}
{{- $roles := $tsso.roles | default $defaultRoles -}}
{{- if not (kindIs "slice" $roles) -}}
{{- fail (printf "tenantValues.sso.roles must be a list of role names — got %v" $roles) -}}
{{- end -}}
{{- $roleCaps := $tv.roleCaps | default dict -}}
{{- $capRoles := concat $defaultRoles (keys $roleCaps) -}}
{{- range $r, $c := $roleCaps -}}
{{- $cs := toString $c -}}
{{- if not (regexMatch "^\\[\"[a-z]+\"(, \"[a-z]+\")*\\]$" $cs) -}}
{{- fail (printf "tenantValues.roleCaps.%s %q is not one capability list such as [\"read\", \"list\"]: every policy line is built from it, and the scope check refuses any other shape" $r $cs) -}}
{{- end -}}
{{- if contains "\"sudo\"" $cs -}}
{{- fail (printf "tenantValues.roleCaps.%s grants sudo, which no tenant policy may hold" $r) -}}
{{- end -}}
{{- end -}}
{{- $mapping := $tsso.tenantRoleMapping | default dict -}}
{{- range $k, $e := $mapping -}}
{{- if eq $k "fallback" -}}
{{- if ne (toString $e) "deny" -}}
{{- fail (printf "tenantValues.sso.tenantRoleMapping.fallback=%q: a fallback role binds no group, so any valid token of the IdP would get a tenant's access. It must be \"deny\"" (toString $e)) -}}
{{- end -}}
{{- else if or (not (kindIs "map" $e)) (not (eq (len (without (keys $e) "pattern")) 0)) (and (hasKey $e "pattern") (not $e.pattern)) -}}
{{- fail (printf "tenantValues.sso.tenantRoleMapping.%s must be {} (the default pattern) or {pattern: \"<pattern>\"} — got %v; anything else binds the default group without a word" $k $e) -}}
{{- else if not (has $k $roles) -}}
{{- fail (printf "tenantValues.sso.tenantRoleMapping.%s maps a role that is not in sso.roles (%s)" $k (join ", " $roles)) -}}
{{- end -}}
{{- end -}}
{{- if and (hasKey $tsso "tenantGroupTemplate") (not $tsso.tenantGroupTemplate) -}}
{{- fail "tenantValues.sso.tenantGroupTemplate is set but empty: the tenant chart then has no pattern for a role. Remove it to use {tenant}-{role}s" -}}
{{- end -}}
{{- $default := toString ($tsso.tenantGroupTemplate | default "{tenant}-{role}s") -}}
{{- $out := list -}}
{{- $seen := dict -}}
{{- range $r := $roles -}}
{{- $role := toString $r -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $role) -}}
{{- fail (printf "tenantValues.sso.roles entry %q is not a DNS label: it is a part of the Vault role name sso.<tenant>.<role>" $role) -}}
{{- end -}}
{{- if eq $role "fallback" -}}
{{- fail "tenantValues.sso.roles entry \"fallback\" is reserved: it is the name of Enterprise's role without a group binding, which this extension refuses" -}}
{{- end -}}
{{- if hasKey $seen $role -}}
{{- fail (printf "tenantValues.sso.roles lists %q twice" $role) -}}
{{- end -}}
{{- $_ := set $seen $role true -}}
{{- if not (has $role $capRoles) -}}
{{- fail (printf "tenantValues.sso.roles includes %q, which has no roleCaps entry (the tenant chart's roles: %s; add tenantValues.roleCaps.%s)" $role (join ", " $defaultRoles) $role) -}}
{{- end -}}
{{- $e := get $mapping $role -}}
{{- $p := $default -}}
{{- $from := "tenantValues.sso.tenantGroupTemplate" -}}
{{- if and (kindIs "map" $e) (get $e "pattern") -}}
{{- $p = toString (get $e "pattern") -}}
{{- $from = printf "tenantValues.sso.tenantRoleMapping.%s.pattern" $role -}}
{{- end -}}
{{- if ne (len (splitList "{tenant}" $p)) 2 -}}
{{- fail (printf "%s %q must contain {tenant} exactly once: without it one group gets role %s in every tenant. Give platform-wide access with a Vault admin policy, not a tenant's SSO role" $from $p $role) -}}
{{- end -}}
{{- if or (contains "'" $p) (contains "\"" $p) (contains "\\" $p) -}}
{{- fail (printf "%s %q contains a quote, a double quote or a backslash, which the admission policies cannot embed" $from $p) -}}
{{- end -}}
{{- if regexMatch "[[:cntrl:]]" $p -}}
{{- fail (printf "%s %q holds a control character (a newline or a tab): in the admission policies' YAML a line break becomes a space, so the CEL would expect another group than the tenant chart binds, and refuse every tenant's SSO roles" $from $p) -}}
{{- end -}}
{{- $out = append $out (dict "role" $role "pattern" $p) -}}
{{- end -}}
{{- /* Two different roles: a role listed twice is the guard above's. */ -}}
{{- range $i, $a := $out -}}
{{- range $j, $b := $out -}}
{{- if and (lt $i $j) (ne $a.role $b.role) -}}
{{- $hit := include "mto-extension-vault-community-bootstrap.ssoCollision" (dict "a" $a "b" $b) -}}
{{- if hasPrefix "same:" $hit -}}
{{- fail (printf "the SSO group patterns of roles %s (%q) and %s (%q) give one tenant the same group for both roles, for example %s: its members get both. Give each role its own group" $a.role $a.pattern $b.role $b.pattern (trimPrefix "same:" $hit)) -}}
{{- else if $hit -}}
{{- fail (printf "the SSO group patterns of roles %s (%q) and %s (%q) can give two tenants the same group, for example %s. Put a character a tenant name cannot hold (such as _ or .) between {tenant} and the rest, or change the role names" $a.role $a.pattern $b.role $b.pattern (trimPrefix "cross:" $hit)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Whether two roles' group patterns can give the same group: to two different
tenants ("cross:<example>"), or to one tenant for both roles
("same:<example>"); "" when never. Each pattern, its role filled in, is
P {tenant} S, and a tenant name is a DNS label. With P1 the shorter prefix
(P2 = P1 D) the groups can only meet when one suffix ends the other:
  S2 = E S1  ->  t1 = D t2 E     same pattern when D = E = "" (every tenant's
                                 two roles share a group); otherwise a
                                 collision when D can start and E can end a
                                 DNS label
  S1 = E S2  ->  t1 E = D t2     t1 = D y, t2 = y E as above; or overlapping,
                                 D = t1 O and E = O t2 (t1 = t2: one tenant)
Each result has its own condition, so each is a guard of its own, and each
has a bad input in the render test ssogroups that only it refuses.
*/}}
{{- define "mto-extension-vault-community-bootstrap.ssoCollision" -}}
{{- $ga := splitList "{tenant}" (replace "{role}" .a.role .a.pattern) -}}
{{- $gb := splitList "{tenant}" (replace "{role}" .b.role .b.pattern) -}}
{{- $p1 := index $ga 0 }}{{ $s1 := index $ga 1 }}{{ $p2 := index $gb 0 }}{{ $s2 := index $gb 1 -}}
{{- if lt (len $p2) (len $p1) -}}
{{- $p1 = index $gb 0 }}{{ $s1 = index $gb 1 }}{{ $p2 = index $ga 0 }}{{ $s2 = index $ga 1 -}}
{{- end -}}
{{- $head := "^([a-z0-9][-a-z0-9]*)?$" -}}
{{- $tail := "^([-a-z0-9]*[a-z0-9])?$" -}}
{{- $label := "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" -}}
{{- if hasPrefix $p1 $p2 -}}
{{- $d := trimPrefix $p1 $p2 -}}
{{- if hasSuffix $s1 $s2 -}}
{{- $e := trimSuffix $s1 $s2 -}}
{{- if and (not $d) (not $e) -}}
{{- printf "same:%sx%s" $p1 $s1 -}}
{{- end -}}
{{- if and (or $d $e) (regexMatch $head $d) (regexMatch $tail $e) -}}
{{- printf "cross:%s%sx%s%s" $p1 $d $e $s1 -}}
{{- end -}}
{{- else if hasSuffix $s2 $s1 -}}
{{- $e := trimSuffix $s2 $s1 -}}
{{- if and (regexMatch $head $d) (regexMatch $tail $e) -}}
{{- printf "cross:%s%sx%s%s" $p1 $d $e $s2 -}}
{{- else -}}
{{- $found := "" -}}
{{- range $k := until (min (len $d) (len $e) | int) -}}
{{- $n := add1 $k | int -}}
{{- $o := substr (sub (len $d) $n | int) (len $d) $d -}}
{{- $t1 := substr 0 (sub (len $d) $n | int) $d -}}
{{- $t2 := substr $n (len $e) $e -}}
{{- $meet := and (not $found) (hasPrefix $o $e) (regexMatch $label $t1) (regexMatch $label $t2) -}}
{{- if and $meet (eq $t1 $t2) -}}
{{- $found = printf "same:%s%s%s%s" $p1 $d $t2 $s2 -}}
{{- end -}}
{{- if and $meet (ne $t1 $t2) -}}
{{- $found = printf "cross:%s%s%s%s" $p1 $d $t2 $s2 -}}
{{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The install-wide values that reach the admission policies' CEL or every
tenant's render, validated at install whether or not admission is on: a value
that is not a name either breaks the CEL (every VCO write refused), makes a
check match nothing while the install reports success, or fails every
tenant's render later. Each entry has a bad input in the render test
installvalues.
*/}}
{{- define "mto-extension-vault-community-bootstrap.installChecks" -}}
{{- $label := "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" -}}
{{- $sub := "^[a-z0-9]([-a-z0-9]*[a-z0-9])?([.][a-z0-9]([-a-z0-9]*[a-z0-9])?)*$" -}}
{{- $mountPath := "^[a-z0-9_][-a-z0-9_]*(/[a-z0-9_][-a-z0-9_]*)*$" -}}
{{- $to := .Values.templateOperator | default dict -}}
{{- $tsso := (.Values.tenantValues | default dict).sso | default dict -}}
{{- $ssoMount := $tsso.mount | default dict -}}
{{- $checks := list
      (list "configNamespace" .Values.configNamespace $label)
      (list "templateOperator.namespace" $to.namespace $label)
      (list "templateOperator.serviceAccountName" $to.serviceAccountName $sub)
      (list "vco.serviceAccount" .Values.vco.serviceAccount $sub)
      (list "vco.authPath" (trimAll "/" (toString .Values.vco.authPath)) $mountPath)
      (list "parent.env" .Values.parent.env $label)
      (list "parent.sharedTenantName" .Values.parent.sharedTenantName $label)
      (list "parent.tenantLabelKey" .Values.parent.tenantLabelKey "^([a-z0-9]([-a-z0-9]*[a-z0-9])?([.][a-z0-9]([-a-z0-9]*[a-z0-9])?)*/)?[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$")
      (list "kubernetesAuth.path" (trimAll "/" (toString .Values.kubernetesAuth.path)) $mountPath)
      (list "kubernetesAuth.name" (trimAll "/" (toString .Values.kubernetesAuth.name)) $mountPath) -}}
{{- range $k := list "path" "name" -}}
{{- if hasKey $ssoMount $k -}}
{{- $checks = append $checks (list (printf "tenantValues.sso.mount.%s" $k) (trimAll "/" (toString (get $ssoMount $k))) $mountPath) -}}
{{- end -}}
{{- end -}}
{{- range $c := $checks -}}
{{- $v := toString (index $c 1 | default "") -}}
{{- if not (regexMatch (index $c 2) $v) -}}
{{- fail (printf "%s %q is not a valid name (%s): the admission policies match on it, and a wrong or empty value makes a check match nothing or fails every tenant" (index $c 0) $v (index $c 2)) -}}
{{- end -}}
{{- end -}}
{{- if or (contains "'" (toString .Values.vco.role)) (contains "\\" (toString .Values.vco.role)) (not .Values.vco.role) -}}
{{- fail (printf "vco.role %q must be set and hold no quote or backslash: the admission policies embed it" (toString .Values.vco.role)) -}}
{{- end -}}
{{- /* The shared name is the prefix of shared/kv and goes into the scope
       check's regexes; as a reserved name (sys, auth, a platform mount) it
       would point the share paths there, and the admission policies take it
       off their reserved list. */ -}}
{{- $shared := toString .Values.parent.sharedTenantName -}}
{{- $others := without (splitList "," (include "mto-extension-vault-community-bootstrap.reservedNames" .)) $shared -}}
{{- $builtin := list "sys" "auth" "identity" "cubbyhole" "agent-registry" "token" (first (splitList "/" (trimAll "/" (toString .Values.vco.authPath)))) -}}
{{- if or (has $shared $builtin) (has $shared (.Values.parent.reservedPaths | default list)) -}}
{{- fail (printf "parent.sharedTenantName %q is a reserved name (%s): the shared mount would sit under a path Vault or the platform already uses" $shared (join ", " $others)) -}}
{{- end -}}
{{- /* The tenant chart refuses ttl over maxTTL, so a side that is not set
       is the tenant chart's default; 0 is Vault's default and is not
       compared. */ -}}
{{- $tok := (.Values.parent | default dict).token | default dict -}}
{{- $eff := include "mto-extension-vault-community-bootstrap.defaultToken" . | fromYaml -}}
{{- range $k := list "ttl" "maxTTL" -}}
{{- if and (hasKey $tok $k) (not (kindIs "invalid" (get $tok $k))) -}}
{{- $_ := set $eff $k (get $tok $k) -}}
{{- end -}}
{{- end -}}
{{- if and $eff.ttl $eff.maxTTL (gt (int64 $eff.ttl) (int64 $eff.maxTTL)) -}}
{{- fail (printf "parent.token.ttl %v is over parent.token.maxTTL %v (a side not set is the tenant chart's default, ttl 3600 and maxTTL 14400): Vault caps a token at maxTTL, and the tenant chart refuses it, so every tenant's render would fail" $eff.ttl $eff.maxTTL) -}}
{{- end -}}
{{- /* Vault puts one auth mount on a path and refuses one inside another,
       so the Kubernetes and SSO mounts of a tenant are two paths, neither
       under the other; otherwise every tenant loses one of its logins. */ -}}
{{- $k8s := printf "%s/%s" (trimAll "/" (toString .Values.kubernetesAuth.path)) (trimAll "/" (toString .Values.kubernetesAuth.name)) -}}
{{- $sso := printf "%s/%s" (trimAll "/" (toString ($ssoMount.path | default "oidc"))) (trimAll "/" (toString ($ssoMount.name | default "sso"))) -}}
{{- if or (eq $k8s $sso) (hasPrefix (printf "%s/" $k8s) $sso) (hasPrefix (printf "%s/" $sso) $k8s) -}}
{{- fail (printf "kubernetesAuth (auth/<tenant>/%s) and tenantValues.sso.mount (auth/<tenant>/%s) are one path, or one is inside the other: Vault mounts one of them only, and every tenant loses that login. Give each its own path" $k8s $sso) -}}
{{- end -}}
{{- $_ := include "mto-extension-vault-community-bootstrap.ssoPatterns" . -}}
{{- end -}}
