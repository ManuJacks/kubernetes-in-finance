# Production-debug application secrets: read only
path "secret/data/production-debug/application/*" {
  capabilities = ["read"]
}

path "secret/metadata/production-debug/application" {
  capabilities = ["list"]
}

path "secret/metadata/production-debug/application/*" {
  capabilities = ["read", "list"]
}
