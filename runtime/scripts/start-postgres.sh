#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

[ -f .env ] && . ./.env
[ -r runtime/generated/battlegroup.env ] && . runtime/generated/battlegroup.env

[ -r runtime/generated/image-tags.env ] && . runtime/generated/image-tags.env
source runtime/scripts/host-paths.sh
source runtime/scripts/runtime-env.sh
source runtime/scripts/image-tags.sh
# Refuse before building an image reference nothing can fetch. This registry is
# never logged into by this repo -- the images exist only once SteamCMD has
# downloaded the depot and update.sh has loaded its image tarballs -- so a
# missing image makes `docker run` attempt a pull that always fails, with an
# error that reads like a network problem. Matches the repository only: the tag
# resolver falls back to a hardcoded value that no shipped image carries.
if ! docker images --format '{{.Repository}}' 2>/dev/null \
    | grep -qx registry.funcom.com/funcom/self-hosting/igw-postgres; then
  echo "DUNE_GAME_ASSETS_MISSING" >&2
  echo "The Funcom database image is not installed on this host." >&2
  echo "Install the game files first:  dune update install-assets" >&2
  echo "(or Console -> Updates -> Install Game Files)" >&2
  exit 1
fi

POSTGRES_IMAGE_TAG="$(resolve_postgres_image_tag)"
IMAGE="registry.funcom.com/funcom/self-hosting/igw-postgres:${POSTGRES_IMAGE_TAG}"
POSTGRES_PORT="$(resolve_postgres_port)"

POSTGRES_BOOTSTRAP_DIR="runtime/postgres/bootstrap"
POSTGRES_BOOTSTRAP_SQL="$POSTGRES_BOOTSTRAP_DIR/ensure-dune.sql"
mkdir -p "$POSTGRES_BOOTSTRAP_DIR"

dune_db_password="${DUNE_DB_PASSWORD:-dune}"
DUNE_DB_PASSWORD="$dune_db_password" runtime/scripts/postgres-bootstrap-sql.sh \
  > "$POSTGRES_BOOTSTRAP_SQL"
chmod 600 "$POSTGRES_BOOTSTRAP_SQL"

dune_engine_create_network dune-net

runtime/scripts/stop-postgres-container.sh

# Docker answers a duplicate volume create with success; Podman's CLI exits
# 125, which under `set -e` means Postgres never starts on any run after the
# first. Guard it the way the sibling network create already is.
docker volume create dune-postgres-data >/dev/null 2>&1 || true

docker run -d \
  "${DUNE_DOCKER_LOG_ARGS[@]}" \
  --name dune-postgres \
  --network dune-net \
  --restart "$DUNE_ENGINE_RESTART_POLICY" \
  -p "127.0.0.1:${POSTGRES_PORT}:5432" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=dune \
  -v dune-postgres-data:/var/lib/postgresql/data \
  "$IMAGE"

echo "Waiting for Postgres..."
ready=0
for i in $(seq 1 60); do
  if docker exec dune-postgres pg_isready -h 127.0.0.1 -p 5432 -U postgres -d postgres >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done

if [ "$ready" != "1" ]; then
  echo "Postgres did not become ready in time."
  echo
  echo "=== Postgres logs ==="
  docker logs --tail 200 dune-postgres || true
  exit 1
fi

docker exec dune-postgres pg_isready -h 127.0.0.1 -p 5432 -U postgres -d postgres

echo
echo "=== Ensuring dune database role and database ==="
# Apply the bootstrap after readiness so every data volume, including an
# existing or partially initialized one, has the required project role before
# the migration starts.
docker exec -i dune-postgres psql -h 127.0.0.1 -p 5432 -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  < "$POSTGRES_BOOTSTRAP_SQL"

schema_exists="$(docker exec dune-postgres psql -h 127.0.0.1 -p 5432 -U postgres -d dune -Atc \
  "SELECT count(*) FROM pg_namespace WHERE nspname = 'dune';" | tr -d '[:space:]')"

if [ "$schema_exists" = "1" ]; then
  echo
  echo "=== Normalizing dune schema ownership and privileges ==="
  docker exec -i dune-postgres psql -h 127.0.0.1 -p 5432 -U postgres -d dune \
    -v ON_ERROR_STOP=1 <<'SQL'
ALTER DATABASE dune OWNER TO dune;
ALTER SCHEMA dune OWNER TO dune;
GRANT ALL PRIVILEGES ON DATABASE dune TO dune;
GRANT USAGE, CREATE ON SCHEMA dune TO dune;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA dune TO dune;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA dune TO dune;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA dune TO dune;
ALTER DEFAULT PRIVILEGES IN SCHEMA dune GRANT ALL PRIVILEGES ON TABLES TO dune;
ALTER DEFAULT PRIVILEGES IN SCHEMA dune GRANT ALL PRIVILEGES ON SEQUENCES TO dune;
ALTER DEFAULT PRIVILEGES IN SCHEMA dune GRANT ALL PRIVILEGES ON FUNCTIONS TO dune;

DO
$$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'ext') THEN
    GRANT USAGE ON SCHEMA ext TO dune;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ext TO dune;
    ALTER DEFAULT PRIVILEGES IN SCHEMA ext GRANT EXECUTE ON FUNCTIONS TO dune;
  END IF;
END
$$;

DO
$$
DECLARE
  obj record;
BEGIN
  FOR obj IN
    SELECT quote_ident(n.nspname) AS schema_name,
           quote_ident(c.relname) AS object_name,
           c.relkind AS relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'dune'
      AND c.relkind IN ('r','p','S','v','m','f')
      AND pg_get_userbyid(c.relowner) <> 'dune'
  LOOP
    EXECUTE format(
      'ALTER %s %s.%s OWNER TO dune',
      CASE obj.relkind
        WHEN 'S' THEN 'SEQUENCE'
        WHEN 'v' THEN 'VIEW'
        WHEN 'm' THEN 'MATERIALIZED VIEW'
        WHEN 'f' THEN 'FOREIGN TABLE'
        ELSE 'TABLE'
      END,
      obj.schema_name,
      obj.object_name
    );
  END LOOP;
END
$$;
SQL
else
  echo
  echo "The dune schema is not present yet; the database migration will create it."
fi

echo
echo "=== Databases ==="
docker exec dune-postgres psql -h 127.0.0.1 -p 5432 -U postgres -d dune -c '\l'

echo
echo "=== Roles ==="
docker exec dune-postgres psql -h 127.0.0.1 -p 5432 -U postgres -d dune -c '\du'

echo
echo "=== Container ==="
docker ps --filter "name=dune-postgres" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
