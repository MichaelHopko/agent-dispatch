#!/usr/bin/env bash
set -eu
cd -- "$(dirname -- "$0")/.."
root=$PWD
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export MANAGER_CONFIG="$tmp/config" QUOTA_DISPATCH_CONFIG="$tmp/profiles" QUOTA_DISPATCH_STATE="$tmp/state"
export FLEET_RECEIPT="$tmp/log"
mkdir -p "$MANAGER_CONFIG"/{plugins,services} "$QUOTA_DISPATCH_CONFIG"
touch "$QUOTA_DISPATCH_CONFIG/order"
ln -s "$root/plugins/services" "$MANAGER_CONFIG/plugins/services"
cat > "$MANAGER_CONFIG/services/example.sh" <<'SERVICE'
#!/bin/sh
echo "$1" >> "$FLEET_RECEIPT"
SERVICE
chmod +x "$MANAGER_CONFIG/services/example.sh"
for lifecycle in start status recover watch; do ./manager "$lifecycle" </dev/null; done
test "$(cat "$FLEET_RECEIPT")" = "$(printf 'ensure-daemon\nstatus\nensure-daemon\nensure-daemon\n')"
export MANAGER_FLEET_PROFILE="$tmp/profile.sh"
printf '%s\n' 'status() { echo profile >> "$FLEET_RECEIPT"; }' > "$MANAGER_FLEET_PROFILE"
: > "$FLEET_RECEIPT"
./manager status
test "$(cat "$FLEET_RECEIPT")" = "$(printf 'profile\nstatus\n')"
unset MANAGER_FLEET_PROFILE
printf '#!/bin/sh\nexit 3\n' > "$MANAGER_CONFIG/services/failing.sh"
chmod +x "$MANAGER_CONFIG/services/failing.sh"
if ./manager watch; then exit 1; fi
