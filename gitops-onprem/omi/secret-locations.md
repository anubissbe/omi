# Waar de secrets van de omi-onprem stack leven (alleen locaties, nooit waarden)

## 1Password (vault `Private`)
- `euraika gitlab token` — GitLab PAT (push + API), nodig om `desktop/merge-upstream` te pushen naar git.euraika.net
- `Vault admin token - onprem` — admin token voor de onprem Vault (port-forward svc/vault, VAULT_ADDR), o.a. voor vault-bootstrap.sh

## Kubernetes cluster (context `onprem`)
- `argocd/repo-omi` — Argo CD deploy-token (read) voor euraika/omi; bron voor Vault is `kv/platform/argocd-onprem-omi` (ESO ExternalSecret repo-omi)
- `omi/omi-secrets` — runtime secrets: OPENAI_API_KEY (Mistral), OPENAI_BASE_URL, ENCRYPTION_SECRET, ADMIN_KEY, REDIS_DB_PASSWORD, TYPESENSE_API_KEY
- `omi/omi-data` — datalaag: REDIS_PASSWORD, TYPESENSE_API_KEY, QDRANT_API_KEY
- `omi/omi-db-app` — CNPG app-secret met `uri` = JOBSTORE_PG_DSN (Postgres jobstore)
- `omi/gitlab-registry` — pull-secret voor git.euraika.net:5050 (gereguleerd door token-rotator)
- `omi/omi-letsencrypt-account` — ACME account key voor cert-manager

## Regels
- Nooit waarden in git, logs of chat dumpen; alleen key-namen.
- Rotatie: waarde in het Secret vervangen + `kubectl -n omi rollout restart deploy/...` (zie secrets.md).
