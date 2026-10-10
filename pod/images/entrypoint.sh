#!/usr/bin/env bash
# Pod entrypoint (POD-SPEC §6.2): prepare the volume layout and start the agent. Nothing else.
set -euo pipefail

WORKSPACE="${PODAGENT_WORKSPACE:-/workspace}"
mkdir -p "$WORKSPACE/datasets" "$WORKSPACE/runs" "$WORKSPACE/models/hf-cache" "$WORKSPACE/logs"
export HF_HOME="${HF_HOME:-$WORKSPACE/models/hf-cache}"

# PODAGENT_TOKEN is checked by the agent itself; it exits 2 with a message when unset.
#
# tini is PID 1 (-s: subreaper), the agent its only child. The supervisor tracks each service
# by its process group and probes the group with killpg(pgid, 0), which stays true while any
# member exists, zombies included: orphans left by a crashed wrapper or vLLM API server must be
# reaped by init, or their GPUs would never be released. tini forwards SIGTERM to the agent.
exec tini -s -- /opt/venvs/agent/bin/python -m podagent --host 0.0.0.0 --port 8800
