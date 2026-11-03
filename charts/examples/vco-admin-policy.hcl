# VCO's login policy for production (docs/design.md §6, ADR-0008). Write it
# once, as a Vault admin, with the role that binds VCO's ServiceAccount
# (charts/README.md → "Vault bootstrap").
#
# Vault Community has one namespace, so every path is a full path from root:
# the Enterprise production policy with each tenant namespace "+/" turned into
# the tenant prefix.
#
#   Enterprise, inside namespace <t>/   Community, in root
#   kv/                                 <t>/kv/
#   auth/kubernetes/workloads/          auth/<t>/kubernetes/workloads/ (share roles too, ADR-0007)
#   auth/oidc/sso/                      auth/<t>/oidc/sso/
#   (the shared namespace) kv/          shared/kv/
#
# Bounded by NAME and by MOUNT TYPE:
#   - policies only under sys/policy/kv.*, share.*, sso.*: VCO can't write its
#     own policy (vco-admin), default, or any platform policy;
#   - roles only under those prefixes, on the extension's mounts, never on
#     auth/kubernetes, where VCO's own login role lives;
#   - kv mounts create, read, update — never delete (ADR-0005);
#   - auth mounts with delete: they hold grants, not data, and disabling a
#     tenant's mount revokes every token issued through it;
#   - allowed_parameters pins every mount's type (P5): VCO can't mount another
#     engine or auth method in the extension's places.
#
# This policy does NOT bound what VCO can grant: a kv.* policy can say
# anything, so VCO's token is root-equivalent (P6). The bootstrap chart's
# admission policies check what VCO is asked, for every writer of the config
# namespace. Keep them on, and keep VCO's token and pod as root secrets.
#
# hack/lab/vco-admin-policy.hcl is this policy plus delete on the kv mounts, for
# the lab's teardown; the render tests check that it is the only difference.

path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/mounts/+/kv" {
  # No delete: deleting a tenant keeps its data (ADR-0005). The CR stays
  # Terminating until a Vault admin purges the mount (charts/README.md → Deletion).
  capabilities = ["create", "read", "update"]
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
