# Deploying Chatwoot to Railway with separate web and worker services, Cloudflare R2, and Cloudflare SSL

This document is the operational reference for the MABE Chatwoot production deployment.

It is also intentionally written as a searchable implementation note for anyone trying to run Chatwoot on Railway with:

- separate `web` and `worker` services
- a Dockerfile-based deploy
- Cloudflare R2 for Active Storage
- Cloudflare in front of Railway
- Rails `FORCE_SSL` enabled behind a proxy

## What broke in the naive Railway setup

These were the main issues we hit when using the "obvious" Railway setup:

1. A single root `/railway.toml` was not enough.
   - `web` and `worker` need different `startCommand` values.
   - Using one shared file caused drift and forced manual command swapping.

2. Inbound WhatsApp media failed even though outbound uploads worked.
   - Chatwoot UI uploads could succeed while inbound WhatsApp attachments still failed in Sidekiq.
   - The worker raised:
     - `Aws::S3::Errors::InvalidRequest`
     - `You can only specify one non-default checksum at a time.`

3. `FORCE_SSL=true` is not enough by itself behind Railway + Cloudflare.
   - Railway and Cloudflare terminate TLS upstream.
   - Rails may still think the request is plain HTTP unless `assume_ssl` is enabled.

## What solved it

The validated fix set was:

1. Split Railway config by service:
   - `/railway.web.toml`
   - `/railway.worker.toml`

2. Run both services from the same fork/branch, but with different config-as-code file paths in Railway.

3. For R2, set all normal S3-compatible variables plus:
   - `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`
   - `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`

4. Make sure `worker` is actually redeployed after changing those variables.
   - Seeing the variables in Railway UI is not enough.
   - Sidekiq must be restarted with a fresh deployment.

5. Add proxy-aware SSL support in Rails:
   - `config.assume_ssl = ... ENV.fetch('ASSUME_SSL', false)`
   - `config.force_ssl = ... ENV.fetch('FORCE_SSL', false)`

6. Set on `web`:
   - `ASSUME_SSL=true`
   - `FORCE_SSL=true`

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

If Railway UI deploy fields are read-only, that is expected while config-as-code is active. Point each service to its own file path instead of trying to edit the command inline in the dashboard.

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

Without them, a common failure mode is:

- Chatwoot receives the WhatsApp event
- the message row is created
- an attachment record is created
- but the actual file upload to R2 fails in the worker

That produces "ghost attachments" that appear in message payloads but do not render correctly in the UI.

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

If `FORCE_SSL=true` is set but cookies are not marked `secure`, or the app still behaves like HTTP behind the proxy, verify that:

- `ASSUME_SSL=true` is present in the live `web` runtime
- the running deployment actually includes the Rails `assume_ssl` code path
- the service is deploying from the expected branch and config file

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

## Fast troubleshooting checklist

### Problem: `web` and `worker` keep overwriting each other

Check:

- `web` is using `/railway.web.toml`
- `worker` is using `/railway.worker.toml`

### Problem: inbound WhatsApp images/files do not render

Check:

- `ACTIVE_STORAGE_SERVICE=s3_compatible`
- `STORAGE_ENDPOINT` points to R2
- checksum env vars exist on both `web` and `worker`
- `worker` has been redeployed after those vars were added

Look for this error in `worker` logs:

- `Aws::S3::Errors::InvalidRequest`
- `You can only specify one non-default checksum at a time.`

### Problem: SSL redirects or cookies behave strangely

Check:

- `ASSUME_SSL=true`
- `FORCE_SSL=true`
- `http://...` redirects to `https://...`
- session cookie contains `secure`

## Notes

- Avoid manual `railway up` deploys from arbitrary local states once GitHub autodeploy is established.
- Prefer pushing controlled commits to `mabe-production`.
- If Railway UI fields are read-only, confirm the service is pointing to the intended config-as-code file and not back to `/railway.toml`.
