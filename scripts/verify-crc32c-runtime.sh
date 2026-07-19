#!/bin/sh

set -eu

mode="${1:-}"

case "$mode" in
    accelerated|fallback)
        ;;
    *)
        echo "usage: $0 accelerated|fallback" >&2
        exit 2
        ;;
esac

if ! grep -qw 'cryptomgr.panic_on_fail=1' /proc/cmdline; then
    echo "CRC32C validation requires cryptomgr.panic_on_fail=1" >&2
    exit 1
fi

driver_present() {
    awk -v expected="$1" '$1 == "driver" && $2 == ":" && $3 == expected { found = 1 } END { exit !found }' /proc/crypto
}

driver_priority() {
    awk -v RS='' -v expected="$1" '
        $0 ~ "driver[[:space:]]*:[[:space:]]*" expected {
            count = split($0, lines, "\n")
            for (i = 1; i <= count; i++) {
                if (lines[i] ~ /^priority[[:space:]]*:/) {
                    split(lines[i], fields, /[[:space:]]+/)
                    print fields[3]
                    exit
                }
            }
        }
    ' /proc/crypto
}

if ! driver_present crc32c-generic; then
    echo "crc32c-generic is not registered" >&2
    exit 1
fi

generic_priority="$(driver_priority crc32c-generic)"
if [ -z "$generic_priority" ]; then
    echo "crc32c-generic has no reported priority" >&2
    exit 1
fi

case "$mode" in
    accelerated)
        if ! grep -qm1 -w sse4_2 /proc/cpuinfo; then
            echo "accelerated validation requires the SSE4.2 guest feature" >&2
            exit 1
        fi
        if ! driver_present crc32c-intel; then
            echo "crc32c-intel is not registered" >&2
            exit 1
        fi
        intel_priority="$(driver_priority crc32c-intel)"
        if [ -z "$intel_priority" ] || [ "$intel_priority" -le "$generic_priority" ]; then
            echo "crc32c-intel does not outrank crc32c-generic" >&2
            exit 1
        fi
        echo "crc32c validation passed: crc32c-intel priority $intel_priority, crc32c-generic priority $generic_priority"
        ;;
    fallback)
        if grep -qm1 -w sse4_2 /proc/cpuinfo; then
            echo "fallback validation requires SSE4.2 to be hidden with clearcpuid=148" >&2
            exit 1
        fi
        if driver_present crc32c-intel; then
            echo "crc32c-intel registered without its required SSE4.2 feature" >&2
            exit 1
        fi
        echo "crc32c fallback passed: crc32c-generic priority $generic_priority"
        ;;
esac
