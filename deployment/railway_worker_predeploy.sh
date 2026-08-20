#!/bin/sh

set -u

max_attempts="${RAILWAY_MIGRATION_LOCK_RETRIES:-20}"
retry_delay="${RAILWAY_MIGRATION_LOCK_RETRY_DELAY:-10}"
attempt=1

while :; do
  output="$(POSTGRES_STATEMENT_TIMEOUT=600s bundle exec rails db:chatwoot_prepare 2>&1)"
  status=$?
  printf '%s\n' "$output"

  if [ "$status" -eq 0 ]; then
    exit 0
  fi

  if ! printf '%s\n' "$output" | grep -Fq 'ActiveRecord::ConcurrentMigrationError'; then
    exit "$status"
  fi

  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Migration lock remained busy after $attempt attempts." >&2
    exit "$status"
  fi

  echo "Another service is running migrations. Retrying in ${retry_delay}s ($attempt/$max_attempts)."
  attempt=$((attempt + 1))
  sleep "$retry_delay"
done
