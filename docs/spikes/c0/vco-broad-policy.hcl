# A broad VCO login policy for the spike only: question 1 needs to see what
# VCO does on a mount delete when Vault allows it. Never use this outside a
# lab. The production policy is vco-admin-policy.hcl.
path "sys/mounts"   { capabilities = ["read", "list"] }
path "sys/mounts/*" { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/auth"     { capabilities = ["read", "list"] }
path "sys/auth/*"   { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "auth/*"       { capabilities = ["create", "read", "update", "delete", "list"] }
path "sys/policy/*" { capabilities = ["create", "read", "update", "delete", "list"] }
