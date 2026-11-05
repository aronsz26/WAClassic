#!/bin/bash
# build the bridge and install both services on debian-home
# (wa4s-bridge 8097/25567, wa4s-bridge2 8098/25568 + data2, same binary)
set -euo pipefail
cd "$(dirname "$0")/../bridge"
./patches/prepare.sh # patched meowcaller (see there)
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o build/wa4s-bridge .
ssh debian-home 'mkdir -p ~/wa4s/data ~/wa4s/data2 && chmod 700 ~/wa4s/data ~/wa4s/data2'
scp -q build/wa4s-bridge debian-home:wa4s/wa4s-bridge.new
scp -q ../deploy/wa4s-bridge.service ../deploy/wa4s-bridge2.service debian-home:wa4s/
ssh debian-home 'mv ~/wa4s/wa4s-bridge.new ~/wa4s/wa4s-bridge && sudo install -m 644 ~/wa4s/wa4s-bridge.service ~/wa4s/wa4s-bridge2.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now wa4s-bridge wa4s-bridge2 && sudo systemctl restart wa4s-bridge wa4s-bridge2 && sleep 2 && systemctl is-active wa4s-bridge wa4s-bridge2'
