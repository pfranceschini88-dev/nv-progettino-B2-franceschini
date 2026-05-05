# Routing tra namespace Linux con veth pair

**Autore:** <!-- Il tuo nome -->
**Codice variante:** B1
**Repo:** https://github.com/<!-- tuo-username -->/nv-progettino-B1-<!-- tuocognome -->

---

## 1. Obiettivo

Il progettino costruisce a mano, usando esclusivamente primitive del kernel Linux (`ip netns`, `veth pair`, `ip route`, `sysctl`), una piccola topologia a tre nodi in cui due reti `/24` distinte comunicano tra loro grazie a un namespace centrale che funge da router. L'obiettivo è capire cosa accade *sotto al cofano* quando Docker crea bridge di rete e collega container: tutto il meccanismo di forwarding e routing che Docker automatizza, qui viene configurato esplicitamente.

---

## 2. Architettura

```
 ns1                    ns2  (router)                ns3
 10.0.1.10/24          10.0.1.1/24  10.0.2.1/24     10.0.2.10/24
    │                       │              │               │
    └──── veth-a ───── veth-ns2a      veth-ns2b ──── veth-b ────┘
          ←── rete 10.0.1.0/24 ───→  ←─── rete 10.0.2.0/24 ───→
```

| Componente | Ruolo | Interfaccia | Indirizzo |
|---|---|---|---|
| `ns1` | host sorgente | `veth-a` | `10.0.1.10/24` |
| `ns2` | router (ip_forward=1) | `veth-ns2a` | `10.0.1.1/24` |
| `ns2` | router (ip_forward=1) | `veth-ns2b` | `10.0.2.1/24` |
| `ns3` | host destinazione | `veth-b` | `10.0.2.10/24` |

Ogni **veth pair** è un cavo virtuale bidirezionale: i due capi sono sempre creati insieme e spostati nei namespace di interesse. `ns2` ha `net.ipv4.ip_forward=1` attivo al suo interno, il che lo trasforma da host a router: il kernel non droppa più i pacchetti non destinati a sé, ma li instrada verso l'interfaccia corretta.

---

## 3. Prerequisiti

- **WSL2** con Ubuntu 24.04 (o qualsiasi Linux con kernel ≥ 5.15)
- Pacchetti: `iproute2`, `iputils-ping`, `traceroute`, `tcpdump`

```bash
sudo apt update && sudo apt install -y iproute2 iputils-ping traceroute tcpdump
```

- Privilegi `sudo` (necessari per operare sui namespace di rete)

---

## 4. Come riprodurre passo-passo

### 4.1 Clona il repo e dai i permessi

```bash
git clone https://github.com/<tuo-username>/nv-progettino-B1-<cognome>.git
cd nv-progettino-B1-<cognome>
chmod +x scripts/setup.sh scripts/teardown.sh
```

### 4.2 Avvia la topologia

```bash
sudo ./scripts/setup.sh
```

Output atteso:

```
=== Creazione namespace ===
[OK] ns1, ns2, ns3 creati
[OK] veth pair creati
[OK] Interfacce spostate nei namespace
[OK] ns1 configurato: 10.0.1.10/24, gw 10.0.1.1
[OK] ns2 (router) configurato: 10.0.1.1/24 + 10.0.2.1/24, ip_forward=1
[OK] ns3 configurato: 10.0.2.10/24, gw 10.0.2.1

=== Topologia attiva ===
```

### 4.3 Verifica namespace e indirizzi

```bash
# Lista dei tre namespace
ip netns list
# → ns1  ns2  ns3

# Interfacce e IP di ciascun namespace
sudo ip netns exec ns1 ip addr
sudo ip netns exec ns2 ip addr
sudo ip netns exec ns3 ip addr

# Tabelle di routing
sudo ip netns exec ns1 ip route
# → default via 10.0.1.1 dev veth-a
# → 10.0.1.0/24 dev veth-a proto kernel scope link src 10.0.1.10

sudo ip netns exec ns2 ip route
# → 10.0.1.0/24 dev veth-ns2a proto kernel scope link src 10.0.1.1
# → 10.0.2.0/24 dev veth-ns2b proto kernel scope link src 10.0.2.1

sudo ip netns exec ns3 ip route
# → default via 10.0.2.1 dev veth-b
# → 10.0.2.0/24 dev veth-b proto kernel scope link src 10.0.2.10
```

---

## 5. Verifica del funzionamento

### 5.1 Ping end-to-end (ns1 → ns3)

```bash
sudo ip netns exec ns1 ping -c 3 10.0.2.10
```

Output atteso:

```
PING 10.0.2.10 (10.0.2.10) 56(84) bytes of data.
64 bytes from 10.0.2.10: icmp_seq=1 ttl=63 time=0.XX ms
64 bytes from 10.0.2.10: icmp_seq=2 ttl=63 time=0.XX ms
64 bytes from 10.0.2.10: icmp_seq=3 ttl=63 time=0.XX ms

--- 10.0.2.10 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss
```

Il TTL è 63 (e non 64) perché il pacchetto attraversa un router (`ns2`), che decrementa il campo TTL di 1.

### 5.2 Traceroute (mostra il salto intermedio)

```bash
sudo ip netns exec ns1 traceroute -n 10.0.2.10
```

Output atteso:

```
traceroute to 10.0.2.10 (10.0.2.10), 30 hops max
 1  10.0.1.1   0.XXX ms   # → ns2, interfaccia veth-ns2a
 2  10.0.2.10  0.XXX ms   # → ns3
```

L'hop 1 (`10.0.1.1`) è `ns2`: conferma che il pacchetto passa fisicamente per il router prima di raggiungere la destinazione.

### 5.3 Cattura tcpdump sul router

In un terminale separato, avvia la cattura sull'interfaccia di ingresso del router:

```bash
sudo ip netns exec ns2 tcpdump -i veth-ns2a -n icmp
```

Poi in un altro terminale esegui il ping:

```bash
sudo ip netns exec ns1 ping -c 3 10.0.2.10
```

La cattura mostra i pacchetti ICMP `echo request` e `echo reply` che transitano per `ns2`.

---

## 6. Esperimenti di ablazione

### 6.1 Ablazione 1 — Disabilita ip_forward in ns2

```bash
# Disabilita il forwarding
sudo ip netns exec ns2 sysctl -w net.ipv4.ip_forward=0

# Il ping ora fallisce: ns2 riceve il pacchetto ma lo droppa
sudo ip netns exec ns1 ping -c 3 10.0.2.10
# → 100% packet loss

# Riabilita
sudo ip netns exec ns2 sysctl -w net.ipv4.ip_forward=1
sudo ip netns exec ns1 ping -c 3 10.0.2.10
# → funziona di nuovo
```

**Spiegazione:** `ip_forward=0` dice al kernel di comportarsi da *host* puro: scarta qualsiasi pacchetto il cui indirizzo di destinazione non sia uno degli indirizzi locali del namespace. Il bit `ip_forward` è esattamente la differenza semantica tra host e router a livello kernel.

### 6.2 Ablazione 2 — Rimuovi la default route da ns3

```bash
# Lancia tcpdump su ns3 in background per vedere i pacchetti in arrivo
sudo ip netns exec ns3 tcpdump -i veth-b -n icmp &

# Rimuovi la default route da ns3
sudo ip netns exec ns3 ip route del default

# Ping da ns1: le request arrivano a ns3 (visibili in tcpdump)
# ma le reply non sanno come tornare → timeout
sudo ip netns exec ns1 ping -c 3 10.0.2.10
# → Request timeout for icmp_seq 1 (oppure 100% packet loss)

# Ripristina
sudo ip netns exec ns3 ip route add default via 10.0.2.1
kill %1   # ferma tcpdump
```

**Spiegazione:** `ns3` riceve correttamente l'`echo request` (il percorso *andata* è integro), ma non sa dove mandare l'`echo reply`: senza default route, il kernel di `ns3` non trova una rotta per `10.0.1.10` e droppa il pacchetto. Il mittente vede un timeout asimmetrico. Questo dimostra che la connettività IP è **bidirezionale**: entrambe le direzioni devono essere routable.

---

## 7. Teardown

```bash
sudo ./scripts/teardown.sh
ip netns list   # output vuoto: tutti i namespace sono stati rimossi
```

---

## 8. Riflessioni e punti aperti

**Cosa ho imparato facendolo.** Il concetto di namespace di rete come "stack TCP/IP isolato" diventa molto concreto quando si vede che ogni `ip route` va eseguito con `ip netns exec nsX`: senza quello prefisso, il comando agisce sul main namespace, non su quello di interesse. Un errore facile all'inizio.

**ip_forward è il bit che distingue host da router.** Senza di esso, un namespace con due interfacce è solo un host multihomed che non condivide traffico tra le sue reti. Con quel bit a 1, diventa un router a tutti gli effetti, senza software aggiuntivo.

**Le veth pair come "cavo virtuale".** La coppia viene creata nel main namespace e poi i due capi vengono "spostati" (non copiati) nei namespace destinatari con `ip link set ... netns`. Dopo lo spostamento, il main namespace non vede più quell'interfaccia: appartiene al namespace di destinazione.

**Connettività asimmetrica.** L'ablazione 2 mostra bene che il ping funziona solo se *entrambe* le direzioni sono routable. La route di ritorno è spesso l'elemento dimenticato in configurazioni reali.

**Domande aperte:**

- Se al posto di veth dirette mettessi un bridge Linux (`ip link add br0 type bridge`), cosa cambierebbe? Il bridge lavora a livello 2 (MAC), mentre qui lavoriamo a livello 3 (IP): con un bridge, più namespace potrebbero condividere lo stesso dominio di broadcast, esattamente come fa Docker con la rete `bridge` di default.
- Aggiungere un quarto namespace `ns4` con `10.0.3.0/24` collegato a `ns2` richiederebbe solo un nuovo veth pair e un nuovo indirizzo su `ns2`: le route delle reti connesse vengono create automaticamente dal kernel quando si assegna un IP, quindi non servirebbero route statiche aggiuntive in `ns2` (solo nei nuovi host verso `ns2` come gateway).
- Per far uscire `ns1` su Internet tramite `ns2` servirebbe NAT (`iptables -t nat -A POSTROUTING -o <iface-esterna> -j MASQUERADE`), esattamente come fa il router di casa.

---

## 9. Riferimenti

- `ip-netns(8)` — man page ufficiale: `man ip-netns`
- `ip-link(8)`, `ip-address(8)`, `ip-route(8)` — man page iproute2
- Slide hands-on del corso: `itp-2526-HandsOn.pptx`
- Guida masquerading nel main namespace: `Namespace_Masquerading_Guida.md`
- Kernel docs — IP Sysctl: https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html
