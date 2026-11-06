# The lab's Dex config (make lab-dex), as the Secret dex-config. The config is
# JSON, a subset of YAML, which Dex reads. Both client secrets come in as the
# Secrets themselves ($kc, $vc) and are decoded here: none passes through the
# shell or a log.
#
# A file, not a quoted program in the Makefile: GNU make 4 keeps a
# backslash-newline inside single quotes, so a quoted program split over lines
# reaches jq with a backslash in it (DX.4).
#
# Inputs (jq --arg/--argjson): kc, vc, issuer, kcurl, cli, ui, tenants, ns.
{apiVersion: "v1", kind: "Secret", type: "Opaque", metadata: {name: "dex-config", namespace: $ns},
  stringData: {"config.yaml": ({issuer: $issuer, storage: {type: "memory"}, web: {http: "0.0.0.0:5556"},
    oauth2: {skipApprovalScreen: true},
    connectors: [{type: "oidc", id: "keycloak", name: "Keycloak", config: {issuer: ($kcurl + "/realms/mto"),
      clientID: "dex", clientSecret: ($kc.data["client-secret"] | @base64d), redirectURI: ($issuer + "/callback"),
      scopes: ["openid", "profile", "email"], insecureEnableGroups: true}}],
    staticClients: [{id: "vault", name: "Vault", secret: ($vc.data["client-secret"] | @base64d),
      redirectURIs: ([$cli] + ($tenants | split(" ") | map(select(. != "")) | map(. as $t | $ui | sub("\\{tenant\\}"; $t))))}]} | tojson)}}
