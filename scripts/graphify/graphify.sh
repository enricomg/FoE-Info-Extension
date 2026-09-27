#!/usr/bin/env bash
set -e

#
# FoE-Info Unified Knowledge Graph Automation
# Supports all repositories across ast, update, reindex, label, export, watch, mcp,
# reflect and save-result.
# Usage: bash scripts/graphify/graphify.sh [target] [action] [options...]
#
# Actions: ast (default), update, reindex, label, export, watch, mcp, reflect, save-result
#
# DERIVED EXPORTS ARE OPT-IN. graph.json is the only artifact a query reads, and
# GRAPH_REPORT.md is the only human-facing summary. Every other format (wiki/,
# obsidian/, svg, html, tree, and the dated backup directories) is regenerable
# and was previously written on every ast/update/reindex/label run, which filled
# graphify-out/ with tens of megabytes nobody read — 26M of obsidian/ and 1.7M of
# wiki/ in metadata-store alone. Pass `--export` to any action to emit them, or
# run the `export` action explicitly.
#

SCRIPT_DIR="$(builtin cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
WORKSPACE_ROOT="$(builtin cd "${SCRIPT_DIR}/../.." && pwd)"
PARENT_WORKSPACE="$(builtin cd "${WORKSPACE_ROOT}/.." && pwd)"
PROJECTS_ROOT="$(builtin cd "${PARENT_WORKSPACE}/.." && pwd)"
# Source shared inference policy if available
if [ -f "${SCRIPT_DIR}/inference-env.sh" ]; then
  source "${SCRIPT_DIR}/inference-env.sh"
fi

TARGET="${1:-foe-info}"
ACTION="${2:-ast}"
shift 2 2>/dev/null || true

# --export opts into the regenerable derived formats. Strip it from the argument
# list so it never reaches graphify itself, and keep it out of "$@" below.
DO_EXPORT=0
PASSTHROUGH=()
for arg in "$@"; do
  if [ "$arg" = "--export" ]; then
    DO_EXPORT=1
  else
    PASSTHROUGH+=("$arg")
  fi
done
set -- ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}

maybe_export() {
  if [ "$DO_EXPORT" = "1" ]; then
    $RUNNER export wiki obsidian svg html tree "$@"
  fi
}

case "$TARGET" in
  foe-info)
    TARGET_DIR="${WORKSPACE_ROOT}"
    export GRAPHIFY_OUT="${WORKSPACE_ROOT}/graphify-out"
    ;;
  foe-info-original)
    TARGET_DIR="${ORIGINAL_DIR:-${PARENT_WORKSPACE}/FoE-Info-Extension-original}"
    export GRAPHIFY_OUT="${TARGET_DIR}/graphify-out"
    ;;
  forge-hammer)
    TARGET_DIR="${FORGE_HAMMER_DIR:-${PARENT_WORKSPACE}/forge-hammer}"
    export GRAPHIFY_OUT="${TARGET_DIR}/graphify-out"
    ;;
  metadata)
    TARGET_DIR="${METADATA_DIR:-${PARENT_WORKSPACE}/metadata-store}"
    export GRAPHIFY_OUT="${TARGET_DIR}/graphify-out"
    ;;
  peer-repo)
    # Closed-source fork. Its graph stays local: graphify-out/ is already in that
    # repo's .gitignore, so nothing here can reach the closed-source history.
    TARGET_DIR="${PEER_REPO_DIR:-${PARENT_WORKSPACE}/peer-repo}"
    export GRAPHIFY_OUT="${TARGET_DIR}/graphify-out"
    ;;
  *)
    echo "Unknown target: $TARGET" >&2
    echo "Supported targets: foe-info, foe-info-original, forge-hammer, metadata, peer-repo" >&2
    exit 1
    ;;
esac

if [ ! -d "$TARGET_DIR" ]; then
  echo "Target directory not found: $TARGET_DIR" >&2
  exit 1
fi

builtin cd "$TARGET_DIR"

RUNNER="graphify"
if ! command -v graphify >/dev/null 2>&1; then
  if [ -x "${WORKSPACE_ROOT}/.venv/bin/graphify" ]; then
    RUNNER="${WORKSPACE_ROOT}/.venv/bin/graphify"
  else
    RUNNER="uv run graphify"
  fi
fi

case "$ACTION" in
  ast)
    if [ "$TARGET" = "metadata" ]; then
      echo "==> Building metadata graph for $TARGET..."
      node "${SCRIPT_DIR}/build-metadata-graph.mjs"
      maybe_export "$@"
    else
      echo "==> AST update for $TARGET..."
      $RUNNER update . "$@"
      maybe_export "$@"
    fi
    ;;
  update)
    if [ "$TARGET" = "metadata" ]; then
      echo "==> Updating metadata graph for $TARGET..."
      node "${SCRIPT_DIR}/build-metadata-graph.mjs"
      maybe_export "$@"
    else
      echo "==> Incremental update for $TARGET..."
      $RUNNER update . "$@"
      maybe_export "$@"
    fi
    ;;
  reindex)
    if [ "$TARGET" = "metadata" ]; then
      echo "==> Full reindex for $TARGET..."
      node "${SCRIPT_DIR}/build-metadata-graph.mjs"
      maybe_export "$@"
    else
      bash "${SCRIPT_DIR}/graphify-model.sh" run bash -c '
        set -e
        runner="$1"
        shift
        $runner extract . --token-budget 8192 "$@"
        $runner label --max-concurrency 1 "$@"
      ' bash "$RUNNER" "$@"
      maybe_export "$@"
    fi
    ;;
  label)
    # Relabel communities only. A tier-1 AST refresh — including the post-commit
    # hook — drops the saved label of any community whose membership shifted and
    # falls back to the hub node's name, so this is the cheap repair for that.
    # It deliberately does NOT re-extract: `reindex` remains the action that does
    # extract + label, and re-extracting a current AST is what degrades labels.
    #
    # This is a REPAIR, not a luxury. An unlabeled graph names its communities
    # after hub files, so a query returns "jquery.tabslet.min.js" as a topic
    # instead of "Charting" — measured on forge-hammer, which had 24 of 125
    # communities filename-derived until this action was run on it. Any target
    # whose community names are filenames needs this action.
    echo "==> Relabeling $TARGET communities (no re-extract)..."
    bash "${SCRIPT_DIR}/graphify-model.sh" run bash -c '
      set -e
      runner="$1"
      shift
      $runner label --max-concurrency 1 "$@"
    ' bash "$RUNNER" "$@"
    maybe_export "$@"
    ;;
  export)
    echo "==> Exporting graph documentation for $TARGET..."
    $RUNNER export wiki obsidian svg html tree "$@"
    ;;
  watch)
    echo "==> Watching $TARGET for changes..."
    $RUNNER watch . "$@"
    ;;
  reflect)
    echo "==> Aggregating graph memory reflections for $TARGET..."
    $RUNNER reflect --memory-dir "${GRAPHIFY_OUT}/memory" --out "${GRAPHIFY_OUT}/reflections/LESSONS.md" --graph "${GRAPHIFY_OUT}/graph.json" "$@"
    ;;
  save-result)
    $RUNNER save-result --memory-dir "${GRAPHIFY_OUT}/memory" "$@"
    ;;
  mcp)
    exec graphify-mcp "${GRAPHIFY_OUT}/graph.json" "$@"
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    echo "Supported actions: ast, update, reindex, label, export, watch, mcp, reflect, save-result" >&2
    exit 1
    ;;
esac
