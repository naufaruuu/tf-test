# Kubernetes BGP Load Balancing with Cilium and Ruijie Switch

A complete guide to understanding BGP-based load balancing for Kubernetes services.

---

## 🎯 What We're Achieving

**Goal:** Make `192.168.95.123:8080` accessible from anywhere, with traffic automatically distributed across 3 Kubernetes nodes.

**Problem:** Kubernetes pods have internal IPs (10.100.x.x). How do we expose them with an external IP that balances traffic?

**Solution:** Use BGP to advertise the LoadBalancer IP, and ECMP to distribute traffic!

---

## 📚 Part 1: Understanding BGP (Border Gateway Protocol)

### What is BGP?

BGP is how routers/switches tell each other: **"Hey, I know how to reach this IP address!"**

```
Cilium on master-0: "I can reach 192.168.95.123!"
Cilium on master-1: "I can reach 192.168.95.123!"
Cilium on master-2: "I can reach 192.168.95.123!"
         ↓
All 3 tell the Ruijie Switch via BGP
         ↓
Switch learns: "I can reach .123 via 3 different paths!"
```

### ASN (Autonomous System Number)

Think of ASN as a **"team number"** in BGP:
- **AS 64512** = Kubernetes nodes (all 3 nodes are on the same team)
- **AS 64513** = Ruijie switch (different team)

They're different teams, but they talk to each other (eBGP = external BGP between different teams).

---

## 🔧 Part 2: Ruijie Switch Configuration

### Complete Configuration

```bash
configure terminal
router bgp 64513
  bgp router-id 192.168.95.200
  bgp log-neighbor-changes
  bgp graceful-restart restart-time 120
  bgp graceful-restart stalepath-time 360
  bgp graceful-restart
  
  # Define neighbors (the 3 Kubernetes nodes)
  neighbor 192.168.95.210 remote-as 64512
  neighbor 192.168.95.210 description k8s-master-0
  neighbor 192.168.95.211 remote-as 64512
  neighbor 192.168.95.211 description k8s-master-1
  neighbor 192.168.95.212 remote-as 64512
  neighbor 192.168.95.212 description k8s-master-2
  
  # CRITICAL: Enable ECMP (at router bgp level, NOT in address-family)
  maximum-paths ebgp 10
  
  address-family ipv4
    neighbor 192.168.95.210 activate
    neighbor 192.168.95.211 activate
    neighbor 192.168.95.212 activate
    exit-address-family
exit
write memory
```

### What Each Line Does

| Command | What It Means |
|---------|---------------|
| `router bgp 64513` | "I am the Ruijie switch, my team number is 64513" |
| `bgp router-id 192.168.95.200` | "My identity/name in BGP is 192.168.95.200" |
| `neighbor 192.168.95.210 remote-as 64512` | "I will talk to 192.168.95.210 (master-0), who is on team 64512" |
| `neighbor 192.168.95.210 description k8s-master-0` | "Give this neighbor a friendly name" |
| `maximum-paths ebgp 10` | **KEY!** "If I learn the same route from multiple neighbors, use ALL of them for load balancing (ECMP)" |
| `neighbor 192.168.95.210 activate` | "Enable IPv4 route exchange with this neighbor" |

### What Happens on the Switch?

```
Switch receives BGP advertisements:
  master-0 says: "192.168.95.123/32 is reachable via me (192.168.95.210)"
  master-1 says: "192.168.95.123/32 is reachable via me (192.168.95.211)"
  master-2 says: "192.168.95.123/32 is reachable via me (192.168.95.212)"

Switch thinks: "I have 3 paths to the same destination!"
Switch creates ECMP: "I'll distribute traffic across all 3 paths (33% each)"
```

### Verification Commands

```bash
# Check BGP sessions
show ip bgp summary

# Check BGP routes
show ip bgp

# Check routing table
show ip route 192.168.95.123
```

**Expected Output:**
```
*m  192.168.95.123/32  192.168.95.212  
*>                     192.168.95.210  
*m                     192.168.95.211  
```
The `*m` flag means **multipath** (ECMP is working!)

---

## ☸️ Part 3: Cilium Configuration

Cilium has 4 main components for BGP. Let me explain each:

### 3.1: CiliumLoadBalancerIPPool

**Purpose:** Defines which IPs can be assigned to LoadBalancer services

```yaml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: bgp-pool
spec:
  blocks:
  - cidr: 192.168.95.123/32
```

**What it does:**
- When you create a Service with `type: LoadBalancer`, Kubernetes assigns an IP from this pool
- `/32` means ONLY this specific IP (not a range)

**Think of it as:** "Here's a pool of public IPs we can give to services"

---

### 3.2: CiliumBGPClusterConfig

**Purpose:** Defines BGP peering configuration for all nodes

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: cilium-bgp
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
  bgpInstances:
  - name: "instance-64512"
    localASN: 64512
    peers:
    - name: "ruijie-switch"
      peerASN: 64513
      peerAddress: "192.168.95.200"
      peerConfigRef:
        name: "cilium-peer"
```

**What it does:**
- **nodeSelector:** Apply this BGP config to all Linux nodes
- **localASN: 64512:** "We (Kubernetes nodes) are team 64512"
- **peerASN: 64513:** "We're talking to team 64513 (switch)"
- **peerAddress: 192.168.95.200:** "The switch's IP address"

**Think of it as:** "Every node should become a BGP router and talk to the switch at 192.168.95.200"

---

### 3.3: CiliumBGPPeerConfig

**Purpose:** Defines HOW to communicate with BGP peers (timers, restart behavior)

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: cilium-peer
spec:
  timers:
    holdTimeSeconds: 90
    keepAliveTimeSeconds: 30
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 120
  families:
  - afi: ipv4
    safi: unicast
    advertisements:
      matchLabels:
        advertise: "bgp"
```

**What it does:**
- **timers:** How often to check if BGP peer is still alive (every 30 seconds)
- **gracefulRestart:** If node restarts, keep routes for 120 seconds
- **families → advertisements:** "Advertise routes that have label `advertise: bgp`"

**Think of it as:** "Settings for HOW to talk BGP with the switch"

---

### 3.4: CiliumBGPAdvertisement

**Purpose:** Defines WHAT routes to advertise via BGP

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: bgp-services
  labels:
    advertise: "bgp"  # ← This matches the label in PeerConfig!
spec:
  advertisements:
  - advertisementType: "Service"
    service:
      addresses:
      - LoadBalancerIP
    selector:
      matchExpressions:
      - {key: bgp, operator: In, values: ["true"]}
```

**What it does:**
- **advertisementType: Service:** "Advertise Kubernetes Services"
- **addresses: LoadBalancerIP:** "Advertise the LoadBalancer IP (not ClusterIP)"
- **selector:** "Only advertise services with label `bgp: true`"

**Think of it as:** "WHAT to advertise - only LoadBalancer services with `bgp: true` label"

---

## 🔄 How They Work Together

```
Step 1: You create a Service
├─ type: LoadBalancer
├─ label: bgp: "true"
└─ Gets IP from CiliumLoadBalancerIPPool (192.168.95.123)

Step 2: CiliumBGPAdvertisement matches it
├─ "This service has bgp: true label!"
├─ "This service has LoadBalancerIP!"
└─ "I should advertise this!"

Step 3: CiliumBGPClusterConfig on each node
├─ "I'm AS 64512"
├─ "I'll talk to 192.168.95.200 (AS 64513)"
└─ Each node establishes BGP session with switch

Step 4: Each node advertises via BGP
├─ master-0 → "192.168.95.123/32 is reachable via me"
├─ master-1 → "192.168.95.123/32 is reachable via me"
└─ master-2 → "192.168.95.123/32 is reachable via me"

Step 5: Ruijie Switch receives all 3 advertisements
├─ "I learned the same route from 3 different neighbors!"
├─ "I have maximum-paths ebgp 10 configured"
└─ "I'll create ECMP with all 3 next-hops!"

Step 6: Traffic arrives at switch
├─ Destination: 192.168.95.123
├─ Switch checks routing table: "I have 3 paths via ECMP"
├─ Switch picks one based on hash (src IP, dst IP, ports)
└─ Forwards to one of the 3 nodes
```

---

## 🌐 Complete Network Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                    │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (Future: NAT/Port Forward)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│              Cisco FTD 1010 Firewall (192.168.95.1)                     │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  Static Route:                                                    │  │
│  │  192.168.95.123/32 → 192.168.95.200                              │  │
│  │                                                                   │  │
│  │  Packet Tracer Result: ✅ ALLOW                                   │  │
│  │  Next-hop: 192.168.95.200 (Ruijie Switch)                        │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ VLAN 1 (inside interface)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│          Ruijie Switch (192.168.95.200) - L3 Gateway                    │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  BGP AS 64513                                                     │  │
│  │  Router ID: 192.168.95.200                                        │  │
│  │                                                                   │  │
│  │  BGP Peers (AS 64512):                                            │  │
│  │    • 192.168.95.210 (master-0) - Established ✅                   │  │
│  │    • 192.168.95.211 (master-1) - Established ✅                   │  │
│  │    • 192.168.95.212 (master-2) - Established ✅                   │  │
│  │                                                                   │  │
│  │  Learned Route via BGP:                                           │  │
│  │    *m  192.168.95.123/32                                          │  │
│  │       → 192.168.95.210  (33%)  ┐                                  │  │
│  │       → 192.168.95.211  (33%)  │ ECMP Load Balancing              │  │
│  │       → 192.168.95.212  (33%)  ┘                                  │  │
│  │                                                                   │  │
│  │  ECMP Config: maximum-paths ebgp 10                               │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                    │                 │                 │
                    │ 33%             │ 33%             │ 33%
                    ▼                 ▼                 ▼
        ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
        │  master-0    │  │  master-1    │  │  master-2    │
        │ .95.210      │  │ .95.211      │  │ .95.212      │
        └──────────────┘  └──────────────┘  └──────────────┘
                │                 │                 │
                └─────────────────┴─────────────────┘
                                  │
                  ┌───────────────┴────────────────┐
                  │   Kubernetes Cluster           │
                  │   Talos Linux + Cilium CNI     │
                  └────────────────────────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
        ▼                         ▼                         ▼
┌──────────────┐          ┌──────────────┐          ┌──────────────┐
│   Pod 1      │          │   Pod 2      │          │   Pod 3      │
│ 10.100.1.45  │          │ 10.100.2.91  │          │ 10.100.0.95  │
│              │          │              │          │              │
│ Node: m-0    │          │ Node: m-1    │          │ Node: m-2    │
└──────────────┘          └──────────────┘          └──────────────┘
```

---

## 🚀 Traffic Flow Example

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         PACKET FLOW                                      │
└─────────────────────────────────────────────────────────────────────────┘

Step 1: Client sends request
┌──────────────┐
│  Client      │  curl 192.168.95.123:8080
│ 192.168.x.x  │  
└──────────────┘
        │
        ▼
┌──────────────┐
│   Firewall   │  Static route: 192.168.95.123 → 192.168.95.200
│ 192.168.95.1 │  Packet-tracer: ALLOW ✅
└──────────────┘
        │
        ▼
┌──────────────┐
│    Switch    │  ECMP decision (hash-based):
│ 192.168.95.  │  • Flow 1 → master-0
│     200      │  • Flow 2 → master-1  
└──────────────┘  • Flow 3 → master-2
        │
        │ (Random distribution per flow)
        ▼
┌──────────────┐
│  master-1    │  externalTrafficPolicy: Local
│              │  Cilium forwards to local pod
└──────────────┘
        │
        ▼
┌──────────────┐
│   Pod on     │  HTTP Response:
│   master-1   │  "BGP routed to node: master-1"
│ 10.100.2.91  │  "Pod IP: 10.100.2.91"
└──────────────┘
```

---

## 🧪 Example Service Configuration

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lb-test
  namespace: kube-system
spec:
  replicas: 3
  selector:
    matchLabels:
      app: lb-test
  template:
    metadata:
      labels:
        app: lb-test
    spec:
      containers:
      - name: web
        image: python:3-alpine
        command: ["python3", "-c"]
        args:
        - |
          import http.server, os
          class Handler(http.server.BaseHTTPRequestHandler):
              def do_GET(self):
                  self.send_response(200)
                  self.send_header('Content-type', 'text/plain')
                  self.end_headers()
                  self.wfile.write(f"BGP routed to node: {os.environ['NODE_NAME']}\nPod IP: {os.environ['POD_IP']}\n".encode())
          http.server.HTTPServer(('', 8080), Handler).serve_forever()
        ports:
        - containerPort: 8080
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
---
apiVersion: v1
kind: Service
metadata:
  name: lb-test
  namespace: kube-system
  labels:
    bgp: "true"  # ← IMPORTANT: Tells Cilium to advertise this via BGP
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local  # ← IMPORTANT: Shows which node received traffic
  selector:
    app: lb-test
  ports:
  - port: 8080
    targetPort: 8080
```

---

## ✅ Verification Commands

### On Kubernetes Nodes

```bash
# Check BGP peering status
cilium bgp peers

# Expected output:
# Node         Local AS   Peer AS   Peer Address      Session State   Uptime      Family         Received   Advertised
# master-0     64512      64513     192.168.95.200    established     2h30m       ipv4/unicast   0          2
```

### On Ruijie Switch

```bash
# Check BGP neighbors
show ip bgp summary

# Check BGP routes
show ip bgp

# Check routing table
show ip route 192.168.95.123

# Expected output should show 3 routing descriptor blocks (ECMP)
```

### Testing Load Balancing

```bash
# Test multiple requests
for i in {1..20}; do curl 192.168.95.123:8080; sleep 0.5; done

# Expected output (random distribution):
# BGP routed to node: master-0, Pod IP: 10.100.1.45
# BGP routed to node: master-2, Pod IP: 10.100.0.95
# BGP routed to node: master-1, Pod IP: 10.100.2.91
# BGP routed to node: master-0, Pod IP: 10.100.1.45
# ...
```

---

## 📝 Summary in Simple Terms

**Cilium:**
- "I have a pool of IPs I can assign (192.168.95.123)"
- "I'll tell the switch about these IPs using BGP"
- "I'm team 64512, switch is team 64513"
- "All 3 nodes will advertise the same IP"

**Ruijie Switch:**
- "I'm team 64513"
- "I'll listen to team 64512 (the 3 nodes)"
- "When all 3 nodes tell me about the same IP, I'll use ECMP"
- "I'll distribute traffic across all 3 paths"

**Result:**
Traffic to `192.168.95.123` gets load balanced across 3 nodes automatically! 🎉

---

## 🔍 Key Concepts

| Concept | What It Means |
|---------|---------------|
| **BGP (Border Gateway Protocol)** | Protocol for routers to share routing information |
| **ASN (Autonomous System Number)** | Team ID for BGP (we use 64512 for K8s, 64513 for switch) |
| **eBGP (External BGP)** | BGP between different ASNs (teams) |
| **ECMP (Equal-Cost Multi-Path)** | Load balancing across multiple equal routes |
| **LoadBalancer IP** | Virtual IP assigned to Kubernetes service |
| **externalTrafficPolicy: Local** | Don't forward traffic to other nodes, keep it local |
| **Graceful Restart** | Keep routes temporarily if BGP peer restarts |

---

## ⚠️ Important Notes

1. **ASN numbers don't need to match any "real" internet ASNs** - we use private range (64512-65534)
2. **maximum-paths MUST be at router bgp level**, not in address-family
3. **All 3 nodes advertise the SAME IP** - this is intentional for ECMP
4. **externalTrafficPolicy: Local** prevents cross-node forwarding
5. **Static route on firewall** needed because LoadBalancer IP is in same subnet

---

## 🎓 What You Learned

✅ How BGP works for advertising routes  
✅ How ECMP provides load balancing  
✅ How Cilium integrates with external routers  
✅ How to configure Ruijie switch for BGP  
✅ How Kubernetes LoadBalancer services work  
✅ How to verify BGP peering and routing  

---