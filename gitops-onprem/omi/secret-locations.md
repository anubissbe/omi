# Waar de secrets van de omi-onprem stack leven (alleen locaties, nooit waarden)

## 1Password (vault `Private`)
- `euraika gitlab token` — GitLab PAT (push + API), nodig om branches te pushen naar git.euraika.net en pipelines te triggeren (project 217). Let op: `op read` faalt soms met "authorization timeout" — retry, of lees de waarde in de 1Password-app.
- `Vault admin token - onprem` — admin token voor de onprem Vault (port-forward svc/vault, VAULT_ADDR), o.a. voor vault-bootstrap.sh (kv v2 `kv/`, kubernetes auth role `argocd-repos`)
- `mistral__api` in de globale `~/.env` — Mistral API key; in het cluster als `omi/omi-secrets` key `OPENAI_API_KEY` met `OPENAI_BASE_URL=https://api.mistral.ai/v1` (llm_gateway leest die twee)

## Kubernetes cluster (context `onprem`)
- `argocd/repo-omi` — Argo CD deploy-token (read) voor euraika/omi; bron voor Vault is `kv/platform/argocd-onprem-omi` (ESO ExternalSecret repo-omi, policy in `gitops/onprem/platform/vault-policies/argocd-repos.hcl`)
- `omi/omi-secrets` — runtime secrets: OPENAI_API_KEY (Mistral), OPENAI_BASE_URL, ENCRYPTION_SECRET, ADMIN_KEY, REDIS_DB_PASSWORD, TYPESENSE_API_KEY
- `omi/omi-data` — datalaag: REDIS_PASSWORD, TYPESENSE_API_KEY, QDRANT_API_KEY
- `omi/omi-db-app` — CNPG app-secret (automatisch gegenereerd) met `uri` = JOBSTORE_PG_DSN (Postgres jobstore)
- `omi/gitlab-registry` — pull-secret voor git.euraika.net:5050 (gereguleerd door token-rotator)
- `omi/omi-letsencrypt-account` — ACME account key voor cert-manager

## Regels
- Nooit waarden in git, logs of chat dumpen; alleen key-namen.
- Rotatie: waarde in het Secret vervangen + `kubectl -n omi rollout restart deploy/...` (zie secrets.md).
- Tijdelijke PAT's (bv. voor een git push) nooit naar een bestand dat git kan zien; gebruik een `mktemp`-bestand met `umask 077` en `rm` direct na gebruik.
