#!/usr/bin/env bash
# run-all.sh - starts all 9 Java services and the web UI.
# Usage:  ./run-all.sh            start everything (services already running are skipped)
#         ./run-all.sh --build    rebuild each jar first (use after pulling new code)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

# The 'local' profile must NOT be active in the integrated system.
unset SPRING_PROFILES_ACTIVE

if [ ! -f run.env ]; then
  echo "Missing $ROOT/run.env. Create it first."
  exit 1
fi
set -a
source ./run.env
set +a

: "${DB_PASSWORD:?Set DB_PASSWORD in run.env}"
: "${MAIL_USERNAME:?Set MAIL_USERNAME in run.env}"
: "${MAIL_PASSWORD:?Set MAIL_PASSWORD in run.env}"
: "${REDIS_PASSWORD:?Set REDIS_PASSWORD in run.env}"
: "${EVENT_CRYPTO_KEY:?Set EVENT_CRYPTO_KEY in run.env (generate with: openssl rand -base64 32)}"

DB_PORT="${DB_PORT:-5433}"
DB_USER="${DB_USER:-banking_admin}"

BUILD=false
[ "${1:-}" = "--build" ] && BUILD=true

LOG_DIR="$ROOT/logs"
PID_DIR="$ROOT/.pids"
mkdir -p "$LOG_DIR" "$PID_DIR"
mkdir -p "$HOME/banking-logs"

# name | port | database (empty = no database)
SERVICES=(
  "discovery-service|8761|"
  # The event bus service creates the Kafka topics. Kafka runs with
  # auto-create turned off, so without it no topic exists and every
  # event publish fails.
  "event-bus-service|8090|"
  "core-banking-service|8084|cbs_db"
  "charge-fee-service|8085|"
  "notification-service|8087|notification_db"
  "otp-service|8086|"
  "user-service|8083|user_db"
  "account-service|8081|account_db"
  "fund-transfer-service|8082|fund_transfer_db"
  "api-gateway|8080|"
)

port_open() {
  (echo > "/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1
}

jar_of() {
  find "$1/target" -maxdepth 1 -name '*.jar' ! -name '*.original' 2>/dev/null | head -1
}

if ! port_open "$DB_PORT"; then
  echo "PostgreSQL is not reachable on port $DB_PORT."
  echo "Start it first: docker compose up -d (inside the folder with your compose file)."
  exit 1
fi

# Repair the database schema before anything starts.
#
# Docker runs /docker-entrypoint-initdb.d only when the data volume is created
# for the first time. An existing installation keeps the schema it had, and
# that schema can be older than the entities. With a broken schema the
# notification service cannot store a processed event and the outbox relay
# cannot publish, so no OTP email is ever sent.
#
# The repair script is idempotent, so it is safe to run on every start.
repair_schema() {
  local psql_cmd="psql -v ON_ERROR_STOP=1 -U $DB_USER -h 127.0.0.1 -p $DB_PORT"

  if ! command -v psql >/dev/null 2>&1; then
    # psql is not installed on this machine. Then the repair has to run inside
    # the PostgreSQL container.
    local container="${POSTGRES_CONTAINER:-banking-postgres}"
    if ! docker exec "$container" true 2>/dev/null; then
      echo "Cannot repair the database: no psql on this machine and the container '$container' is not running."
      echo "Start it first: docker compose up -d"
      exit 1
    fi
    docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres \
      < "$ROOT/postgres/init/04-repair-schema.sql" >/dev/null || {
        echo "The database repair failed. See the output above."
        exit 1
      }
    echo "[schema] database schema is up to date"
    return 0
  fi

  PGPASSWORD="$DB_PASSWORD" $psql_cmd -d postgres \
    < "$ROOT/postgres/init/04-repair-schema.sql" >/dev/null || {
      echo "The database repair failed. See the output above."
      exit 1
    }
  echo "[schema] database schema is up to date"
}

repair_schema


REDIS_PORT="${REDIS_PORT:-6379}"

if ! port_open "$REDIS_PORT"; then
 echo "Redis is not reachable on port $REDIS_PORT."
 echo "Start it first: docker compose up -d redis (inside the folder with your compose file)."
 exit 1
fi

if ! port_open 9092; then
  echo "Kafka is not reachable on port 9092."
  echo "Start it first: docker compose up -d kafka kafka-init (inside the folder with your compose file)."
  exit 1
fi

start_service() {
  local name="$1" port="$2" db="$3"

  if [ ! -d "$ROOT/$name" ]; then
    echo "ERROR: folder $ROOT/$name not found."
    exit 1
  fi

  if port_open "$port"; then
    echo "[$name] port $port already in use, assuming it is running. Skipping."
    return 0
  fi

  local jar
  jar="$(jar_of "$ROOT/$name")"
  if [ "$BUILD" = true ] || [ -z "$jar" ]; then
    echo "[$name] building..."
    if ! (cd "$ROOT/$name" && mvn -q clean package -DskipTests); then
      echo "[$name] BUILD FAILED. Fix the error above and run again."
      exit 1
    fi
    jar="$(jar_of "$ROOT/$name")"
  fi
  if [ -z "$jar" ]; then
    echo "[$name] no jar found in target/."
    exit 1
  fi

  local -a envs=("SERVER_PORT=$port")
  if [ -n "$db" ]; then
    envs+=("SPRING_DATASOURCE_URL=jdbc:postgresql://127.0.0.1:$DB_PORT/$db"
           "SPRING_DATASOURCE_USERNAME=$DB_USER"
           "SPRING_DATASOURCE_PASSWORD=$DB_PASSWORD")
  fi

  echo "[$name] starting on port $port..."
  pushd "$ROOT/$name" >/dev/null
  env "${envs[@]}" nohup java -jar "$jar" > "$LOG_DIR/$name.log" 2>&1 &
  local pid=$!
  echo "$pid" > "$PID_DIR/$name.pid"
  popd >/dev/null

  local i
  for i in $(seq 1 90); do
    if port_open "$port"; then
      echo "[$name] UP"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[$name] FAILED to start. Last log lines:"
      tail -n 25 "$LOG_DIR/$name.log"
      exit 1
    fi
    sleep 2
  done
  echo "[$name] did not open port $port within 3 minutes. See $LOG_DIR/$name.log"
  exit 1
}

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name port db <<< "$entry"
  start_service "$name" "$port" "$db"
done

# Web UI
if port_open 3000; then
  echo "[banking-web-ui] port 3000 already in use. Skipping."
else
  nohup python3 "$ROOT/banking-web-ui/serve.py" 3000 > "$LOG_DIR/banking-web-ui.log" 2>&1 &
  echo $! > "$PID_DIR/banking-web-ui.pid"
  echo "[banking-web-ui] UP on port 3000"
fi

# Wait until every service is visible in Eureka.
# The discovery service does not register itself, and the web UI is not a
# Eureka client at all, so neither is counted here.
EXPECTED_SERVICES=$((${#SERVICES[@]} - 1))
echo "Waiting for $EXPECTED_SERVICES services to register in Eureka..."
registered=false
for i in $(seq 1 60); do
  apps="$(curl -s -H 'Accept: application/json' http://localhost:8761/eureka/apps \
          | grep -oE '"name":"[A-Z-]+"' | sort -u | wc -l)"
  if [ "$apps" -ge "$EXPECTED_SERVICES" ]; then
    registered=true
    break
  fi
  sleep 3
done
if [ "$registered" = true ]; then
  echo "All $EXPECTED_SERVICES services are registered in Eureka."
else
  echo "Not all services registered yet. Open http://localhost:8761 to see which one is missing."
fi

# Wait until the gateway can actually route a request.
#
# Being registered in Eureka is not the same as being routable. The gateway
# keeps its own copy of the registry and only refreshes it every few seconds,
# so right after a start the first request of a route still answered
# 503 "No servers available for service: ...". This loop sends a request
# that needs no login and waits until the gateway forwards it.
wait_for_gateway() {
  echo "Waiting for the gateway to route requests..."
  for i in $(seq 1 40); do
    code="$(curl -s -m 5 -o /dev/null -w "%{http_code}" \
            -X POST -H 'Content-Type: application/json' \
            -d '{"email":"nobody@example.invalid","password":"x"}' \
            http://localhost:8080/api/auth/login)"
    # 401 means the request reached the user service and was rejected there.
    # 503 means the gateway had no instance for the route yet.
    if [ "$code" = "401" ] || [ "$code" = "400" ]; then
      echo "The gateway routes requests."
      return 0
    fi
    sleep 2
  done
  echo "The gateway still does not route requests. Check $LOG_DIR/api-gateway.log."
  return 1
}
wait_for_gateway

echo
echo "Eureka:  http://localhost:8761"
echo "Web UI:  http://localhost:3000"
echo "Logs:    $LOG_DIR/<service>.log  (example: tail -f logs/fund-transfer-service.log)"
echo "Stop:    ./stop-all.sh"
echo "Logs and traces: Grafana > Explore (Loki, Tempo) and the dashboard 'Banking - Logs'"
