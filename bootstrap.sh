#!/bin/sh
# Install/claim Netdata Agent; leave the distro/static netdata.service running.
set -eu

CLAIM_TOKEN="${NETDATA_CLAIM_TOKEN:-}"
CLAIM_ROOMS="${NETDATA_CLAIM_ROOMS:-}"
CLAIM_URL="${NETDATA_CLAIM_URL:-https://app.netdata.cloud}"
KICKSTART_URL="${NETDATA_KICKSTART_URL:-https://get.netdata.cloud/kickstart.sh}"

if [ -z "$CLAIM_TOKEN" ]; then
  echo "NETDATA_CLAIM_TOKEN is required" >&2
  exit 1
fi

netdata_bin() {
  if command -v netdata >/dev/null 2>&1; then
    command -v netdata
  elif [ -x /opt/netdata/usr/sbin/netdata ]; then
    echo /opt/netdata/usr/sbin/netdata
  else
    return 1
  fi
}

claim_bin() {
  if [ -x /opt/netdata/bin/netdata-claim.sh ]; then
    echo /opt/netdata/bin/netdata-claim.sh
  elif [ -x /usr/sbin/netdata-claim.sh ]; then
    echo /usr/sbin/netdata-claim.sh
  elif command -v netdata-claim.sh >/dev/null 2>&1; then
    command -v netdata-claim.sh
  else
    return 1
  fi
}

# Vector listens on 127.0.0.1:8091 for POSTs to /impressions. Netdata's
# Couchbase collector defaults to GET http://127.0.0.1:8091/pools/default/buckets
# and floods Vector with MethodNotAllowed. Disable it on exchange hosts.
disable_couchbase_probe() {
  mkdir -p /etc/netdata/go.d
  cat > /etc/netdata/go.d/couchbase.conf <<'CONF'
# Disabled: port 8091 is Vector impressions_in, not Couchbase.
enabled: no
CONF
  # Also disable any stock/enable.conf job if present.
  if [ -d /etc/netdata/go.d.conf.d ] || [ -f /etc/netdata/go.d.conf ]; then
    :
  fi
  if [ -f /etc/netdata/go.d.conf ]; then
    # Best-effort: ensure modules.couchbase = no when file is YAML-ish
    if grep -q 'couchbase:' /etc/netdata/go.d.conf 2>/dev/null; then
      sed -i 's/^\([[:space:]]*\)couchbase:.*/\1couchbase: no/' /etc/netdata/go.d.conf || true
    else
      printf '\nmodules:\n  couchbase: no\n' >> /etc/netdata/go.d.conf || true
    fi
  else
    cat > /etc/netdata/go.d.conf <<'CONF'
# Managed by netdata-bootstrap (Barestack Deploy)
modules:
  couchbase: no
CONF
  fi
}

ensure_claimed() {
  claim="$(claim_bin)" || return 0
  echo "Claiming node to Netdata Cloud..."
  "$claim" -token="$CLAIM_TOKEN" -rooms="$CLAIM_ROOMS" -url="$CLAIM_URL" || true
}

ensure_running() {
  if systemctl list-unit-files netdata.service >/dev/null 2>&1; then
    systemctl enable netdata.service >/dev/null 2>&1 || true
    systemctl restart netdata.service
    systemctl is-active --quiet netdata.service
    return $?
  fi
  return 1
}

if ! netdata_bin >/dev/null 2>&1; then
  echo "Installing Netdata via kickstart (stable)..."
  curl -fsSL "$KICKSTART_URL" -o /tmp/netdata-kickstart.sh
  sh /tmp/netdata-kickstart.sh \
    --stable-channel \
    --non-interactive \
    --claim-token "$CLAIM_TOKEN" \
    --claim-rooms "$CLAIM_ROOMS" \
    --claim-url "$CLAIM_URL"
else
  echo "Netdata already present: $(netdata_bin)"
  ensure_claimed
fi

disable_couchbase_probe
echo "Disabled Netdata Couchbase probe on :8091 (reserved for Vector)."

if ! ensure_running; then
  echo "netdata.service failed to become active" >&2
  systemctl status netdata.service --no-pager -l || true
  exit 1
fi

echo "Netdata is active and claimed."
