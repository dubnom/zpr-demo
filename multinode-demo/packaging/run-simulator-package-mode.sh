#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
    echo "usage: run-simulator-package-mode.sh dashboard-stack-arguments..." >&2
    exit 2
fi

if [ -z "${ZPR_DASHBOARD_DIR:-}" ]; then
    echo "ZPR_DASHBOARD_DIR must point to the required dashboard support tree" >&2
    exit 2
fi

if [ -z "${ZPR_SIMULATOR_IMAGE:-}" ]; then
    echo "ZPR_SIMULATOR_IMAGE must name the locally loaded Simulator image" >&2
    exit 2
fi

dashboard_stack="$ZPR_DASHBOARD_DIR/scripts/dashboard-stack.sh"
if [ ! -f "$dashboard_stack" ]; then
    echo "dashboard-stack.sh was not found under ZPR_DASHBOARD_DIR" >&2
    exit 2
fi

export ZPR_SIMULATOR_IMAGE
export ZPR_SIMULATOR_PREBUILT_IMAGE=1
exec sh "$dashboard_stack" "$@"
