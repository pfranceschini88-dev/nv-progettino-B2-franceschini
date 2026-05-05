#!/usr/bin/env bash
# =============================================================================
# teardown.sh — Rimuove tutti i namespace e le interfacce creati da setup.sh
# Eseguire con: sudo ./scripts/teardown.sh
# =============================================================================

set -euo pipefail

echo "=== Teardown topologia ns1/ns2/ns3 ==="

# Rimuovere un namespace elimina automaticamente tutte le interfacce
# che vivono dentro di esso (inclusi i capi veth).
for NS in ns1 ns2 ns3; do
  if ip netns list | grep -q "^${NS}"; then
    ip netns del "$NS"
    echo "[OK] Namespace $NS rimosso"
  else
    echo "[skip] Namespace $NS non trovato (già rimosso?)"
  fi
done

# Sicurezza: rimuovi eventuali veth orfani rimasti nel main namespace
for VETH in veth-a veth-b veth-ns2a veth-ns2b; do
  if ip link show "$VETH" &>/dev/null; then
    ip link del "$VETH"
    echo "[OK] Interfaccia orfana $VETH rimossa"
  fi
done

echo ""
echo "=== Stato finale ==="
echo "Namespace rimasti:"
ip netns list || echo "  (nessuno)"
