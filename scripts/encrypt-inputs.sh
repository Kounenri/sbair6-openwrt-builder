#!/bin/bash
# Encrypt the kit's local inputs into local.tar.age for the GitHub Actions build (docs/ci.md). The age identity
# stays on the computer that holds the unit: commit local.tar.age, never the identity.
#   scripts/encrypt-inputs.sh age1...          # recipient (public key) as the argument
#   AGE_RECIPIENT=age1... scripts/encrypt-inputs.sh
# local/ holds the Wi-Fi firmware (pull-fw) and, optionally, the modem userspace (pull-modem), local/files,
# local/diffconfig and local/kernel-patches; all of them are encrypted together.
set -euo pipefail
cd "$(dirname "$0")/.."
R=${1:-${AGE_RECIPIENT:-}}
if [ -z "$R" ]; then
	echo "usage: $0 AGE_RECIPIENT" >&2
	echo "  create a key pair with: age-keygen -o age-key.txt   (it prints 'public key: age1...')" >&2
	exit 2
fi
case $R in age1*) ;; *) echo "not an age recipient: $R" >&2; exit 2 ;; esac
command -v age >/dev/null || { echo "age not found: install it (apt install age)" >&2; exit 2; }
[ -d local/firmware/mt7996 ] || { echo "local/firmware/mt7996 is missing: run ./build.sh pull-fw [USER@]DEVICE first" >&2; exit 1; }
[ -n "$(ls -A local/firmware/mt7996)" ] || { echo "local/firmware/mt7996 is empty" >&2; exit 1; }
tar -czf - local | age -r "$R" -o local.tar.age
echo "wrote local.tar.age ($(du -h local.tar.age | cut -f1)); commit it and keep age-key.txt private"
