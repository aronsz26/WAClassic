#!/bin/bash
# opens the pairing page through a tunnel (localhost:18097 -> debian-home 8097)
# tools/pair.sh 8098 for the second bridge
# ctrl-c when the phone shows the new device
set -euo pipefail
PORT=${1:-8097}
ssh -N -o ExitOnForwardFailure=yes -L 1$PORT:127.0.0.1:$PORT debian-home &
TUNNEL=$!
trap 'kill $TUNNEL 2>/dev/null' EXIT
until nc -z 127.0.0.1 1$PORT 2>/dev/null; do sleep 0.3; done
open "http://localhost:1$PORT/pair"
wait $TUNNEL
