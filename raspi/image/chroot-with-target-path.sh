#!/bin/sh
set -eu

: "${DANCAM_CHROOT_EXE:?set DANCAM_CHROOT_EXE to the controller chroot executable}"
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

exec "$DANCAM_CHROOT_EXE" "$@"
