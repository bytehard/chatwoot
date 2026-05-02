# Chatwoot on Railway for MABE

This document is the operational reference for the MABE Chatwoot production deployment.

## Production targets

- App URL: `https://chats.mabeimpact.com`
- Railway project: `chatwoot-mabe`
- GitHub fork: `bytehard/chatwoot`
- Deploy branch: `mabe-production`

## Service topology

- `web`
  - Runs Rails web server
  - Config file: `/railway.web.toml`
- `worker`
  - Runs Sidekiq
  - Config file: `/railway.worker.toml`
- `Postgres`
  - Railway managed PostgreSQL
- `Redis`
  - Railway managed Redis
- `R2`
  - Cloudflare R2 for Active Storage

## Why we do not use `/railway.toml`

`web` and `worker` need different `startCommand` values. A single root `/railway.toml` caused drift and forced manual command swapping.

To keep autodeploy clean:

- `web` must point to `/railway.web.toml`
- `worker` must point to `/railway.worker.toml`

## Current runtime behavior

### Web

- Pre-deploy:
  - `POSTGRES_STATEMENT_TIMEOUT=600s bundle exec rails db:chatwoot_prepare`
- Start:
  - `bundle exec rails ip_lookup:setup && bin/rails server -p $PORT -e $RAILS_ENV`
- Healthcheck:
  - `/health`

### Worker

- Pre-deploy:
  - `POSTGRES_STATEMENT_TIMEOUT=600s bundle exec rails db:chatwoot_prepare`
- Start:
  - `bundle exec rails ip_lookup:setup && bundle exec sidekiq -C config/sidekiq.yml`

## Storage

Active Storage uses Cloudflare R2 through the `s3_compatible` adapter.

Required variables on `web` and `worker`:

- `ACTIVE_STORAGE_SERVICE=s3_compatible`
- `STORAGE_BUCKET_NAME`
- `STORAGE_ACCESS_KEY_ID`
- `STORAGE_SECRET_ACCESS_KEY`
- `STORAGE_REGION=auto`
- `STORAGE_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com`
- `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`
- `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`

The checksum variables are required for inbound WhatsApp media uploads to R2.

## SSL

Production runs behind Railway and Cloudflare.

Required variables on `web`:

- `ASSUME_SSL=true`
- `FORCE_SSL=true`

Rails support for this lives in `config/environments/production.rb`:

- `config.assume_ssl = ... ENV.fetch('ASSUME_SSL', false)`
- `config.force_ssl = ... ENV.fetch('FORCE_SSL', false)`

Expected production checks:

- `https://chats.mabeimpact.com/health` returns `200`
- `http://chats.mabeimpact.com/health` redirects with `301`
- Session cookie is marked `secure`

## Safe update flow from upstream

Use this flow whenever you want new Chatwoot updates without losing the MABE deploy setup:

1. Fetch upstream changes.
2. Rebase or merge `upstream/develop` into `mabe-production`.
3. Review conflicts in:
   - `Dockerfile`
   - `config/environments/production.rb`
   - `railway.web.toml`
   - `railway.worker.toml`
4. Push `mabe-production` to `origin`.
5. Let Railway autodeploy `web` and `worker`.
6. Validate:
   - `/health`
   - login
   - WhatsApp inbound/outbound
   - media upload to R2

## Local git remote layout

Recommended remotes for this clone:

- `origin` -> `https://github.com/bytehard/chatwoot.git`
- `upstream` -> `https://github.com/chatwoot/chatwoot.git`

## Post-deploy smoke checks

After important changes, verify:

1. `https://chats.mabeimpact.com/health`
2. Chatwoot login works
3. WhatsApp text send/receive works
4. WhatsApp media inbound works
5. Upload from Chatwoot UI works
6. R2 objects are being created

## Notes

- Avoid manual `railway up` deploys from arbitrary local states once GitHub autodeploy is established.
- Prefer pushing controlled commits to `mabe-production`.
- If Railway UI fields are read-only, confirm the service is pointing to the intended config-as-code file and not back to `/railway.toml`.
