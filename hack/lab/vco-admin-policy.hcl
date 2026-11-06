# VCO's login policy in the LAB. It is the production policy
# (charts/examples/vco-admin-policy.hcl, design §6, ADR-0008) plus ONE grant:
# delete on the kv mounts, so the e2e teardown can remove the tenants' data.
# Production denies it: deleting a tenant keeps its data (ADR-0005). The e2e
# suite's offboarding step swaps in the production policy to prove that.
# Its paths are the default mounts, as in production; make admission-offline
# checks that both cover every path VCO writes (C.23).
#
# Vault Community has one namespace, so every path is a full path from root:
# <tenant>/kv, shared/kv, auth/<tenant>/kubernetes/workloads,
# auth/<tenant>/oidc/sso. Bounded by name and by mount type.

path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/mounts/+/kv" {
  # Lab only: "delete", for the teardown.
  capabilities = ["create", "read", "update", "delete"]
  allowed_parameters = {
    "type" = ["kv"]
    "*"    = []
  }
}
path "sys/mounts/+/kv/tune" {
  capabilities = ["create", "read", "update"]
}

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

path "auth/+/kubernetes/workloads/config" {
  capabilities = ["create", "read", "update"]
}
path "auth/+/kubernetes/workloads/role/kv.*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "auth/+/kubernetes/workloads/role/share.*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "auth/+/oidc/sso/config" {
  capabilities = ["create", "read", "update"]
}
path "auth/+/oidc/sso/role/sso.*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "sys/policy/kv.*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "sys/policy/share.*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "sys/policy/sso.*" {
  capabilities = ["create", "read", "update", "delete"]
}
