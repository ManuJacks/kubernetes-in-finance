# Production-debug database diagnostic access
path "secret/data/production-debug/database/*" {
  capabilities = ["read"]
}

path "secret/metadata/production-debug/database" {
  capabilities = ["list"]
}

path "secret/metadata/production-debug/database/*" {
  capabilities = ["read", "list"]
}
