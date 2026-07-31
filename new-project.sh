#!/usr/bin/env bash
# new-project.sh - bootstrap a spec-driven .NET project with a stack you choose.
#
# Usage (run from Git Bash on Windows, or any bash):
#   ./new-project.sh MyProject                       -> interactive stack prompts
#   ./new-project.sh MyProject ~/dev                 -> creates ~/dev/MyProject
#   ./new-project.sh MyProject ~/dev --api=rest --db=postgres --cache=none --yes
#
# Stack options (all default to the interactive prompt unless --yes is passed):
#   --api=rest|graphql|grpc|none      HTTP surface for the Api project
#   --db=mongo|sqlserver|postgres|none
#   --cache=redis|none
#   --tfm=net8.0|net9.0|net10.0
#   --yes                             non-interactive; use defaults for anything unspecified
#
# What it does:
#   1. Checks prerequisites (dotnet, git)
#   2. Resolves the stack (flags, then prompts, then defaults)
#   3. Scaffolds the solution and adds only the packages that stack needs
#   4. Copies workflow files, gate scripts, rules, and MCP config
#   5. Generates docker-compose.yml from the chosen services only
#   6. Installs the skill pack into .claude/skills
#   7. Installs SpecKit (if missing) and runs `specify init`
#   8. Seeds YOUR constitution over SpecKit's default (must happen AFTER init)
#   9. Builds, then git init + initial commit

set -euo pipefail

# --- args ---------------------------------------------------------------
NAME=""
PARENT="."
API=""; DB=""; CACHE=""; TFM=""; ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --api=*)   API="${arg#*=}" ;;
    --db=*)    DB="${arg#*=}" ;;
    --cache=*) CACHE="${arg#*=}" ;;
    --tfm=*)   TFM="${arg#*=}" ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
    -*)        echo "Unknown option: $arg" >&2; exit 1 ;;
    *)         if [ -z "$NAME" ]; then NAME="$arg"; else PARENT="$arg"; fi ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "Usage: ./new-project.sh <ProjectName> [parent-dir] [--api=] [--db=] [--cache=] [--tfm=] [--yes]" >&2
  exit 1
fi
if ! [[ "$NAME" =~ ^[A-Za-z][A-Za-z0-9._]*$ ]]; then
  echo "Project name must be a valid .NET identifier (got: $NAME)" >&2
  exit 1
fi

STARTER="$(cd "$(dirname "$0")" && pwd)"
TARGET="$PARENT/$NAME"
if [ -e "$TARGET" ]; then
  echo "Target already exists: $TARGET" >&2
  exit 1
fi

# --- stack selection ----------------------------------------------------
# choose <var-name> <prompt> <default> <option>...
choose() {
  local __var="$1"; shift
  local prompt="$1"; shift
  local default="$1"; shift
  local options=("$@")
  local current="${!__var}"

  if [ -n "$current" ]; then
    local ok=0
    for o in "${options[@]}"; do [ "$o" = "$current" ] && ok=1; done
    if [ "$ok" -eq 0 ]; then
      echo "Invalid value for $__var: $current (expected one of: ${options[*]})" >&2
      exit 1
    fi
    return
  fi

  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    printf -v "$__var" '%s' "$default"
    return
  fi

  echo
  echo "$prompt"
  local i=1
  for o in "${options[@]}"; do
    if [ "$o" = "$default" ]; then echo "  $i) $o (default)"; else echo "  $i) $o"; fi
    i=$((i+1))
  done
  local reply
  read -r -p "> " reply
  if [ -z "$reply" ]; then
    printf -v "$__var" '%s' "$default"
  elif [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#options[@]}" ]; then
    printf -v "$__var" '%s' "${options[$((reply-1))]}"
  else
    local ok=0
    for o in "${options[@]}"; do [ "$o" = "$reply" ] && ok=1; done
    if [ "$ok" -eq 1 ]; then printf -v "$__var" '%s' "$reply"; else
      echo "Invalid choice: $reply" >&2; exit 1
    fi
  fi
}

choose TFM   "Target framework?"            "net8.0"  net8.0 net9.0 net10.0
choose API   "HTTP surface for the Api?"    "rest"    rest graphql grpc none
choose DB    "Database?"                    "none"    none mongo sqlserver postgres
choose CACHE "Distributed cache?"           "none"    none redis

echo
echo "Stack: tfm=$TFM api=$API db=$DB cache=$CACHE"

# --- prerequisites ------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing prerequisite: $1" >&2; exit 1; }; }
need dotnet
need git
command -v docker >/dev/null 2>&1 || echo "NOTE: docker not found - docker compose + Testcontainers won't run until it's installed."
command -v pwsh   >/dev/null 2>&1 || echo "NOTE: pwsh (PowerShell 7) not found - the static-analysis gate scripts require it."

# --- scaffold solution --------------------------------------------------
echo "==> Scaffolding $NAME"
mkdir -p "$TARGET"
cd "$TARGET"

dotnet new gitignore >/dev/null
dotnet new sln -n "$NAME" >/dev/null

case "$API" in
  grpc) API_TEMPLATE=grpc ;;
  none) API_TEMPLATE=worker ;;
  *)    API_TEMPLATE=web ;;
esac

dotnet new "$API_TEMPLATE" -n "$NAME.Api"    -o "src/$NAME.Api"     >/dev/null
dotnet new classlib        -n "$NAME.Domain" -o "src/$NAME.Domain"  >/dev/null
dotnet new xunit           -n "$NAME.Tests"  -o "tests/$NAME.Tests" >/dev/null

dotnet sln add "src/$NAME.Api" "src/$NAME.Domain" "tests/$NAME.Tests" >/dev/null
dotnet add "src/$NAME.Api"     reference "src/$NAME.Domain" >/dev/null
dotnet add "tests/$NAME.Tests" reference "src/$NAME.Api" "src/$NAME.Domain" >/dev/null

echo "==> Adding packages for the chosen stack"
add_api()  { dotnet add "src/$NAME.Api"     package "$1" >/dev/null; }
add_test() { dotnet add "tests/$NAME.Tests" package "$1" >/dev/null; }

case "$API" in
  graphql) add_api HotChocolate.AspNetCore ;;
  grpc)    : ;;  # the grpc template already references Grpc.AspNetCore
esac

case "$DB" in
  mongo)     add_api MongoDB.Driver;                                add_test Testcontainers.MongoDb ;;
  sqlserver) add_api Microsoft.EntityFrameworkCore.SqlServer;       add_test Testcontainers.MsSql ;;
  postgres)  add_api Npgsql.EntityFrameworkCore.PostgreSQL;         add_test Testcontainers.PostgreSql ;;
esac

[ "$CACHE" = "redis" ] && { add_api StackExchange.Redis; add_test Testcontainers.Redis; }

# WebApplicationFactory only makes sense for an actual web host
[ "$API" != "none" ] && add_test Microsoft.AspNetCore.Mvc.Testing
add_test Microsoft.Extensions.TimeProvider.Testing

# --- workflow files -----------------------------------------------------
#
# Deliberately NOT copied here. install.ps1 (called near the end of this script)
# places every harness file: skills, agents, rules, hooks, gate scripts,
# analyzer wiring, and the configs rendered from harness.yml.
#
# This block used to duplicate that copying, which meant two code paths that
# drifted - the generator was still pointing at directories that had moved, so
# it had been broken for a while without anyone running it. One installer, one
# code path, and the generator's only job is to scaffold the solution first.

# --- docker-compose from the chosen services only -----------------------
COMPOSE_SERVICES=()
[ "$DB" != "none" ]    && COMPOSE_SERVICES+=("$DB")
[ "$CACHE" != "none" ] && COMPOSE_SERVICES+=("$CACHE")

if [ ${#COMPOSE_SERVICES[@]} -gt 0 ]; then
  {
    echo "services:"
    for s in "${COMPOSE_SERVICES[@]}"; do
      case "$s" in
        mongo) cat "$STARTER/packs/dotnet/templates/compose/mongodb.yml" ;;
        *)     cat "$STARTER/packs/dotnet/templates/compose/$s.yml" ;;
      esac
    done
    # named volumes for the stateful services only
    VOLS=()
    [ "$DB" = "mongo" ]     && VOLS+=("mongo-data:")
    [ "$DB" = "sqlserver" ] && VOLS+=("sqlserver-data:")
    [ "$DB" = "postgres" ]  && VOLS+=("postgres-data:")
    if [ ${#VOLS[@]} -gt 0 ]; then
      echo
      echo "volumes:"
      for v in "${VOLS[@]}"; do echo "  $v"; done
    fi
  } > docker-compose.yml
  echo "==> docker-compose.yml written (${COMPOSE_SERVICES[*]})"
else
  echo "==> No infra services selected - skipping docker-compose.yml"
fi

# --- CLAUDE.md, filled in for this stack --------------------------------
case "$DB" in
  mongo)     DB_LABEL="MongoDB" ;;
  sqlserver) DB_LABEL="SQL Server" ;;
  postgres)  DB_LABEL="PostgreSQL" ;;
  *)         DB_LABEL="" ;;
esac
case "$API" in
  rest)    API_LABEL="Minimal API" ;;
  graphql) API_LABEL="Hot Chocolate GraphQL" ;;
  grpc)    API_LABEL="gRPC" ;;
  *)       API_LABEL="worker service (no HTTP surface)" ;;
esac

STACK_SUMMARY=".NET ${TFM#net} backend: $API_LABEL"
[ -n "$DB_LABEL" ]       && STACK_SUMMARY="$STACK_SUMMARY, $DB_LABEL"
[ "$CACHE" = "redis" ]   && STACK_SUMMARY="$STACK_SUMMARY, Redis"
STACK_SUMMARY="$STACK_SUMMARY, xUnit, Testcontainers, Stryker.NET."

PORTS=()
[ "$DB" = "mongo" ]     && PORTS+=("MongoDB on 27017")
[ "$DB" = "sqlserver" ] && PORTS+=("SQL Server on 1433")
[ "$DB" = "postgres" ]  && PORTS+=("PostgreSQL on 5432")
[ "$CACHE" = "redis" ]  && PORTS+=("Redis on 6379")

if [ ${#PORTS[@]} -gt 0 ]; then
  PORT_LIST=$(printf '%s, ' "${PORTS[@]}")
  INFRA_COMMAND="\`docker compose up -d\` (${PORT_LIST%, })"
else
  INFRA_COMMAND="none - this project declares no local infra services."
fi

# Stack-specific non-negotiables, one per line, written to a file so multi-line
# content never has to survive a sed replacement.
NOTES_FILE="$(mktemp)"
if [ "$DB" = "mongo" ]; then
  echo '- No BSON attributes on domain types. New Mongo query shapes need `.Explain()` evidence.' >> "$NOTES_FILE"
elif [ "$DB" != "none" ]; then
  echo '- No EF Core attributes on domain types - configure via `IEntityTypeConfiguration<T>`. New query shapes need an execution-plan check.' >> "$NOTES_FILE"
fi
[ "$API" = "graphql" ] && echo '- DataLoaders for resolver fan-out. No N+1 in resolvers.' >> "$NOTES_FILE"

# Article V of the constitution, derived from the SAME stack flags.
#
# This used to be the bug: only {{PROJECT_NAME}} was substituted, so a project
# created with --db=postgres still shipped a constitution mandating MongoDB,
# Hot Chocolate, and Redis. A constitution that contradicts the code it governs
# trains everyone to ignore it, which is worse than having none.
CONSTRAINTS_FILE="$(mktemp)"
case "$DB" in
  mongo)     echo '4. Persistence: MongoDB via the official driver. Queries that scan collections require an index; `.Explain()` evidence is required in review for new query shapes.' >> "$CONSTRAINTS_FILE" ;;
  postgres)  echo '4. Persistence: PostgreSQL via Npgsql/EF Core. New query shapes need an execution-plan check in review; no unindexed sequential scans on hot paths.' >> "$CONSTRAINTS_FILE" ;;
  sqlserver) echo '4. Persistence: SQL Server via EF Core. New query shapes need an actual-execution-plan check in review; no unindexed scans on hot paths.' >> "$CONSTRAINTS_FILE" ;;
esac
case "$API" in
  graphql) echo '5. API: GraphQL via Hot Chocolate. Resolver fan-out to persistence goes through DataLoaders — no N+1 by construction. Schema diffs are attached to the task.' >> "$CONSTRAINTS_FILE" ;;
  grpc)    echo '5. API: gRPC with contract-first `.proto` files. Contract changes are breaking-change-reviewed.' >> "$CONSTRAINTS_FILE" ;;
  rest)    echo '5. API: REST over HTTP with explicit status codes and `ProblemDetails` (RFC 9457) for errors. Contract changes are breaking-change-reviewed.' >> "$CONSTRAINTS_FILE" ;;
esac
[ "$CACHE" = "redis" ] && echo '6. Caching: Redis via StackExchange.Redis. Cache entries carry explicit TTLs; no unbounded caches.' >> "$CONSTRAINTS_FILE"

# --- harness ------------------------------------------------------------
# Runs BEFORE CLAUDE.md is written, deliberately.
#
# install.ps1 writes the adapter CLAUDE.md carrying the @imports for all ten
# always-on rules, and never overwrites an existing one. If the generator wrote
# its own CLAUDE.md first, install would skip it and the generated project would
# silently lose every always-on rule on Claude Code - the failure would look
# like "the agent ignores our conventions", with nothing obviously broken.
#
# So: install first, then APPEND the stack section to what it wrote.
echo "==> Installing the harness"
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File "$STARTER/install.ps1" "$(pwd)" || \
    echo "install.ps1 failed - run it manually: pwsh $STARTER/install.ps1 $(pwd)"
else
  echo "pwsh not found - install PowerShell 7, then: pwsh $STARTER/install.ps1 $(pwd)"
fi

# --- CLAUDE.md: append this project's stack to the installed file --------
{
  echo ""
  echo "## Stack"
  echo ""
  echo "$STACK_SUMMARY"
  echo ""
  echo "- Local infra: $INFRA_COMMAND"
  echo "- Integration tests use Testcontainers - Docker must be running."
  if [ -s "$NOTES_FILE" ]; then
    echo ""
    echo "### Stack non-negotiables"
    echo ""
    cat "$NOTES_FILE"
  fi
} >> CLAUDE.md
rm -f "$NOTES_FILE"

# --- speckit ------------------------------------------------------------
echo "==> Setting up SpecKit"
if ! command -v specify >/dev/null 2>&1; then
  need uv
  uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
fi
specify init --here --integration claude --no-git 2>/dev/null \
  || specify init --here --ai claude --no-git 2>/dev/null \
  || specify init --here --ai claude \
  || { echo "specify init failed - run it manually inside $TARGET, then re-copy the constitution:"; \
       echo "  cp '$STARTER/packs/dotnet/templates/constitution.md' .specify/memory/constitution.md"; }

# Seed the constitution AFTER init - init overwrites .specify/memory/constitution.md
if [ -d .specify/memory ]; then
  # Same stack-aware substitution CLAUDE.md gets. Article V must describe the
  # stack that was actually scaffolded, not the one the template was written for.
  sed -e "s/{{PROJECT_NAME}}/$NAME/g" \
      -e "s|{{TFM_LABEL}}|.NET ${TFM#net}|g" \
      "$STARTER/packs/dotnet/templates/constitution.md" > .specify/memory/constitution.md.tmpl

  awk -v constraints="$CONSTRAINTS_FILE" '
    /\{\{STACK_CONSTRAINTS\}\}/ {
      while ((getline line < constraints) > 0) print line
      close(constraints)
      next
    }
    { print }
  ' .specify/memory/constitution.md.tmpl > .specify/memory/constitution.md
  rm -f .specify/memory/constitution.md.tmpl

  # Fail loudly rather than shipping a constitution with visible placeholders.
  if grep -q '{{' .specify/memory/constitution.md; then
    echo "WARNING: unsubstituted placeholders remain in the constitution:"
    grep -n '{{' .specify/memory/constitution.md
  fi

  echo "==> Constitution seeded (stack-aware)"
fi
rm -f "$CONSTRAINTS_FILE"

# --- verify + commit ----------------------------------------------------
echo "==> Building"
dotnet build --nologo -v q

git init -q
git add -A
git commit -qm "chore: bootstrap $NAME ($API/$DB/$CACHE on $TFM)" \
  || echo "NOTE: initial commit skipped (configure git user.name/user.email, then commit manually)."

echo
echo "Done. Next steps:"
echo "  cd $TARGET"
[ ${#COMPOSE_SERVICES[@]} -gt 0 ] && echo "  docker compose up -d          # ${COMPOSE_SERVICES[*]}"
echo "  dotnet tool restore           # provisions jb (InspectCode) + stryker"
echo "  claude                        # then /grill-with-docs to start the first feature"
