#!/usr/bin/env bash
# =============================================================================
# setup.sh — Topologia tre namespace: ns1 — ns2 (router) — ns3
# Reti: 10.0.1.0/24 (ns1 ↔ ns2) e 10.0.2.0/24 (ns2 ↔ ns3)
# Idempotente: se i namespace esistono già, li rimuove e ricrea.
# Eseguire con: sudo ./scripts/setup.sh
# =============================================================================

set -euo pipefail

# --- 0. Pulizia preventiva (idempotenza) -------------------------------------
for NS in ns1 ns2 ns3; do
  if ip netns list | grep -q "^${NS}"; then
    echo "[cleanup] Rimuovo namespace preesistente: $NS"
    ip netns del "$NS"
  fi
done

# I veth vengono rimossi automaticamente quando si elimina il namespace,
# ma per sicurezza rimuoviamo eventuali capi rimasti nel main namespace.
for VETH in veth-a veth-b; do
  if ip link show "$VETH" &>/dev/null; then
    echo "[cleanup] Rimuovo interfaccia preesistente: $VETH"
    ip link del "$VETH"
  fi
done

echo ""
echo "=== Creazione namespace ==="

# --- 1. Crea i tre namespace --------------------------------------------------
ip netns add ns1
ip netns add ns2
ip netns add ns3
echo "[OK] ns1, ns2, ns3 creati"

# --- 2. Crea le veth pair -----------------------------------------------------
# veth-a / veth-ns2a  →  collega ns1 a ns2 (rete 10.0.1.0/24)
ip link add veth-a type veth peer name veth-ns2a
# veth-b / veth-ns2b  →  collega ns2 a ns3 (rete 10.0.2.0/24)
ip link add veth-b type veth peer name veth-ns2b
echo "[OK] veth pair creati"

# --- 3. Sposta le interfacce nei namespace ------------------------------------
ip link set veth-a    netns ns1   # capo ns1
ip link set veth-ns2a netns ns2   # capo ns2, lato ns1
ip link set veth-ns2b netns ns2   # capo ns2, lato ns3
ip link set veth-b    netns ns3   # capo ns3
echo "[OK] Interfacce spostate nei namespace"

# --- 4. Configura ns1 ---------------------------------------------------------
ip netns exec ns1 ip link set lo up
ip netns exec ns1 ip link set veth-a up
ip netns exec ns1 ip addr add 10.0.1.10/24 dev veth-a
ip netns exec ns1 ip route add default via 10.0.1.1   # gateway = ns2 lato sinistro
echo "[OK] ns1 configurato: 10.0.1.10/24, gw 10.0.1.1"

# --- 5. Configura ns2 (router) ------------------------------------------------
ip netns exec ns2 ip link set lo up
ip netns exec ns2 ip link set veth-ns2a up
ip netns exec ns2 ip link set veth-ns2b up
ip netns exec ns2 ip addr add 10.0.1.1/24  dev veth-ns2a
ip netns exec ns2 ip addr add 10.0.2.1/24  dev veth-ns2b
# Abilita il forwarding IPv4 DENTRO il namespace ns2
ip netns exec ns2 sysctl -w net.ipv4.ip_forward=1 > /dev/null
echo "[OK] ns2 (router) configurato: 10.0.1.1/24 + 10.0.2.1/24, ip_forward=1"

# --- 6. Configura ns3 ---------------------------------------------------------
ip netns exec ns3 ip link set lo up
ip netns exec ns3 ip link set veth-b up
ip netns exec ns3 ip addr add 10.0.2.10/24 dev veth-b
ip netns exec ns3 ip route add default via 10.0.2.1   # gateway = ns2 lato destro
echo "[OK] ns3 configurato: 10.0.2.10/24, gw 10.0.2.1"

# --- 7. Riepilogo finale -------------------------------------------------------
echo ""
echo "=== Topologia attiva ==="
echo ""
echo "  ns1 (10.0.1.10) ──veth-a──veth-ns2a── ns2 ──veth-ns2b──veth-b── (10.0.2.10) ns3"
echo "                        10.0.1.0/24    router    10.0.2.0/24"
echo ""
echo "Verifica rapida:"
echo "  sudo ip netns exec ns1 ping -c 3 10.0.2.10"
echo "  sudo ip netns exec ns1 traceroute -n 10.0.2.10"
