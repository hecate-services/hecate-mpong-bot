#!/usr/bin/env bash
#
# Deploy hecate-mpong-bot across the beam fleet — one bot per node, each
# dialing a DISTINCT station via MACULA_STATION_SEEDS (hecate_om 0.3.2+).
#
# The beams run Docker (not podman/Quadlet), and ghcr.io/hecate-services
# is PRIVATE, so we build locally and ship with `docker save | ssh load`.
# v1 connect/publish needs no cert (the SDK auto-generates an ephemeral
# peering identity), so no secret mount here. The Quadlet + station.env
# path is the gitops/podman future; this script is the current reality.
#
# Each node gets a different Leuven district station. Run the macula-demo
# teardown FIRST to free these stations from the old beam daemons:
#   (cd ../../macula-internal/macula-demo && ./scripts/teardown-beam-daemons.sh)
#
# Usage:
#   ./scripts/deploy-bots.sh             # build + load + run on all 4 beams
#   ./scripts/deploy-bots.sh build       # build the image locally
#   ./scripts/deploy-bots.sh load        # save + ssh-load image to all beams
#   ./scripts/deploy-bots.sh run         # (re)run the container on all beams
#   ./scripts/deploy-bots.sh run beam02  # one node
#   ./scripts/deploy-bots.sh status      # docker ps for the bot on each beam
#   ./scripts/deploy-bots.sh stop        # stop + remove the bot on each beam
#   ./scripts/deploy-bots.sh logs beam00 # tail one node's bot
#
set -eu

USER="rl"
IMAGE="ghcr.io/hecate-services/hecate-mpong-bot:latest"
NAME="hecate-mpong-bot"
DATA_DIR="/bulk0/hecate/hecate-mpong-bot"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# node → its single station seed. One station per bot (the requirement).
declare -A STATION=(
    [beam00]="https://station-be-leuven-centrum.macula.io:4433"
    [beam01]="https://station-be-leuven-gasthuisberg.macula.io:4433"
    [beam02]="https://station-be-leuven-heverlee.macula.io:4433"
    [beam03]="https://station-be-leuven-korbeek-lo.macula.io:4433"
)
ALL_NODES=(beam00 beam01 beam02 beam03)

ssh_node() { ssh -o ConnectTimeout=5 "${USER}@${1}.lab" "$2"; }

build() {
    echo "[build] ${IMAGE} from Containerfile"
    # --load: with a buildx docker-container driver, a bare build leaves the
    # result in the build cache only (not the local image store), so the
    # subsequent `docker save` would ship a stale image. --load imports it.
    docker build --load -f "${REPO_ROOT}/Containerfile" -t "${IMAGE}" "${REPO_ROOT}"
}

load_one() {
    local node="$1"
    echo "[${node}] loading image (docker save | ssh load)"
    docker save "${IMAGE}" | ssh -o ConnectTimeout=5 "${USER}@${node}.lab" "docker load"
}

run_one() {
    local node="$1"
    local seed="${STATION[$node]:-}"
    if [ -z "${seed}" ]; then
        echo "[${node}] no station mapping — skip"; return
    fi
    echo "[${node}] run ${NAME}  →  ${seed}"
    ssh_node "${node}" "mkdir -p ${DATA_DIR}
        docker rm -f ${NAME} 2>/dev/null || true
        docker run -d --name ${NAME} --restart always --network host \
            -e HECATE_MPONG_AUTO_HOST=true \
            -e MACULA_STATION_SEEDS='${seed}' \
            -v ${DATA_DIR}:/var/lib/hecate-mpong-bot \
            ${IMAGE}"
}

nodes_from_arg() {
    if [ "$#" -gt 0 ]; then echo "$@"; else echo "${ALL_NODES[@]}"; fi
}

case "${1:-all}" in
    all)
        build
        for n in "${ALL_NODES[@]}"; do load_one "$n"; run_one "$n"; done
        echo; for n in "${ALL_NODES[@]}"; do
            echo "=== ${n}.lab ==="
            ssh_node "$n" "docker ps --filter name=${NAME} --format '{{.Names}}\t{{.Status}}'" || true
        done
        ;;
    build) build ;;
    load)  shift; for n in $(nodes_from_arg "$@"); do load_one "$n"; done ;;
    run)   shift; for n in $(nodes_from_arg "$@"); do run_one  "$n"; done ;;
    status)
        for n in "${ALL_NODES[@]}"; do
            echo "=== ${n}.lab (${STATION[$n]}) ==="
            ssh_node "$n" "docker ps --filter name=${NAME} --format '{{.Names}}\t{{.Image}}\t{{.Status}}'" || true
        done
        ;;
    stop)
        shift; for n in $(nodes_from_arg "$@"); do
            echo "[${n}] stop + remove ${NAME}"
            ssh_node "$n" "docker rm -f ${NAME} 2>/dev/null || true"
        done
        ;;
    logs)
        node="${2:-beam00}"
        ssh -o ConnectTimeout=5 "${USER}@${node}.lab" "docker logs ${NAME} --tail 40 -f 2>&1"
        ;;
    *)
        echo "Usage: $0 [all|build|load [node...]|run [node...]|status|stop [node...]|logs [node]]"
        exit 1
        ;;
esac
