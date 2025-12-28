# Dell ME5224 Storage Integration Guide
## Complete Tutorial for Proxmox Cluster and Kubernetes

**Last Updated:** December 2025  
**Target Hardware:** Dell PowerVault ME5224 (or similar enterprise SAN)  
**Hypervisor:** Proxmox VE 8.x  
**Kubernetes:** Any CNI-compatible cluster on Proxmox VMs

---

## 📋 Table of Contents

- [Overview](#overview)
- [Storage Fundamentals & Theory](#storage-fundamentals--theory)
  - [Storage Array Concepts](#️-storage-array-concepts)
  - [iSCSI Protocol](#-iscsi-protocol)
  - [Multipath](#-multipath)
  - [LVM (Logical Volume Manager)](#-lvm-logical-volume-manager)
  - [CSI (Container Storage Interface)](#️-csi-container-storage-interface)
  - [Proxmox Storage Concepts](#️-proxmox-storage-concepts)
- [Architecture Comparison](#architecture-comparison)
- [Prerequisites](#prerequisites)
- [PART 1: VM-FOCUSED STORAGE](#part-1-vm-focused-storage)
  - [iSCSI Multipath LVM for Proxmox](#iscsi-multipath-lvm-for-proxmox)
- [PART 2: KUBERNETES-FOCUSED STORAGE](#part-2-kubernetes-focused-storage)
  - [Option A: Seagate Exos X CSI](#option-a-seagate-exos-x-csi)
  - [Option B: Proxmox CSI Plugin](#option-b-proxmox-csi-plugin)
- [Decision Matrix](#decision-matrix)
- [Performance Tuning](#performance-tuning)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Overview

This guide covers three distinct approaches to using Dell ME5224 (PowerVault) storage:

### 🖥️ **VM-Focused Approach**
Use ME5224 as shared storage for **traditional Proxmox VMs and containers** with high availability and live migration capabilities.

**Use Case:** General-purpose VMs, Windows VMs, file servers, applications that need HA

### ☸️ **Kubernetes-Focused Approaches**
Use ME5224 to provide **dynamic persistent volumes** for Kubernetes workloads.

**Option A - Seagate Exos X CSI:** Direct SAN integration (K8s talks to ME5224)  
**Option B - Proxmox CSI:** Proxmox-mediated storage (K8s talks to Proxmox)

---

## Storage Fundamentals & Theory

Before diving into implementation, let's understand the core concepts. This section explains the building blocks used throughout this guide.

---

### 🗄️ Storage Array Concepts

#### What is a SAN (Storage Area Network)?

A **SAN** is a dedicated high-speed network that provides block-level storage to servers. Unlike NAS (Network Attached Storage) which provides file-level access, SAN provides raw block devices.

```
Traditional Storage (DAS):
┌──────────┐
│  Server  │
└────┬─────┘
     │ Internal cable
     ↓
┌──────────┐
│   Disk   │
└──────────┘

SAN Storage:
┌──────────┐      ┌──────────┐
│ Server 1 │      │ Server 2 │
└────┬─────┘      └────┬─────┘
     │                 │
     └────────┬────────┘
              │ Network
              ↓
      ┌───────────────┐
      │  SAN Storage  │
      │  (ME5224)     │
      └───────────────┘
```

**Benefits:**
- Multiple servers access same storage
- Centralized management
- Redundancy and high availability
- Better utilization

---

#### What is a LUN (Logical Unit Number)?

A **LUN** is a logical storage volume created on the SAN that appears to servers as a physical disk.

**Think of it like:**
- Physical disks in SAN = Raw ingredients
- RAID pool = Mixed ingredients
- LUN = A slice of cake you can serve

```
┌─────────────────────────────────────┐
│         DELL ME5224 SAN             │
│                                     │
│  Physical Disks (24× 2.5" drives)  │
│  ┌───┬───┬───┬───┬───┬───┬───┐     │
│  │ ● │ ● │ ● │ ● │ ● │ ● │ ● │ ... │
│  └───┴───┴───┴───┴───┴───┴───┘     │
│           ↓ RAID-6                  │
│  ┌─────────────────────────────┐    │
│  │    Storage Pool (10TB)      │    │
│  └─────────────────────────────┘    │
│           ↓ Create LUNs             │
│  ┌────────┐ ┌────────┐ ┌────────┐  │
│  │ LUN 0  │ │ LUN 1  │ │ LUN 2  │  │
│  │ 1TB    │ │ 2TB    │ │ 500GB  │  │
│  └────────┘ └────────┘ └────────┘  │
└─────────────────────────────────────┘
         │         │         │
         └─────────┴─────────┘
              Mapped to servers
```

**Key Points:**
- One LUN = One virtual disk
- Can create multiple LUNs from one pool
- Each LUN can be mapped to specific servers
- Appears as `/dev/sdb`, `/dev/sdc`, etc. on Linux

---

#### Thin vs Thick Provisioning

**Thick Provisioning:**
- Allocate full space immediately
- 100GB LUN = 100GB used on SAN right away
- Guaranteed space
- Slightly better performance

**Thin Provisioning:**
- Allocate space on-demand
- 100GB LUN = Only use what's written
- Can overprovision (create 500GB LUNs from 200GB pool)
- Must monitor actual usage

```
Thick Provisioning:
┌─────────────────────────────┐
│  SAN Storage Pool (1TB)     │
├─────────────────────────────┤
│ ███████████ LUN 1 (500GB)   │ ← 500GB reserved
│ ████ LUN 2 (200GB)          │ ← 200GB reserved
│ ░░░░░ Free (300GB)          │
└─────────────────────────────┘

Thin Provisioning:
┌─────────────────────────────┐
│  SAN Storage Pool (1TB)     │
├─────────────────────────────┤
│ ███ LUN 1 (500GB allocated) │ ← Only 150GB actually used
│ ██ LUN 2 (200GB allocated)  │ ← Only 100GB actually used
│ █ LUN 3 (500GB allocated)   │ ← Only 50GB actually used
│ ░░░░░░░░ Free (700GB)       │ ← Available for more writes
└─────────────────────────────┘
  ↑ Can allocate 1.2TB from 1TB pool!
```

---

### 🌐 iSCSI Protocol

#### What is iSCSI?

**iSCSI** (Internet Small Computer Systems Interface) is a protocol that transports SCSI commands over TCP/IP networks, allowing servers to access storage over Ethernet.

**Simple analogy:** Like SATA/SAS over network cables instead of direct cables.

```
Traditional SCSI/SAS:
Server ←──[Cable]──→ Disk

iSCSI:
Server ←──[Ethernet Network]──→ SAN Storage
```

---

#### iSCSI Components

**1. iSCSI Target** (Storage side - ME5224)
- The storage array that provides storage
- Listens on port 3260
- Has an IQN (iSCSI Qualified Name)

**2. iSCSI Initiator** (Server side - Proxmox)
- The client that consumes storage
- Connects to target
- Also has an IQN

**3. IQN (iSCSI Qualified Name)**
- Unique identifier for iSCSI devices
- Format: `iqn.YYYY-MM.domain:identifier`
- Example: `iqn.2024-12.com.dell:me5224-storage`

```
┌─────────────────────────────────────────────┐
│  iSCSI Target (ME5224)                      │
│  IQN: iqn.2024-12.com.dell:me5224           │
│  IP: 192.168.10.11                          │
│  Port: 3260                                 │
│                                             │
│  LUNs Available:                            │
│  - LUN 0: 1TB disk                          │
│  - LUN 1: 500GB disk                        │
└─────────────────────────────────────────────┘
                    ↑
                    │ TCP/IP (port 3260)
                    │
┌─────────────────────────────────────────────┐
│  iSCSI Initiator (Proxmox Node)             │
│  IQN: iqn.2024-12.com.company:proxmox1      │
│  IP: 192.168.10.50                          │
│                                             │
│  Discovers → Logs in → Sees /dev/sdb        │
└─────────────────────────────────────────────┘
```

---

#### iSCSI Discovery and Login

**Discovery:** Find available targets
```bash
iscsiadm -m discovery -t st -p 192.168.10.11
# Returns: List of targets and their portals
```

**Login:** Connect to target
```bash
iscsiadm -m node -L all
# Creates block device: /dev/sdb
```

**Session:** Active connection
```bash
iscsiadm -m session
# Shows: Active iSCSI connections
```

---

### 🔀 Multipath

#### Why Multipath?

**Problem:** Single network path = Single point of failure

**Solution:** Multiple paths to same storage

```
WITHOUT Multipath:
┌──────────┐
│ Proxmox  │
└────┬─────┘
     │ One cable
     ↓
┌──────────┐
│ ME5224   │
└──────────┘
❌ Cable fails = Storage lost!

WITH Multipath:
┌──────────┐
│ Proxmox  │
└─┬──┬──┬──┘
  │  │  │  │ Four paths
  ↓  ↓  ↓  ↓
┌──────────┐
│ ME5224   │
│ 2 Ctrl   │
└──────────┘
✅ One path fails = Other 3 continue!
```

---

#### How Multipath Works

**Without multipath:**
```
OS sees 4 separate disks:
/dev/sdd - 1TB (Controller A, Port 1)
/dev/sde - 1TB (Controller A, Port 2)
/dev/sdf - 1TB (Controller B, Port 1)
/dev/sdg - 1TB (Controller B, Port 2)

Problem: Writing to /dev/sdd ≠ writing to /dev/sde
         This causes DATA CORRUPTION!
```

**With multipath:**
```
Multipath combines into ONE device:
/dev/mapper/mpatha - 1TB
    ├── /dev/sdd (path 1) ✅
    ├── /dev/sde (path 2) ✅
    ├── /dev/sdf (path 3) ✅
    └── /dev/sdg (path 4) ✅

Benefit: Write to mpatha → multipath handles distribution
         All paths see the same data!
```

---

#### Multipath Path Selection Policies

**1. Round-Robin** (Load Balancing)
```
I/O Request 1 → Path A
I/O Request 2 → Path B
I/O Request 3 → Path C
I/O Request 4 → Path D
I/O Request 5 → Path A (cycle repeats)

✅ Best performance
✅ Even load distribution
```

**2. Failover** (Active/Passive)
```
Primary:   Path A ← All I/O goes here
Standby:   Path B
Standby:   Path C
Standby:   Path D

If Path A fails → Switch to Path B

⚠️ Lower performance
✅ Simpler, more conservative
```

---

#### ALUA (Asymmetric Logical Unit Access)

ALUA optimizes paths based on controller ownership.

```
┌─────────────────────────────────────────┐
│           ME5224 SAN                    │
│                                         │
│  Controller A (OWNER)                   │
│  ├── Port 1: 192.168.10.11  ⭐ Optimized
│  └── Port 2: 192.168.10.12  ⭐ Optimized
│                                         │
│  Controller B (NON-OWNER)               │
│  ├── Port 1: 192.168.10.13  ⚠️ Non-optimized
│  └── Port 2: 192.168.10.14  ⚠️ Non-optimized
└─────────────────────────────────────────┘

Optimized Path:
  Request → Controller A → Direct to disk
  Latency: 0.5ms ✅

Non-Optimized Path:
  Request → Controller B → Forward to A → Disk
  Latency: 1.5ms ⚠️

Multipath prefers optimized paths!
```

---

### 📦 LVM (Logical Volume Manager)

#### LVM Overview

LVM provides **flexible disk management** by abstracting physical storage into logical volumes.

**Traditional Partitioning:**
```
/dev/sdb
├── /dev/sdb1 - 500GB - Can't resize easily! ❌
├── /dev/sdb2 - 300GB - Fixed size! ❌
└── /dev/sdb3 - 200GB - Wasted if not used! ❌
```

**LVM Approach:**
```
Physical Disks → Volume Group (Pool) → Logical Volumes (Flexible)

Can resize, extend, reduce anytime! ✅
```

---

#### LVM Components

```
┌─────────────────────────────────────────────────────┐
│                    LVM STACK                        │
│                                                     │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐    │
│  │     LV     │  │     LV     │  │     LV     │    │ ← Logical Volumes
│  │  (vm-disk) │  │  (data)    │  │  (backup)  │    │   What you use
│  │   50GB     │  │   100GB    │  │   30GB     │    │
│  └──────┬─────┘  └──────┬─────┘  └──────┬─────┘    │
│         └────────────────┴────────────────┘         │
│                        │                            │
│              ┌─────────▼─────────┐                  │
│              │   Volume Group    │                  │ ← VG (Storage Pool)
│              │   "san-storage"   │                  │   Combines PVs
│              │      1TB          │                  │
│              └─────────┬─────────┘                  │
│                        │                            │
│         ┌──────────────┴──────────────┐             │
│         │                             │             │
│  ┌──────▼──────┐              ┌───────▼──────┐     │
│  │     PV      │              │      PV      │     │ ← Physical Volumes
│  │ /dev/sdb    │              │ /dev/sdc     │     │   Initialized disks
│  │   500GB     │              │   500GB      │     │
│  └─────────────┘              └──────────────┘     │
└─────────────────────────────────────────────────────┘
```

---

#### LVM Terminology

**1. Physical Volume (PV)**
- Raw disk or partition initialized for LVM
- Command: `pvcreate /dev/sdb`
- Example: `/dev/sdb`, `/dev/mapper/mpatha`

**2. Volume Group (VG)**
- Pool of storage from one or more PVs
- Command: `vgcreate san-storage /dev/sdb /dev/sdc`
- Like a "storage wallet" you can draw from

**3. Logical Volume (LV)**
- Virtual partition created from VG
- Command: `lvcreate -L 50G -n vm-disk san-storage`
- What you actually format and use

**4. Physical Extent (PE)**
- Smallest unit of space in VG
- Default: 4MB chunks
- LVs are made of PEs

**5. Thin Pool**
- Special LV that provides thin provisioning
- Command: `lvcreate -L 100G -T vg-name/pool-name`
- Allows overprovisioning

---

#### Shared LVM (HA) vs LVM-Thin

**Regular LVM (Thick Volumes) - Cluster-Safe ✅**
```
┌────────────────────────────────────────┐
│  Volume Group: san-storage             │
│  Total: 1TB                            │
│                                        │
│  Thick Volumes:                        │
│  ├── vm-100-disk-0: 100GB ← Allocated  │
│  ├── vm-101-disk-0: 50GB  ← Allocated  │
│  └── Free: 850GB                       │
│                                        │
│  Multiple nodes can access ✅          │
│  (but only one writes metadata)        │
└────────────────────────────────────────┘
```

**LVM-Thin - NOT Cluster-Safe ❌**
```
┌────────────────────────────────────────┐
│  Volume Group: local-storage           │
│  Thin Pool: 500GB                      │
│                                        │
│  Thin Volumes:                         │
│  ├── vm-100-disk-0: 100GB (uses 20GB)  │
│  ├── vm-101-disk-0: 200GB (uses 50GB)  │
│  └── Total allocated: 300GB             │
│      Actually used: 70GB                │
│                                        │
│  Multiple nodes = CORRUPTION ❌         │
│  (metadata conflicts!)                 │
└────────────────────────────────────────┘
```

**Why Thin Doesn't Work in HA:**
- Thin pool tracks which blocks are used
- Multiple nodes writing simultaneously
- Metadata gets corrupted
- **Use thick volumes for shared storage!**

---

### 🖥️ Proxmox Storage Concepts

#### Storage Types in Proxmox

**Directory** (`dir`)
```
Simple folder on filesystem
/var/lib/vz/
├── images/
│   ├── 100/  ← VM 100 disks
│   └── 101/  ← VM 101 disks
└── template/

✅ Simple
❌ No snapshots
❌ No thin provisioning
```

**LVM** (`lvm`)
```
Block devices from Volume Group
/dev/pve/
├── vm-100-disk-0  ← 50GB LV
├── vm-101-disk-0  ← 100GB LV

✅ Good performance
✅ Snapshots (if not shared)
⚠️ Thick provisioning only (for shared)
```

**LVM-Thin** (`lvmthin`)
```
Thin-provisioned from Thin Pool
/dev/pve/
├── data (thin pool - 500GB)
    ├── vm-100-disk-0 (50GB allocated, 10GB used)
    ├── vm-101-disk-0 (100GB allocated, 30GB used)

✅ Thin provisioning
✅ Snapshots
❌ NOT for shared/HA (single node only)
```

**iSCSI** (`iscsi`)
```
Block devices from iSCSI target
Proxmox connects → Sees LUNs as /dev/sdX

⚠️ Raw access only
⚠️ Can't create volumes from Proxmox
✅ Can use as PV for LVM!
```

---

#### Shared vs Non-Shared Storage

**Non-Shared (Local)**
```
┌─────────────┐
│  Proxmox 1  │
│   Local     │
│   Disk      │
└─────────────┘

✅ Fast (local disk speed)
✅ Can use LVM-thin
❌ Can't migrate VMs to other nodes
❌ No HA
```

**Shared (Cluster)**
```
┌─────────────┐     ┌─────────────┐
│  Proxmox 1  │     │  Proxmox 2  │
└──────┬──────┘     └──────┬──────┘
       │                   │
       └────────┬──────────┘
                ↓
       ┌─────────────────┐
       │  Shared Storage │
       │  (NFS/iSCSI/    │
       │   Ceph)         │
       └─────────────────┘

✅ HA and live migration
✅ VMs can move between nodes
⚠️ Must use thick LVM (no thin)
⚠️ Slower than local (network latency)
```

---

### 🎯 Putting It All Together

#### Complete Stack Example

Let's trace a VM disk write through the entire stack:

```
┌──────────────────────────────────────────────────┐
│  1. VM writes file                               │
│     Application: echo "data" > /var/file.txt     │
└────────────────────┬─────────────────────────────┘
                     │
                     ↓
┌──────────────────────────────────────────────────┐
│  2. VM Filesystem (ext4/xfs)                     │
│     Converts to block writes                     │
└────────────────────┬─────────────────────────────┘
                     │
                     ↓
┌──────────────────────────────────────────────────┐
│  3. VM Sees: /dev/sda                            │
│     VirtIO SCSI disk                             │
└────────────────────┬─────────────────────────────┘
                     │
                     ↓
┌──────────────────────────────────────────────────┐
│  4. Proxmox Hypervisor                           │
│     LV: /dev/san-storage/vm-100-disk-0           │
└────────────────────┬─────────────────────────────┘
                     │
                     ↓
┌──────────────────────────────────────────────────┐
│  5. LVM Volume Group                             │
│     VG: san-storage (backed by PV)               │
└────────────────────┬─────────────────────────────┘
                     │
                     ↓
┌──────────────────────────────────────────────────┐
│  6. Physical Volume                              │
│     PV: /dev/mapper/mpatha                       │
└────────────────────┬─────────────────────────────┘
                     │
                     ↓
┌──────────────────────────────────────────────────┐
│  7. Multipath Device                             │
│     Splits I/O across 4 paths (round-robin)      │
│     ├── /dev/sdd (25% of I/O)                    │
│     ├── /dev/sde (25% of I/O)                    │
│     ├── /dev/sdf (25% of I/O)                    │
│     └── /dev/sdg (25% of I/O)                    │
└────────────────────┬─────────────────────────────┘
                     │
                     ↓
┌──────────────────────────────────────────────────┐
│  8. iSCSI Protocol                               │
│     Encapsulates SCSI commands in TCP/IP         │
│     Send to: 192.168.10.11-14:3260               │
└────────────────────┬─────────────────────────────┘
                     │
                     ↓
┌──────────────────────────────────────────────────┐
│  9. Network (25GbE)                              │
│     Transmits packets to SAN                     │
└────────────────────┬─────────────────────────────┘
                     │
                     ↓
┌──────────────────────────────────────────────────┐
│ 10. ME5224 SAN                                   │
│     Receives iSCSI, converts to SCSI             │
│     Writes to LUN on RAID array                  │
│     Data stored on physical disks                │
└──────────────────────────────────────────────────┘
```

**Latency Breakdown:**
```
Layer                      Latency
─────────────────────────────────────
VM filesystem             <0.01ms
Hypervisor                <0.05ms
LVM                       <0.01ms
Multipath                 <0.01ms
iSCSI protocol            <0.1ms
Network (25GbE)           0.5-1ms  ← Main latency!
SAN controller            0.2ms
SAN disk (SSD)            0.1ms
─────────────────────────────────────
Total round-trip:         ~2-3ms
```

---

### 📚 Quick Reference

#### Command Cheat Sheet

**iSCSI Commands:**
```bash
# Discover targets
iscsiadm -m discovery -t st -p <IP>

# Login to target
iscsiadm -m node -L all

# Show sessions
iscsiadm -m session

# Logout
iscsiadm -m node -u all
```

**Multipath Commands:**
```bash
# Show multipath devices
multipath -ll

# Reload multipath
multipath -r

# Show paths
multipathd show paths
```

**LVM Commands:**
```bash
# Physical Volumes
pvcreate /dev/sdb
pvs
pvdisplay

# Volume Groups
vgcreate vg-name /dev/sdb
vgs
vgdisplay

# Logical Volumes
lvcreate -L 10G -n lv-name vg-name
lvs
lvdisplay
```

**Proxmox Storage:**
```bash
# List storage
pvesm status

# Add LVM storage
pvesm add lvm storage-id --vgname vg-name

# List volumes
pvesm list storage-id
```

---

This foundational knowledge will help you understand:
- Why we use multipath (redundancy + performance)
- Why shared LVM can't use thin provisioning (metadata conflicts)
- How CSI automates storage provisioning
- The complete data path from application to disk

Now let's apply these concepts in the practical sections!

---

### 🔗 Concept Relationships Map

Here's how all concepts relate to each other:

```
PHYSICAL LAYER (Hardware)
═══════════════════════════════════════════════════════════════
┌────────────────────────────────────────────────────────────┐
│  DELL ME5224 SAN                                           │
│  ┌──────────────┐  ┌──────────────┐                        │
│  │ Controller A │  │ Controller B │                        │
│  │ (Active)     │  │ (Active)     │  Dual Controllers      │
│  └──────┬───────┘  └──────┬───────┘                        │
│         │                 │                                │
│  ┌──────▼─────────────────▼────────┐                       │
│  │     Physical Disks (RAID-6)     │  Storage Pool         │
│  │  24× 2.5" SSD/HDD               │                       │
│  └─────────────────────────────────┘                       │
└────────────────────────────────────────────────────────────┘
         │                 │
         │ Creates         │ Presents as
         ↓                 ↓
┌─────────────────┐  ┌──────────────────────┐
│  Storage Pool   │  │  LUN (Logical Unit)  │  Logical Layer
│  (10TB)         │→ │  LUN 0: 1TB          │
└─────────────────┘  │  LUN 1: 500GB        │
                     └──────────────────────┘
                              │
                              │ Exposed via
                              ↓

PROTOCOL LAYER (Network)
═══════════════════════════════════════════════════════════════
                     ┌────────────────┐
                     │ iSCSI Protocol │  Port 3260
                     │ IQN: iqn.2024  │  4 Network Paths
                     └────────┬───────┘
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
    Path 1 (A1)          Path 2 (A2)         Path 3 (B1)  Path 4 (B2)
    192.168.10.11        192.168.10.12       192.168.10.13 192.168.10.14
         │                    │                    │         │
         └────────────────────┴────────────────────┴─────────┘
                              │
                    25GbE Network (Ethernet)
                              │
                              ↓

SERVER LAYER (Proxmox/Linux)
═══════════════════════════════════════════════════════════════
┌─────────────────────────────────────────────────────────────┐
│  PROXMOX NODE                                               │
│                                                             │
│  ┌──────────────────────────────────────────────┐           │
│  │  iSCSI Initiator (open-iscsi)                │           │
│  │  IQN: iqn.2024-12.com.company:proxmox1       │           │
│  └────────────┬─────────────────────────────────┘           │
│               │ Discovers & Logs In                         │
│               ↓                                             │
│  ┌──────────────────────────────────────────────┐           │
│  │  Block Devices Created:                      │           │
│  │  /dev/sdd ← Path 1 (same LUN!)               │           │
│  │  /dev/sde ← Path 2 (same LUN!)               │           │
│  │  /dev/sdf ← Path 3 (same LUN!)               │           │
│  │  /dev/sdg ← Path 4 (same LUN!)               │           │
│  └────────────┬─────────────────────────────────┘           │
│               │ ❌ Without multipath = 4 separate disks     │
│               ↓                                             │
│  ┌──────────────────────────────────────────────┐           │
│  │  Multipath Daemon (multipathd)               │           │
│  │  Combines 4 paths into 1 device              │           │
│  └────────────┬─────────────────────────────────┘           │
│               │                                             │
│               ↓                                             │
│  ┌──────────────────────────────────────────────┐           │
│  │  /dev/mapper/mpatha                          │           │
│  │  ├── /dev/sdd (active ready running)         │           │
│  │  ├── /dev/sde (active ready running)         │           │
│  │  ├── /dev/sdf (active ready running)         │           │
│  │  └── /dev/sdg (active ready running)         │           │
│  │  Policy: round-robin (load balanced)         │           │
│  └────────────┬─────────────────────────────────┘           │
│               │ ✅ Single logical device!                   │
│               ↓                                             │
│  ┌──────────────────────────────────────────────┐           │
│  │  LVM Physical Volume (PV)                    │           │
│  │  pvcreate /dev/mapper/mpatha                 │           │
│  └────────────┬─────────────────────────────────┘           │
│               │                                             │
│               ↓                                             │
│  ┌──────────────────────────────────────────────┐           │
│  │  LVM Volume Group (VG)                       │           │
│  │  vgcreate san-storage /dev/mapper/mpatha     │           │
│  │  Total: 1TB (from multipath device)          │           │
│  └────────────┬─────────────────────────────────┘           │
│               │                                             │
│               ↓                                             │
│  ┌──────────────────────────────────────────────┐           │
│  │  LVM Logical Volumes (LV) - Thick            │           │
│  │  ├── vm-100-disk-0: 100GB                    │           │
│  │  ├── vm-101-disk-0: 50GB                     │           │
│  │  └── vm-102-disk-0: 200GB                    │           │
│  └────────────┬─────────────────────────────────┘           │
│               │                                             │
│               ↓                                             │
│  ┌──────────────────────────────────────────────┐           │
│  │  Proxmox Storage (pvesm)                     │           │
│  │  Type: lvm (shared: yes)                     │           │
│  │  Content: VM disks, CT volumes               │           │
│  └────────────┬─────────────────────────────────┘           │
└───────────────┼─────────────────────────────────────────────┘
                │

VIRTUALIZATION LAYER
═══════════════════════════════════════════════════════════════
                │
    ┌───────────┼───────────┐
    │           │           │
    ↓           ↓           ↓
┌────────┐  ┌────────┐  ┌────────┐
│ VM 100 │  │ VM 101 │  │ VM 102 │
│        │  │        │  │        │
│ Sees:  │  │ Sees:  │  │ Sees:  │
│/dev/sda│  │/dev/sda│  │/dev/sda│
│ 100GB  │  │ 50GB   │  │ 200GB  │
└────────┘  └────────┘  └────────┘

KUBERNETES LAYER (Optional)
═══════════════════════════════════════════════════════════════
                │
                ↓
    ┌───────────────────────┐
    │  CSI Driver           │
    │  (Proxmox CSI or      │
    │   Seagate Exos CSI)   │
    └───────────┬───────────┘
                │
                ↓
    ┌───────────────────────┐
    │  StorageClass         │
    │  provisioner: csi...  │
    └───────────┬───────────┘
                │
                ↓
    ┌───────────────────────┐
    │  PersistentVolume     │
    │  Dynamically created  │
    └───────────┬───────────┘
                │
                ↓
    ┌───────────────────────┐
    │  Pod mounts PVC       │
    │  Application uses     │
    │  /data directory      │
    └───────────────────────┘


KEY CONCEPTS SUMMARY
═══════════════════════════════════════════════════════════════

LUN         → Virtual disk on SAN (what ME5224 creates)
iSCSI       → Protocol to access LUN over network
Multipath   → Combines 4 network paths into 1 device
PV          → Physical disk/device for LVM
VG          → Pool of PVs (storage wallet)
LV          → Virtual partition from VG (what VMs use)
Shared LVM  → Multiple Proxmox nodes access same VG
CSI         → Kubernetes standard for storage automation
PVC         → Kubernetes storage request
```

---

### 💡 Key Takeaways

**For Presentations, Remember:**

1. **SAN/LUN:** ME5224 creates virtual disks (LUNs) from physical disk pool
2. **iSCSI:** Network protocol to access those LUNs (like SATA over Ethernet)
3. **Multipath:** Combines 4 network cables into 1 logical path (redundancy + speed)
4. **LVM:** Flexible disk management - easier than fixed partitions
5. **Shared LVM:** Multiple servers share one storage pool (enables HA)
6. **CSI:** Kubernetes automation - creates disks on-demand

**The Stack in 3 Sentences:**
- **ME5224** creates LUNs and exposes them via **iSCSI** over 4 network paths
- **Proxmox** combines paths with **multipath**, creates **LVM** pool from it
- **VMs/Kubernetes** get flexible storage from that pool, with **HA** and **live migration**

**Why This Design?**
- **Redundancy:** Any path fails → others continue (no downtime)
- **Performance:** 4 paths = 4× bandwidth (load balancing)
- **Flexibility:** LVM allows resize, extend, manage easily
- **HA:** Shared storage = VMs can move between servers
- **Automation:** CSI = Kubernetes creates disks automatically

---

## Architecture Comparison

### VM-Focused Architecture

```
┌──────────────────────────────────────────────────────────┐
│                  PROXMOX CLUSTER                         │
│                                                          │
│  ┌─────────────────┐      ┌─────────────────┐           │
│  │  Proxmox Node 1 │      │  Proxmox Node 2 │           │
│  │                 │      │                 │           │
│  │  ┌───────────┐  │      │  ┌───────────┐  │           │
│  │  │    VM     │  │      │  │    VM     │  │           │
│  │  │  (disk on │  │      │  │  (disk on │  │           │
│  │  │  shared   │  │      │  │  shared   │  │           │
│  │  │  LVM)     │  │      │  │  LVM)     │  │           │
│  │  └───────────┘  │      │  └───────────┘  │           │
│  │        │        │      │        │        │           │
│  │        ↓        │      │        ↓        │           │
│  │  ┌───────────┐  │      │  ┌───────────┐  │           │
│  │  │   LVM VG  │  │      │  │   LVM VG  │  │           │
│  │  │  (shared) │  │      │  │  (shared) │  │           │
│  │  └─────┬─────┘  │      │  └─────┬─────┘  │           │
│  │        │        │      │        │        │           │
│  │        ↓        │      │        ↓        │           │
│  │  ┌───────────┐  │      │  ┌───────────┐  │           │
│  │  │ Multipath │  │      │  │ Multipath │  │           │
│  │  │  mpatha   │  │      │  │  mpatha   │  │           │
│  │  └─────┬─────┘  │      │  └─────┬─────┘  │           │
│  └────────┼────────┘      └────────┼────────┘           │
│           │                        │                    │
│           └────────────┬───────────┘                    │
└────────────────────────┼────────────────────────────────┘
                         │
            4× iSCSI Paths (Multipath)
                         │
        ┌────────────────┴────────────────┐
        │         192.168.x.10            │ Controller A
        │         192.168.x.11            │ Controller A
        │         192.168.x.12            │ Controller B
        │         192.168.x.13            │ Controller B
        └────────────────┬────────────────┘
                         │
              ┌──────────▼──────────┐
              │  DELL ME5224 SAN    │
              │  - Dual Controllers │
              │  - RAID Protection  │
              │  - Thin Provision   │
              └─────────────────────┘
```

**Benefits:** VM HA, live migration, shared storage  
**Use For:** Traditional VMs, LXC containers, file servers

---

### Kubernetes Option A: Seagate Exos X CSI

```
┌──────────────────────────────────────────────────────────┐
│                KUBERNETES CLUSTER                         │
│              (running on Proxmox VMs)                     │
│                                                          │
│  ┌─────────────────────────────────────────────────┐     │
│  │              POD WITH PVC                       │     │
│  │  ┌────────────────────────────────────┐         │     │
│  │  │  Application                       │         │     │
│  │  │  Mounts: /data (PersistentVolume)  │         │     │
│  │  └────────────────────────────────────┘         │     │
│  └──────────────────────┬──────────────────────────┘     │
│                         │                                │
│                         ↓                                │
│           ┌─────────────────────────────┐                │
│           │   Seagate Exos X CSI        │                │
│           │   (talks to ME5224 API)     │                │
│           └─────────────┬───────────────┘                │
│                         │                                │
│  ┌──────────────────────▼────────────────────────┐       │
│  │         Kubernetes Worker Node (VM)           │       │
│  │  ┌──────────────────────────────────┐         │       │
│  │  │  iSCSI Initiator + Multipath     │         │       │
│  │  │  /dev/mapper/mpath0              │         │       │
│  │  └──────────────┬───────────────────┘         │       │
│  └─────────────────┼─────────────────────────────┘       │
└────────────────────┼───────────────────────────────────┘
                     │
        Direct iSCSI (bypasses Proxmox storage layer)
                     │
              ┌──────▼──────┐
              │  ME5224 SAN │
              │  - Creates  │
              │    LUNs via │
              │    API      │
              └─────────────┘
```

**Benefits:** Direct SAN control, ME5224 features, less overhead  
**Use For:** K8s-only clusters, when you want maximum SAN feature access

---

### Kubernetes Option B: Proxmox CSI

```
┌──────────────────────────────────────────────────────────┐
│                KUBERNETES CLUSTER                         │
│              (running on Proxmox VMs)                     │
│                                                          │
│  ┌─────────────────────────────────────────────────┐     │
│  │              POD WITH PVC                       │     │
│  │  ┌────────────────────────────────────┐         │     │
│  │  │  Application                       │         │     │
│  │  │  Mounts: /data (PersistentVolume)  │         │     │
│  │  └────────────────────────────────────┘         │     │
│  └──────────────────────┬──────────────────────────┘     │
│                         │                                │
│                         ↓                                │
│           ┌─────────────────────────────┐                │
│           │     Proxmox CSI Plugin      │                │
│           │   (talks to Proxmox API)    │                │
│           └─────────────┬───────────────┘                │
│                         │                                │
└─────────────────────────┼────────────────────────────────┘
                          │
                          ↓ Proxmox API
┌──────────────────────────────────────────────────────────┐
│                  PROXMOX HYPERVISOR                      │
│                                                          │
│  ┌────────────────────────────────────────┐              │
│  │  Creates LV on iscsi-multipath VG     │              │
│  │  Attaches to VM as SCSI disk          │              │
│  └────────────────┬───────────────────────┘              │
│                   │                                      │
│            ┌──────▼──────┐                               │
│            │   LVM VG    │                               │
│            │  (backed by │                               │
│            │   ME5224)   │                               │
│            └──────┬──────┘                               │
│                   │                                      │
│            ┌──────▼──────┐                               │
│            │  Multipath  │                               │
│            └──────┬──────┘                               │
└───────────────────┼──────────────────────────────────────┘
                    │
       4× iSCSI (managed by Proxmox)
                    │
              ┌─────▼─────┐
              │ ME5224 SAN│
              └───────────┘
```

**Benefits:** Unified management, works with any Proxmox storage, simpler K8s node setup  
**Use For:** Mixed environments (VMs + K8s), want Proxmox to manage storage

---

## Prerequisites

### Hardware Requirements

- **Dell PowerVault ME5224** (or ME5012/ME5024/ME5084)
  - Dual controllers configured
  - Network ports configured for iSCSI
  - At least one storage pool created

- **Proxmox Cluster**
  - Minimum 2 nodes (3+ recommended for quorum)
  - 10GbE or 25GbE network interfaces
  - Separate network for storage (recommended)

### Network Requirements

```
Management Network:  192.168.1.0/24
Storage Network:     192.168.10.0/24  (dedicated VLAN recommended)

ME5224 IPs:
  Controller A Port 1: 192.168.10.11
  Controller A Port 2: 192.168.10.12
  Controller B Port 1: 192.168.10.13
  Controller B Port 2: 192.168.10.14
```

### Software Versions

- Proxmox VE 8.x or later
- open-iscsi 2.1.x or later
- multipath-tools 0.9.x or later
- Kubernetes 1.27+ (for CSI features)

---

# PART 1: VM-FOCUSED STORAGE

## iSCSI Multipath LVM for Proxmox

**Goal:** Configure ME5224 as shared storage for Proxmox VMs with HA and live migration.

**Official Guide:** https://kb.blockbridge.com/technote/proxmox-lvm-shared-storage/

---

## Step 1: Prepare ME5224 Storage

### 1.1 Create Storage Pool (via ME5224 Web UI)

1. Login to ME5224 management interface
2. Navigate to **Provisioning → Pools**
3. Create pool: `Pool_A`
   - RAID Level: RAID-6 (recommended)
   - Spare disks: 2
   - Click **Create**

### 1.2 Create Virtual Disk (LUN)

1. Navigate to **Provisioning → Volumes**
2. Click **Create Virtual Disk**
3. Settings:
   ```
   Name: proxmox-shared-01
   Pool: Pool_A
   Size: 1TB (or as needed)
   Provisioning: Thin
   ```
4. Click **Create**

### 1.3 Configure Network Ports

1. Navigate to **Settings → Network**
2. For each controller:
   ```
   Controller A:
     Port 1: 192.168.10.11/24
     Port 2: 192.168.10.12/24
   
   Controller B:
     Port 1: 192.168.10.13/24
     Port 2: 192.168.10.14/24
   ```
3. Enable iSCSI on all ports

### 1.4 Create Host and Map LUN

1. Navigate to **Provisioning → Hosts**
2. Click **Create Host**
3. Settings:
   ```
   Name: proxmox-cluster
   Host Type: Linux
   ```
4. Click **Add Initiator**
5. Add initiator IQN from each Proxmox node:
   ```
   iqn.2024-12.com.company:proxmox-node1
   iqn.2024-12.com.company:proxmox-node2
   iqn.2024-12.com.company:proxmox-node3
   ```
6. **Map Volume:**
   - Select `proxmox-shared-01`
   - LUN ID: 0
   - Access: Read/Write
   - Click **Map**

---

## Step 2: Configure iSCSI on ALL Proxmox Nodes

**Run these commands on EVERY Proxmox node in the cluster.**

### 2.1 Install Required Packages

```bash
apt update
apt install open-iscsi multipath-tools -y
```

### 2.2 Configure iSCSI Initiator

**On each node, use a UNIQUE initiator name:**

```bash
# Node 1
echo "InitiatorName=iqn.2024-12.com.company:proxmox-node1" > /etc/iscsi/initiatorname.iscsi

# Node 2
echo "InitiatorName=iqn.2024-12.com.company:proxmox-node2" > /etc/iscsi/initiatorname.iscsi

# Node 3
echo "InitiatorName=iqn.2024-12.com.company:proxmox-node3" > /etc/iscsi/initiatorname.iscsi
```

Restart services:

```bash
systemctl restart iscsid open-iscsi
systemctl enable iscsid open-iscsi
```

### 2.3 Discover iSCSI Targets

**Run on one node first to test:**

```bash
# Discover from Controller A
iscsiadm -m discovery -t st -p 192.168.10.11

# You should see 4 portals advertising the same target:
# 192.168.10.11:3260,1 iqn.2024-12.com.dell:me5224-target
# 192.168.10.12:3260,1 iqn.2024-12.com.dell:me5224-target
# 192.168.10.13:3260,1 iqn.2024-12.com.dell:me5224-target
# 192.168.10.14:3260,1 iqn.2024-12.com.dell:me5224-target
```

### 2.4 Login to All Paths

```bash
# Login to all discovered targets
iscsiadm -m node -L all

# Verify 4 sessions
iscsiadm -m session

# Should show:
# tcp: [1] 192.168.10.11:3260,1 iqn.2024-12.com.dell:me5224-target (non-flash)
# tcp: [2] 192.168.10.12:3260,1 iqn.2024-12.com.dell:me5224-target (non-flash)
# tcp: [3] 192.168.10.13:3260,1 iqn.2024-12.com.dell:me5224-target (non-flash)
# tcp: [4] 192.168.10.14:3260,1 iqn.2024-12.com.dell:me5224-target (non-flash)
```

### 2.5 Enable Automatic Login on Boot

```bash
iscsiadm -m node -L automatic
```

### 2.6 Verify Block Devices

```bash
lsblk

# You should see 4 new disks (same size):
# sdd    8:48   0  1.0T  0 disk
# sde    8:64   0  1.0T  0 disk
# sdf    8:80   0  1.0T  0 disk
# sdg    8:96   0  1.0T  0 disk
```

**⚠️ CRITICAL:** All 4 devices point to the SAME physical LUN!

---

## Step 3: Configure Multipath on ALL Nodes

### 3.1 Get Device WWID

```bash
# Get WWID from one of the devices
lsblk -o NAME,WWID | grep sdd

# Example output:
# sdd    36001405ab074f80c771472bb0e1d2c8a
```

**Copy this WWID - you'll need it!**

### 3.2 Create Multipath Configuration

```bash
nano /etc/multipath.conf
```

**Paste this configuration:**

```conf
defaults {
    user_friendly_names yes
    path_grouping_policy multibus
    path_selector "round-robin 0"
    failback immediate
    no_path_retry 12
    find_multipaths no
}

blacklist {
    # Blacklist local disks
    devnode "^(ram|raw|loop|fd|md|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^sd[abc]$"      # Adjust based on your local disks
    devnode "^nvme"          # If you have local NVMe
}

blacklist_exceptions {
    # Whitelist Dell/ME5224 devices
    device {
        vendor "DellEMC"
        product "ME5"
    }
}

devices {
    device {
        vendor "DellEMC"
        product "ME5"
        path_grouping_policy multibus
        path_selector "round-robin 0"
        failback immediate
        rr_weight uniform
        no_path_retry 12
        prio alua
    }
}
```

**⚠️ Important:** Adjust `blacklist` section to match YOUR local disks!

### 3.3 Add WWID to Whitelist

```bash
# Replace with YOUR WWID from step 3.1
echo "/36001405ab074f80c771472bb0e1d2c8a/" >> /etc/multipath/wwids
```

### 3.4 Restart Multipath

```bash
systemctl restart multipathd
systemctl enable multipathd

# Reload multipath devices
multipath -r

# Verify multipath device created
multipath -ll
```

**Expected output:**

```
mpatha (36001405ab074f80c771472bb0e1d2c8a) dm-0 DellEMC,ME5
size=1.0T features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
`-+- policy='round-robin 0' prio=50 status=active
  |- 6:0:0:0 sdd 8:48  active ready running
  |- 7:0:0:0 sde 8:64  active ready running
  |- 8:0:0:0 sdf 8:80  active ready running
  `- 9:0:0:0 sdg 8:96  active ready running
```

✅ **All 4 paths should show "active ready running"**

### 3.5 Verify Multipath Device

```bash
# Check device exists
ls -l /dev/mapper/mpatha

# Should show:
# lrwxrwxrwx 1 root root 8 Dec 28 10:00 /dev/mapper/mpatha -> ../dm-0
```

---

## Step 4: Create LVM on FIRST Node Only

**⚠️ Run these commands on ONE node only! Other nodes will import the VG later.**

### 4.1 Create Physical Volume

```bash
pvcreate /dev/mapper/mpatha

# Verify
pvs

# Should show:
# PV                VG  Fmt  Attr PSize   PFree
# /dev/mapper/mpatha     lvm2 ---  1.00t   1.00t
```

### 4.2 Create Volume Group

```bash
vgcreate san-storage /dev/mapper/mpatha

# Verify
vgs

# Should show:
# VG          #PV #LV #SN Attr   VSize   VFree
# san-storage   1   0   0 wz--n- 1.00t   1.00t
```

### 4.3 DO NOT Create Thin Pool

**Important:** For shared LVM (HA), we use **thick volumes only**. Thin provisioning doesn't work in clustered mode.

---

## Step 5: Import VG on Other Nodes

**Run on nodes 2, 3, etc.:**

### 5.1 Scan for Volume Groups

```bash
vgscan

# Should discover the VG:
# Reading all physical volumes. This may take a while...
# Found volume group "san-storage" using metadata type lvm2
```

### 5.2 Activate Volume Group

```bash
vgchange -ay san-storage

# Verify
vgs

# Should show:
# VG          #PV #LV #SN Attr   VSize   VFree
# san-storage   1   0   0 wz--n- 1.00t   1.00t
```

---

## Step 6: Add Storage to Proxmox

**Run on any ONE node (it syncs to cluster automatically):**

```bash
pvesm add lvm san-storage \
  --vgname san-storage \
  --content images \
  --shared 1
```

**Parameters explained:**
- `san-storage` - Storage ID in Proxmox
- `--vgname san-storage` - LVM VG name
- `--content images` - Store VM/CT disks
- `--shared 1` - **CRITICAL!** Marks storage as shared for HA

### 6.1 Verify in Proxmox

```bash
pvesm status

# Should show:
# Name         Type   Status  Total       Used    Available   %
# san-storage  lvm    active  1073741824  0       1073741824  0.00%
```

**Or check in Web UI:**
1. Datacenter → Storage
2. You should see `san-storage` listed
3. Nodes: All (because it's shared)

---

## Step 7: Test VM Creation

### 7.1 Create Test VM

**Via CLI:**

```bash
# Create VM
qm create 999 \
  --name test-ha-vm \
  --memory 2048 \
  --cores 2 \
  --net0 virtio,bridge=vmbr0

# Add disk on shared storage
qm set 999 --scsi0 san-storage:32

# Verify disk created
lvs | grep vm-999

# Should show:
# vm-999-disk-0 san-storage -wi-a----- 32.00g
```

**Or via Web UI:**
1. Right-click node → Create VM
2. In **Hard Disk** tab:
   - Storage: `san-storage`
   - Disk size: 32 GB
3. Finish wizard

### 7.2 Test HA Migration

**Migrate VM between nodes:**

```bash
# Migrate VM 999 to node2
qm migrate 999 node2 --online

# VM migrates live while running!
# Disk stays on shared storage
```

**Or via Web UI:**
1. Right-click VM → Migrate
2. Select target node
3. Click **Migrate**

✅ **Success!** VM migrates with live storage access.

---

## Step 8: Configure HA (Optional)

### 8.1 Enable HA for VM

```bash
# Add VM to HA group
ha-manager add vm:999

# Set HA policy
ha-manager set vm:999 --state started --max_relocate 2
```

**Or via Web UI:**
1. Datacenter → HA
2. Add → VM 999
3. Set options

### 8.2 Test Failover

**Simulate node failure:**

```bash
# On node running VM 999, stop services
systemctl stop pve-cluster

# HA manager detects failure
# VM automatically restarts on another node
# Disk accessible because of shared storage
```

---

## VM-Focused Setup Complete! ✅

**What you now have:**

✅ ME5224 configured with iSCSI  
✅ Multipath with 4 active paths  
✅ Shared LVM storage across all nodes  
✅ HA-capable VMs with live migration  
✅ Automatic failover protection  

**Monitoring:**

```bash
# Check multipath health
multipath -ll

# Check iSCSI sessions
iscsiadm -m session

# Check LVM
vgs; lvs

# Check storage
pvesm status
```

---

# PART 2: KUBERNETES-FOCUSED STORAGE

**Prerequisites for K8s section:**
- ✅ Kubernetes cluster running on Proxmox VMs
- ✅ `kubectl` access to cluster
- ✅ Helm 3.x installed

---

## Option A: Seagate Exos X CSI

**Official Repo:** https://github.com/Seagate/seagate-exos-x-csi

**What it does:** Kubernetes CSI driver that talks directly to ME5224 API to provision LUNs dynamically.

**Best for:** K8s-only environments, direct SAN control, maximum ME5224 feature access

---

### Architecture Overview

```
Kubernetes Pod → PVC → CSI Driver → ME5224 API → Create LUN
                                          ↓
                              iSCSI attach to K8s node
                                          ↓
                              Mount in Pod as volume
```

---

### A1: Check ME5224 API Compatibility

**⚠️ Important:** Seagate Exos X CSI is designed for Seagate storage, but ME5224 is Dell-branded Seagate hardware with compatible API.

**Test API Access:**

```bash
# Install curl if needed
apt install curl -y

# Test API endpoint (from any K8s node)
curl -k -u manage:password https://192.168.10.11/api/login

# If successful, you'll see XML response with session key
```

**If API is accessible, proceed. If not, use Proxmox CSI (Option B).**

---

### A2: Install iSCSI on ALL Kubernetes Worker Nodes

**⚠️ Must be done on every K8s worker node (Proxmox VMs):**

```bash
# SSH to each K8s worker node

# Install iSCSI initiator
apt update
apt install open-iscsi multipath-tools -y

# Configure initiator (unique per node!)
echo "InitiatorName=iqn.2024-12.com.company:k8s-worker1" > /etc/iscsi/initiatorname.iscsi

# Restart
systemctl restart iscsid open-iscsi
systemctl enable iscsid open-iscsi

# Configure multipath
cat > /etc/multipath.conf <<EOF
defaults {
    user_friendly_names yes
    find_multipaths yes
}
EOF

systemctl restart multipathd
systemctl enable multipathd
```

**Repeat for all worker nodes with unique initiator names!**

---

### A3: Register Initiators on ME5224

**On ME5224 Web UI:**

1. Navigate to **Provisioning → Hosts**
2. Create host group: `kubernetes-cluster`
3. Add all K8s worker initiator IQNs:
   ```
   iqn.2024-12.com.company:k8s-worker1
   iqn.2024-12.com.company:k8s-worker2
   iqn.2024-12.com.company:k8s-worker3
   ```

---

### A4: Install Seagate Exos X CSI

**On K8s master/control node:**

```bash
# Clone repo
git clone https://github.com/Seagate/seagate-exos-x-csi.git
cd seagate-exos-x-csi
```

### A4.1 Create Secret for ME5224 Credentials

```bash
kubectl create namespace exos-csi

kubectl create secret generic exos-csi-secret \
  --namespace exos-csi \
  --from-literal=username='manage' \
  --from-literal=password='your-me5224-password'
```

### A4.2 Create CSI Config

Create file `exos-config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: exos-csi-config
  namespace: exos-csi
data:
  config.yaml: |
    arrays:
      - name: me5224-primary
        mgmt_ip: 192.168.10.11        # Management IP
        username: manage
        password_secret: exos-csi-secret
        password_secret_namespace: exos-csi
        iscsi_ips:
          - 192.168.10.11
          - 192.168.10.12
          - 192.168.10.13
          - 192.168.10.14
        pool: Pool_A                   # Your ME5224 pool name
```

Apply:

```bash
kubectl apply -f exos-config.yaml
```

### A4.3 Install CSI Driver via Helm

```bash
helm repo add seagate https://seagate.github.io/seagate-exos-x-csi/
helm repo update

helm install exos-csi seagate/seagate-exos-x-csi \
  --namespace exos-csi \
  --set configMap.name=exos-csi-config
```

### A4.4 Verify Installation

```bash
# Check CSI pods running
kubectl get pods -n exos-csi

# Should see:
# exos-csi-controller-0          5/5     Running
# exos-csi-node-xxxxx            3/3     Running  (on each worker)
# exos-csi-node-yyyyy            3/3     Running
# exos-csi-node-zzzzz            3/3     Running

# Check CSI driver registered
kubectl get csidrivers

# Should show:
# csi.seagate.com
```

---

### A5: Create StorageClass

Create `storageclass-exos.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: exos-iscsi
provisioner: csi.seagate.com
parameters:
  arrayName: me5224-primary        # From config
  pool: Pool_A                     # ME5224 pool
  fsType: xfs                      # or ext4
  protocol: iscsi
  # Optional: thin provisioning
  provisioningType: thin
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```

Apply:

```bash
kubectl apply -f storageclass-exos.yaml

# Verify
kubectl get storageclass

# Should show:
# NAME          PROVISIONER        RECLAIMPOLICY   VOLUMEBINDINGMODE
# exos-iscsi    csi.seagate.com    Delete          WaitForFirstConsumer
```

---

### A6: Test PVC Creation

Create `test-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: exos-iscsi
  resources:
    requests:
      storage: 10Gi
```

Create test pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
  - name: test
    image: nginx:latest
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-pvc
```

Apply and test:

```bash
kubectl apply -f test-pvc.yaml
kubectl apply -f test-pod.yaml

# Watch PVC get bound
kubectl get pvc -w

# Should see:
# NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
# test-pvc   Bound    pvc-xxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx     10Gi       RWO            exos-iscsi     30s

# Check pod running
kubectl get pod test-pod

# Verify volume mounted
kubectl exec test-pod -- df -h /data
```

### A7: Verify on ME5224

**Check ME5224 Web UI:**

1. Navigate to **Provisioning → Volumes**
2. You should see new volume: `k8s-pvc-xxxxx-xxxx-xxxx`
3. Navigate to **Provisioning → Host Mappings**
4. Volume should be mapped to appropriate K8s worker

---

### A8: Production Deployment Example

**StatefulSet with persistent storage:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql
spec:
  ports:
  - port: 3306
  clusterIP: None
  selector:
    app: mysql
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
spec:
  serviceName: mysql
  replicas: 3
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: "changeme"
        ports:
        - containerPort: 3306
        volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: exos-iscsi
      resources:
        requests:
          storage: 50Gi
```

Deploy:

```bash
kubectl apply -f mysql-statefulset.yaml

# Watch PVCs created
kubectl get pvc

# Should see 3 PVCs:
# data-mysql-0   Bound   pvc-xxxxx   50Gi   RWO   exos-iscsi
# data-mysql-1   Bound   pvc-yyyyy   50Gi   RWO   exos-iscsi
# data-mysql-2   Bound   pvc-zzzzz   50Gi   RWO   exos-iscsi
```

---

### A9: Monitoring and Management

**Check CSI Driver Health:**

```bash
# Controller status
kubectl logs -n exos-csi exos-csi-controller-0 -c csi-provisioner

# Node status
kubectl logs -n exos-csi exos-csi-node-xxxxx -c csi-driver

# Storage capacity
kubectl get csistoragecapacities -A
```

**Common Commands:**

```bash
# List all PVs from Exos CSI
kubectl get pv | grep exos-iscsi

# Describe PV details
kubectl describe pv pvc-xxxxx-xxxx-xxxx

# Check volume attachments
kubectl get volumeattachment
```

---

## Option A Complete! ✅

**What you now have:**

✅ Direct Kubernetes-to-SAN integration  
✅ Dynamic PV provisioning  
✅ Multipath iSCSI from K8s nodes  
✅ ME5224 thin provisioning  
✅ Volume expansion support  

**Limitations:**

⚠️ Seagate CSI may have compatibility issues with Dell ME5224  
⚠️ Community support only (not official Dell)  
⚠️ Each K8s node needs iSCSI/multipath configured  

**If Option A doesn't work or has issues, proceed to Option B...**

---

## Option B: Proxmox CSI Plugin

**Official Repo:** https://github.com/sergelogvinov/proxmox-csi-plugin

**What it does:** Kubernetes CSI driver that talks to Proxmox API to provision volumes. Proxmox then creates LVs on storage backend (including your ME5224 iSCSI LVM).

**Best for:** Mixed environments (VMs + K8s), simpler K8s node setup, unified storage management

---

### Architecture Overview

```
Kubernetes Pod → PVC → Proxmox CSI → Proxmox API
                                          ↓
                              Create LV on san-storage VG
                                          ↓
                              Attach LV to K8s worker VM as disk
                                          ↓
                              Mount in Pod as volume
```

**The san-storage VG is backed by ME5224 via the multipath setup from Part 1!**

---

### B1: Prerequisites

**Required from Part 1:**

✅ ME5224 configured with iSCSI  
✅ Multipath setup on all Proxmox nodes  
✅ LVM VG `san-storage` created and shared  
✅ Storage added to Proxmox: `pvesm status | grep san-storage`  

**Kubernetes Requirements:**

- K8s nodes must be labeled with topology
- Proxmox API credentials
- Proxmox nodes must be accessible from K8s

---

### B2: Label Kubernetes Nodes

**The CSI driver uses these labels to know which Proxmox node hosts each K8s node.**

**Get Proxmox node names:**

```bash
pvesh get /nodes

# Output example:
# node1
# node2
# node3
```

**Label K8s nodes:**

```bash
# For each K8s worker node, label with Proxmox topology

# Worker 1 (runs on Proxmox node1)
kubectl label node k8s-worker1 \
  topology.kubernetes.io/region=cluster-main \
  topology.kubernetes.io/zone=node1

# Worker 2 (runs on Proxmox node2)
kubectl label node k8s-worker2 \
  topology.kubernetes.io/region=cluster-main \
  topology.kubernetes.io/zone=node2

# Worker 3 (runs on Proxmox node3)
kubectl label node k8s-worker3 \
  topology.kubernetes.io/region=cluster-main \
  topology.kubernetes.io/zone=node3

# Verify labels
kubectl get nodes --show-labels | grep topology
```

**Region = Proxmox cluster name**  
**Zone = Proxmox node name**

---

### B3: Create Proxmox API Token

**On any Proxmox node:**

```bash
# Create CSI user
pveum user add csi@pve

# Create API token
pveum user token add csi@pve csi-token --privsep 0

# Output:
# ┌──────────────┬──────────────────────────────────────┐
# │ key          │ value                                │
# ╞══════════════╪══════════════════════════════════════╡
# │ full-tokenid │ csi@pve!csi-token                    │
# ├──────────────┼──────────────────────────────────────┤
# │ info         │ {"privsep":0}                        │
# ├──────────────┼──────────────────────────────────────┤
# │ value        │ xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx │
# └──────────────┴──────────────────────────────────────┘

# SAVE THE TOKEN VALUE!
```

**Grant permissions:**

```bash
# Allow CSI to manage storage
pveum acl modify / --user csi@pve --role PVESDNAdmin

# Allow CSI to manage VMs
pveum acl modify / --user csi@pve --role PVEVMAdmin
```

---

### B4: Install Proxmox CSI Plugin

**Add Helm repo:**

```bash
helm repo add proxmox-csi https://sergelogvinov.github.io/proxmox-csi-plugin
helm repo update
```

**Create values file `proxmox-csi-values.yaml`:**

```yaml
config:
  clusters:
    - url: https://192.168.1.10:8006/api2/json  # Proxmox API URL
      insecure: false
      token_id: "csi@pve!csi-token"
      token_secret: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
      region: cluster-main

storageClass:
  - name: proxmox-san
    storage: san-storage      # Your LVM VG from Part 1!
    reclaimPolicy: Delete
    fstype: xfs
    cache: directsync
    ssd: true

# Node selector (optional)
node:
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
```

**Install:**

```bash
kubectl create namespace csi-proxmox

helm install proxmox-csi proxmox-csi/proxmox-csi-plugin \
  --namespace csi-proxmox \
  --values proxmox-csi-values.yaml
```

### B5: Verify Installation

```bash
# Check pods
kubectl get pods -n csi-proxmox

# Should see:
# proxmox-csi-controller-0       5/5     Running
# proxmox-csi-node-xxxxx         3/3     Running  (on each worker)
# proxmox-csi-node-yyyyy         3/3     Running
# proxmox-csi-node-zzzzz         3/3     Running

# Check CSI driver
kubectl get csidrivers

# Should show:
# csi.proxmox.sinextra.dev

# Check storage class
kubectl get storageclass

# Should show:
# proxmox-san   csi.proxmox.sinextra.dev   Delete   WaitForFirstConsumer
```

---

### B6: Test PVC Creation

Create `test-pvc-proxmox.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc-proxmox
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: proxmox-san
  resources:
    requests:
      storage: 10Gi
```

Create test pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod-proxmox
spec:
  containers:
  - name: test
    image: nginx:latest
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-pvc-proxmox
```

Apply:

```bash
kubectl apply -f test-pvc-proxmox.yaml
kubectl apply -f test-pod-proxmox.yaml

# Watch PVC
kubectl get pvc -w

# Should bind:
# NAME               STATUS   VOLUME                                     CAPACITY
# test-pvc-proxmox   Bound    pvc-xxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx     10Gi

# Check pod
kubectl get pod test-pod-proxmox

# Exec into pod
kubectl exec -it test-pod-proxmox -- df -h /data

# Should show 10GB XFS filesystem
```

### B7: Verify on Proxmox

**Check Proxmox CLI:**

```bash
# List LVs
lvs | grep pvc

# Should show:
# vm-<VMID>-pvc-xxxxx-xxxx-xxxx  san-storage  -wi-a-----  10.00g

# This LV is on the san-storage VG
# Which is backed by ME5224 via multipath!
```

**Check Proxmox Web UI:**

1. Select any node
2. Navigate to storage `san-storage`
3. You should see disk: `vm-<VMID>-pvc-xxxxx-xxxx-xxxx`

---

### B8: Advanced StorageClass Options

**Create multiple storage classes for different use cases:**

```yaml
---
# Fast local storage
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: proxmox-local-fast
provisioner: csi.proxmox.sinextra.dev
parameters:
  storage: local-lvm        # Proxmox local storage
  cache: directsync
  ssd: "true"
  csi.storage.k8s.io/fstype: xfs
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer

---
# SAN storage (HA capable)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: proxmox-san-ha
provisioner: csi.proxmox.sinextra.dev
parameters:
  storage: san-storage      # ME5224-backed storage
  cache: directsync
  ssd: "true"
  csi.storage.k8s.io/fstype: xfs
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
```

Apply:

```bash
kubectl apply -f storageclasses.yaml
```

**Usage guidance:**

- Use `proxmox-local-fast` for:
  - Databases (MySQL, PostgreSQL)
  - High-IOPS workloads
  - Performance-critical apps

- Use `proxmox-san-ha` for:
  - StatefulSets needing HA
  - Shared application data
  - When you need multi-node migration

---

### B9: Production StatefulSet Example

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  ports:
  - port: 5432
  clusterIP: None
  selector:
    app: postgres
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: postgres
  replicas: 3
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      # Anti-affinity to spread across Proxmox nodes
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - postgres
              topologyKey: topology.kubernetes.io/zone
      containers:
      - name: postgres
        image: postgres:16
        env:
        - name: POSTGRES_PASSWORD
          value: "changeme"
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: proxmox-local-fast  # Use local for best performance
      resources:
        requests:
          storage: 100Gi
```

Deploy:

```bash
kubectl apply -f postgres-statefulset.yaml

# Watch deployment
kubectl get pods -l app=postgres -w

# Check PVCs spread across zones
kubectl get pvc -o wide
```

---

### B10: Volume Expansion Test

**Expand existing PVC:**

```bash
# Edit PVC
kubectl edit pvc test-pvc-proxmox

# Change storage: 10Gi → 20Gi
# Save and exit

# Watch resize
kubectl get pvc test-pvc-proxmox -w

# After resize completes, verify in pod
kubectl exec test-pod-proxmox -- df -h /data

# Should now show 20GB!
```

---

### B11: Monitoring

**Check CSI health:**

```bash
# Controller logs
kubectl logs -n csi-proxmox proxmox-csi-controller-0 -c csi-provisioner

# Node logs
kubectl logs -n csi-proxmox proxmox-csi-node-xxxxx -c csi-driver

# Storage capacity tracking
kubectl get csistoragecapacities -A

# Should show available capacity from Proxmox storage pools
```

---

## Option B Complete! ✅

**What you now have:**

✅ Proxmox-managed K8s storage  
✅ Works with ME5224-backed LVM  
✅ Dynamic PV provisioning  
✅ Volume expansion support  
✅ Topology-aware scheduling  
✅ Multiple storage tiers (local + SAN)  

**Advantages over Option A:**

✅ More mature and actively maintained  
✅ Simpler K8s node configuration (no iSCSI setup needed in VMs)  
✅ Works with ANY Proxmox storage backend  
✅ Better integration with Proxmox ecosystem  

---

# Decision Matrix

## When to Use Each Approach

### VM-Focused (Part 1)

| Use Case | Recommendation |
|----------|----------------|
| Windows VMs | ✅ **Perfect** |
| File servers | ✅ **Perfect** |
| General-purpose VMs | ✅ **Perfect** |
| HA VMs with live migration | ✅ **Perfect** |
| Mixed VM environment | ✅ **Perfect** |
| Kubernetes only | ⚠️ Use CSI instead |

---

### Kubernetes Option A: Seagate Exos X CSI

| Use Case | Recommendation |
|----------|----------------|
| Kubernetes-only cluster | ✅ **Good** |
| Direct SAN control needed | ✅ **Good** |
| Need ME5224-specific features | ✅ **Good** |
| Mixed VMs + K8s | ⚠️ Use Option B |
| Community support acceptable | ✅ **Good** |
| Dell ME5224 (not Seagate) | ⚠️ May have issues |

---

### Kubernetes Option B: Proxmox CSI

| Use Case | Recommendation |
|----------|----------------|
| Mixed VMs + Kubernetes | ✅ **Perfect** |
| Want unified management | ✅ **Perfect** |
| Multiple storage tiers | ✅ **Perfect** |
| Simpler K8s setup | ✅ **Perfect** |
| Production stability critical | ✅ **Perfect** |
| Active community support | ✅ **Perfect** |

---

## Performance Comparison

### Expected IOPS (4K Random)

| Approach | Read IOPS | Write IOPS | Latency |
|----------|-----------|------------|---------|
| **Local NVMe** (Proxmox CSI local) | 500k | 300k | <0.1ms |
| **SAN via Proxmox CSI** | 80k | 50k | 1-2ms |
| **SAN via Exos CSI** | 100k | 60k | 1-2ms |
| **VM on shared LVM** | 80k | 50k | 1-2ms |

### Expected Throughput (Sequential)

| Approach | Read GB/s | Write GB/s |
|----------|-----------|------------|
| **Local NVMe** | 7.0 | 5.0 |
| **SAN (4× 25GbE)** | 3.5 | 3.0 |
| **SAN (4× 10GbE)** | 1.2 | 1.0 |

---

## Recommended Architecture

### Hybrid Approach (Best of All Worlds)

```
┌─────────────────────────────────────────────────────┐
│                PROXMOX CLUSTER                      │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │  TIER 1: Traditional VMs                     │   │
│  │  - Windows VMs                               │   │
│  │  - File Servers                              │   │
│  │  - Legacy Applications                       │   │
│  │                                              │   │
│  │  Storage: san-storage (shared LVM)   ✅      │   │
│  └──────────────────────────────────────────────┘   │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │  TIER 2: Kubernetes (High Performance)       │   │
│  │  - Databases (MySQL, PostgreSQL)             │   │
│  │  - Redis, Elasticsearch                      │   │
│  │                                              │   │
│  │  Storage: proxmox-local-fast         ✅      │   │
│  │  (CSI: Proxmox CSI + local NVMe)             │   │
│  └──────────────────────────────────────────────┘   │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │  TIER 3: Kubernetes (HA Workloads)           │   │
│  │  - Stateful web apps                         │   │
│  │  - Message queues                            │   │
│  │  - Session stores                            │   │
│  │                                              │   │
│  │  Storage: proxmox-san-ha             ✅      │   │
│  │  (CSI: Proxmox CSI + ME5224 LVM)             │   │
│  └──────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
                       │
                       ↓
         ┌─────────────────────────┐
         │    DELL ME5224 SAN      │
         │  - Shared LVM backend   │
         │  - HA for VMs           │
         │  - HA for K8s tier 3    │
         └─────────────────────────┘
```

---

# Performance Tuning

## ME5224 Optimization

### Enable Write-Back Cache (if BBU present)

**On ME5224:**

1. Navigate to **Settings → Controller**
2. For each controller:
   - Write Policy: **Write-back** (if BBU/capacitor present)
   - Read Policy: **Read-ahead**

### ALUA Configuration

```bash
# ALUA automatically assigns ownership
# Controller A owns certain paths (optimized)
# Controller B has non-optimized paths
# Automatic failover on controller failure

# No manual configuration needed - ME5224 handles this
```

### Volume Settings

- **Tier:** Use SSD tier for hot data
- **Provisioning:** Thin (save space, enable TRIM)
- **Cache:** Enable if supported

---

## Proxmox Multipath Tuning

### Adjust Queue Depth

```bash
# Edit /etc/multipath.conf
# Add under defaults:

defaults {
    ...
    rr_min_io_rq 10
    queue_without_daemon no
}
```

### Enable ATS (Atomic Test and Set)

For VMware-like features:

```bash
# On Proxmox nodes
echo "options scsi_mod use_blk_mq=1" >> /etc/modprobe.d/scsi.conf

# Reboot or reload:
update-initramfs -u
```

---

## Kubernetes CSI Optimization

### Tune Volume Binding

```yaml
# For latency-sensitive apps, use Immediate binding
volumeBindingMode: Immediate

# For better pod spreading, use WaitForFirstConsumer
volumeBindingMode: WaitForFirstConsumer
```

### Enable Topology Spread

```yaml
apiVersion: apps/v1
kind: StatefulSet
spec:
  template:
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: myapp
```

---

# Troubleshooting

## Common Issues and Solutions

### Issue 1: Multipath Not Detecting Devices

**Symptom:** `multipath -ll` shows no devices

**Solution:**

```bash
# 1. Check iSCSI sessions active
iscsiadm -m session

# Should show 4 sessions

# 2. Check devices exist
lsblk

# Should show sdd, sde, sdf, sdg

# 3. Check WWID whitelisted
cat /etc/multipath/wwids

# 4. Rescan multipath
multipath -r
multipath -v2
```

---

### Issue 2: PVC Stuck in Pending

**Symptom:** PVC never binds to PV

**Kubernetes logs:**

```bash
# Check CSI controller logs
kubectl logs -n csi-proxmox proxmox-csi-controller-0 -c csi-provisioner

# Check events
kubectl describe pvc <pvc-name>
```

**Common causes:**

1. **No storage capacity:**
   ```bash
   # Check Proxmox storage
   pvesm status | grep san-storage
   
   # Expand VG if needed
   ```

2. **Node labels missing:**
   ```bash
   # Verify labels
   kubectl get nodes --show-labels | grep topology
   
   # Add if missing
   kubectl label node <node> topology.kubernetes.io/region=cluster-main
   kubectl label node <node> topology.kubernetes.io/zone=<proxmox-node>
   ```

3. **CSI driver not running:**
   ```bash
   kubectl get pods -n csi-proxmox
   
   # Restart if needed
   kubectl delete pod -n csi-proxmox <pod-name>
   ```

---

### Issue 3: iSCSI Session Drops

**Symptom:** Multipath paths go to "faulty" state

**Check:**

```bash
# Check network connectivity
ping -c 4 192.168.10.11
ping -c 4 192.168.10.12
ping -c 4 192.168.10.13
ping -c 4 192.168.10.14

# Check ME5224 controller status
# Via web UI or CLI

# Restart iSCSI service
systemctl restart iscsid open-iscsi

# Rescan sessions
iscsiadm -m session --rescan

# Check multipath
multipath -ll
```

**Prevention:**

```bash
# Increase timeout in /etc/iscsi/iscsid.conf
node.session.timeo.replacement_timeout = 120
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout = 10

# Restart
systemctl restart iscsid
```

---

### Issue 4: VM Migration Fails

**Symptom:** Can't migrate VM to another node

**Check:**

```bash
# 1. Verify shared storage
pvesm status | grep shared

# san-storage should show "shared: 1"

# 2. Check LVM VG active on target node
ssh node2 "vgs | grep san-storage"

# 3. Check multipath on target
ssh node2 "multipath -ll"

# 4. Force VG activation
ssh node2 "vgchange -ay san-storage"

# 5. Retry migration
qm migrate <vmid> <target-node> --online
```

---

### Issue 5: Low Performance

**Symptom:** Poor IOPS or throughput

**Diagnostics:**

```bash
# 1. Test iSCSI network
iperf3 -s  # On Proxmox node
iperf3 -c 192.168.10.11  # From another node

# Should see near line-rate (10G = 9.4 Gbps, 25G = 23.5 Gbps)

# 2. Test ME5224 directly
apt install fio

fio --filename=/dev/mapper/mpatha \
    --name=randread \
    --ioengine=libaio \
    --iodepth=32 \
    --rw=randread \
    --bs=4k \
    --direct=1 \
    --size=1G \
    --numjobs=4 \
    --runtime=30 \
    --group_reporting

# Expected: >50k IOPS for random 4K reads

# 3. Check multipath load balancing
iostat -x 2 10

# All paths (sdd, sde, sdf, sdg) should show similar utilization

# 4. Verify cache settings in VM
qm config <vmid> | grep cache

# Should be: cache=directsync or cache=none
```

**Optimization:**

```bash
# 1. Tune Proxmox VM disk settings
qm set <vmid> --scsi0 san-storage:vm-<vmid>-disk-0,cache=directsync,iothread=1,ssd=1

# 2. Enable discard/TRIM
qm set <vmid> --scsi0 san-storage:vm-<vmid>-disk-0,discard=on

# 3. Inside VM, enable deadline scheduler
echo deadline > /sys/block/sda/queue/scheduler
```

---

### Issue 6: Proxmox CSI Can't Create Volumes

**Symptom:** PVC creation fails with API errors

**Check CSI logs:**

```bash
kubectl logs -n csi-proxmox proxmox-csi-controller-0 -c csi-provisioner

# Look for authentication errors
```

**Verify API access:**

```bash
# Test API token
curl -k -H "Authorization: PVEAPIToken=csi@pve!csi-token=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" \
  https://192.168.1.10:8006/api2/json/version

# Should return Proxmox version JSON

# If fails, regenerate token
pveum user token add csi@pve csi-token --privsep 0
```

**Check permissions:**

```bash
# Verify CSI user has correct roles
pveum user list | grep csi

pveum acl list | grep csi

# Re-grant if needed
pveum acl modify / --user csi@pve --role PVESDNAdmin
pveum acl modify / --user csi@pve --role PVEVMAdmin
```

---

## Monitoring Commands Reference

### Proxmox Side

```bash
# Check multipath health
multipath -ll

# Check iSCSI sessions
iscsiadm -m session

# Check LVM
vgs; lvs; pvs

# Check storage
pvesm status

# Monitor I/O
iostat -x 2

# Check network
iftop -i <interface>
```

### Kubernetes Side

```bash
# Check CSI pods
kubectl get pods -n csi-proxmox -o wide

# Check PVCs
kubectl get pvc --all-namespaces

# Check PVs
kubectl get pv

# Check storage classes
kubectl get storageclass

# Check CSI capacity
kubectl get csistoragecapacities -A

# Check volume attachments
kubectl get volumeattachment
```

### ME5224 Side

**Via Web UI:**
- Dashboard → Performance graphs
- Volumes → Check I/O stats
- Controllers → Health status
- Events → Recent alerts

**Via CLI (if available):**
```bash
# Show volumes
show volumes

# Show I/O statistics
show volume-statistics

# Show controller status
show controllers
```

---

# References

## Official Documentation

- **Proxmox LVM Shared Storage Guide:**  
  https://kb.blockbridge.com/technote/proxmox-lvm-shared-storage/

- **Proxmox CSI Plugin:**  
  https://github.com/sergelogvinov/proxmox-csi-plugin

- **Seagate Exos X CSI:**  
  https://github.com/Seagate/seagate-exos-x-csi

- **Proxmox VE Documentation:**  
  https://pve.proxmox.com/wiki/Main_Page

- **Dell ME5 Series User Guide:**  
  https://www.dell.com/support/manuals/powervault-me5

- **Linux Multipath Documentation:**  
  https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/dm-multipath.html

## Community Resources

- **Proxmox Forum:**  
  https://forum.proxmox.com/

- **Proxmox CSI GitHub Issues:**  
  https://github.com/sergelogvinov/proxmox-csi-plugin/issues

- **Reddit r/Proxmox:**  
  https://www.reddit.com/r/Proxmox/

## Tools and Utilities

- **fio** - I/O benchmarking  
  https://fio.readthedocs.io/

- **iperf3** - Network performance testing  
  https://iperf.fr/

- **lsscsi** - List SCSI devices  
  Install: `apt install lsscsi`

- **multipath-tools** - Device mapper multipath  
  Install: `apt install multipath-tools`

---

# Conclusion

This guide covered three distinct approaches to Dell ME5224 storage integration:

1. **VM-Focused:** Traditional shared LVM for Proxmox VMs with HA
2. **K8s Option A:** Direct SAN CSI (Seagate Exos X)
3. **K8s Option B:** Proxmox-mediated CSI

## Recommended Path

For most users, we recommend:

1. **Start with VM-focused approach (Part 1)**
   - Provides immediate value for VMs
   - Foundation for Option B

2. **For Kubernetes, use Proxmox CSI (Option B)**
   - More mature and stable
   - Simpler setup
   - Better integration

3. **Try Seagate CSI (Option A) only if:**
   - You need direct SAN control
   - Proxmox CSI doesn't meet needs
   - You're comfortable with community support

## Next Steps

After completing this guide:

1. ✅ Monitor performance for 1-2 weeks
2. ✅ Test failover scenarios
3. ✅ Document your specific configurations
4. ✅ Set up monitoring/alerting
5. ✅ Plan backup strategy

**Good luck with your deployment!** 🚀

---

**Document Version:** 1.0  
**Last Updated:** December 2025  
**Author:** Infrastructure Team  
**License:** CC BY-SA 4.0