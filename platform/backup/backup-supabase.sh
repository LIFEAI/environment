#!/usr/bin/env bash
# Supabase Backup — Dump all schemas from project uvojezuorjgqzmhhgluu
# Usage: bash scripts/backup-supabase.sh [output_dir]
#
# Requires: pg_dump (PostgreSQL client tools)
# Connection string from clauth: echo "pw" | clauth get supabase-db
#
# Schemas dumped: public, prt, rccs, virtue, pal, hail, ontology, rdc, lifeai

set -euo pipefail

# --- Config ---
SCHEMAS=("public" "prt" "rccs" "virtue" "pal" "hail" "ontology" "rdc" "lifeai")
OUTPUT_DIR="${1:-./backups/supabase}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${OUTPUT_DIR}/${TIMESTAMP}"

# --- Connection ---
# Try clauth daemon first, then env var
if command -v curl &>/dev/null && curl -s http://127.0.0.1:52437/ping &>/dev/null; then
  DB_URL=$(curl -s http://127.0.0.1:52437/get/supabase-db 2>/dev/null | tr -d '\n')
elif [ -n "${SUPABASE_DB_URL:-}" ]; then
  DB_URL="$SUPABASE_DB_URL"
else
  echo "ERROR: Cannot get DB connection string. Start clauth daemon or set SUPABASE_DB_URL."
  exit 1
fi

if [ -z "$DB_URL" ]; then
  echo "ERROR: Empty DB connection string."
  exit 1
fi

# --- Create output directory ---
mkdir -p "$BACKUP_DIR"
echo "=== Supabase Backup ==="
echo "Timestamp: $TIMESTAMP"
echo "Output:    $BACKUP_DIR"
echo ""

# --- Dump each schema ---
FAILED=0
for SCHEMA in "${SCHEMAS[@]}"; do
  OUTFILE="${BACKUP_DIR}/${SCHEMA}.sql"
  echo -n "  Dumping schema: ${SCHEMA}... "

  if pg_dump "$DB_URL" \
    --schema="$SCHEMA" \
    --no-owner \
    --no-privileges \
    --format=plain \
    --file="$OUTFILE" 2>/dev/null; then

    SIZE=$(wc -c < "$OUTFILE" | tr -d ' ')
    if [ "$SIZE" -gt 100 ]; then
      echo "OK ($(numfmt --to=iec "$SIZE" 2>/dev/null || echo "${SIZE}B"))"
    else
      echo "EMPTY (schema may not have tables)"
      rm -f "$OUTFILE"
    fi
  else
    echo "FAILED"
    FAILED=$((FAILED + 1))
    rm -f "$OUTFILE"
  fi
done

# --- Combined dump (all schemas, one file) ---
echo ""
echo -n "  Combined dump (all schemas)... "
COMBINED="${BACKUP_DIR}/all-schemas.sql"
SCHEMA_FLAGS=""
for SCHEMA in "${SCHEMAS[@]}"; do
  SCHEMA_FLAGS="$SCHEMA_FLAGS --schema=$SCHEMA"
done

if pg_dump "$DB_URL" \
  $SCHEMA_FLAGS \
  --no-owner \
  --no-privileges \
  --format=plain \
  --file="$COMBINED" 2>/dev/null; then
  SIZE=$(wc -c < "$COMBINED" | tr -d ' ')
  echo "OK ($(numfmt --to=iec "$SIZE" 2>/dev/null || echo "${SIZE}B"))"
else
  echo "FAILED"
  FAILED=$((FAILED + 1))
fi

# --- Summary ---
echo ""
FILE_COUNT=$(ls -1 "$BACKUP_DIR"/*.sql 2>/dev/null | wc -l)
echo "=== Done: ${FILE_COUNT} files in ${BACKUP_DIR} ==="

if [ "$FAILED" -gt 0 ]; then
  echo "WARNING: ${FAILED} dump(s) failed. Check pg_dump is installed and DB is accessible."
  exit 1
fi
