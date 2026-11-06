# VCO's login policy (design §6, ADR-0006), as C.0 verified it. Community
# Edition has one namespace, so every path is a full path from root: the
# Enterprise production policy (charts/examples/vco-admin-policy.hcl there)
# with each tenant namespace "+/" turned into the tenant prefix, as follows.
#
#   Enterprise, inside namespace <t>/   Community, in root
#   kv/                                 <t>/kv/
#   auth/kubernetes/workloads/          auth/<t>/kubernetes/workloads/
#   auth/oidc/sso/                      auth/<t>/oidc/sso/
#   (the shared namespace)              shared/kv/, auth/shared/kubernetes/workloads/
#
# Bounded by name AND by mount type: allowed_parameters pins the type of every
# mount VCO may create (question 14). Deletes follow the data, as on
# Enterprise: none on a kv mount; allowed on policies, roles and auth mounts,
# which hold grants, and disabling a tenant's auth mount revokes its tokens
# (question 17).
#
# This policy alone does not bound what VCO can grant: a kv.* policy can say
# anything (question 16). The admission policies in q18-admission.yaml check
# the content of every VCO CR in vault-config before VCO sees it.

# The kv mount of each tenant, and shared/kv.
path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/mounts/+/kv" {
  capabilities = ["create", "read", "update"]
  allowed_parameters = {
    "type" = ["kv"]
    "*"    = []
  }
}
path "sys/mounts/+/kv/tune" {
  capabilities = ["create", "read", "update"]
}

# The auth mounts of each tenant, and the shared one for share roles. Enabling
# and tuning an auth method needs sudo. The auth table is also read by the
# Policy kind, to resolve accessor placeholders.
path "sys/auth" {
  capabilities = ["read"]
}
path "sys/auth/+/kubernetes/workloads" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
  allowed_parameters = {
    "type" = ["kubernetes"]
    "*"    = []
  }
}
path "sys/auth/+/kubernetes/workloads/tune" {
  capabilities = ["create", "read", "update", "sudo"]
}
path "sys/auth/+/oidc/sso" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
  allowed_parameters = {
    "type" = ["oidc"]
    "*"    = []
  }
}
path "sys/auth/+/oidc/sso/tune" {
  capabilities = ["create", "read", "update", "sudo"]
}

# Their configuration and roles, each role family on its own mounts only.
path "auth/+/kubernetes/workloads/config" {
  capabilities = ["create", "read", "update"]
}
path "auth/+/kubernetes/workloads/role/kv.*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "auth/shared/kubernetes/workloads/role/share.*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "auth/+/oidc/sso/config" {
  capabilities = ["create", "read", "update"]
}
path "auth/+/oidc/sso/role/sso.*" {
  capabilities = ["create", "read", "update", "delete"]
}

# The policies the charts render, by name family. VCO's own policy, default,
# and every platform policy are outside them.
path "sys/policy/kv.*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "sys/policy/share.*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "sys/policy/sso.*" {
  capabilities = ["create", "read", "update", "delete"]
}
