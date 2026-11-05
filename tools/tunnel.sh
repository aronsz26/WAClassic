#!/bin/bash
# forward the bridges (debian-home 8097/8098) to mac:8097/8098 for the phones.
# ssh only, nothing new opens on the server. started by de.aronsz.wa4s-tunnel
exec /usr/bin/ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -L 0.0.0.0:8097:127.0.0.1:8097 -L 0.0.0.0:8098:127.0.0.1:8098 debian-home
