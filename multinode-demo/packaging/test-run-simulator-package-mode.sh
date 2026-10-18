#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
launcher="$script_dir/run-simulator-package-mode.sh"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/zpr-simulator-package-mode.XXXXXX")
support="$temporary/support"
stub="$support/scripts/dashboard-stack.sh"
missing_image_output="$temporary/missing-image.out"

cleanup() {
    rm -f "$stub" "$missing_image_output"
    rmdir "$support/scripts" "$support" "$temporary"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$support/scripts"
cat > "$stub" <<'EOF'
#!/bin/sh
printf 'mode=%s\nimage=%s\n' "$ZPR_SIMULATOR_PREBUILT_IMAGE" "$ZPR_SIMULATOR_IMAGE"
printf 'arg=<%s>\n' "$@"
EOF

output=$(
    ZPR_DASHBOARD_DIR="$support" \
        ZPR_SIMULATOR_IMAGE=zpr-simulator:paired-demo \
        ZPR_SIMULATOR_PREBUILT_IMAGE=0 \
        sh "$launcher" start
)
expected=$(printf 'mode=1\nimage=zpr-simulator:paired-demo\narg=<start>')
if [ "$output" != "$expected" ]; then
    printf 'unexpected package-mode handoff:\n%s\n' "$output" >&2
    exit 1
fi

if (
    unset ZPR_SIMULATOR_IMAGE
    export ZPR_DASHBOARD_DIR="$support"
    sh "$launcher" start
) > "$missing_image_output" 2>&1; then
    echo "missing Simulator image was unexpectedly accepted" >&2
    exit 1
fi
if ! grep -Fqx "ZPR_SIMULATOR_IMAGE must name the locally loaded Simulator image" "$missing_image_output"; then
    echo "missing Simulator image did not fail with the expected diagnostic" >&2
    exit 1
fi
