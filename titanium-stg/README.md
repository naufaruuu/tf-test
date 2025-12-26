# Talos Kubernetes on Proxmox - Terraform

This Terraform configuration deploys a Talos Kubernetes cluster on Proxmox VE.

## Architecture

```
terraform/
├── hasunosora-k8s/          # Main cluster configuration
│   ├── main.tf              # Shared configuration (proxmox, network, cluster)
│   ├── versions.tf          # Provider versions
│   ├── talos-master.tf      # Master nodes configuration
│   ├── talos-worker.tf      # Worker nodes configuration
│   └── lxc.tf               # LXC containers (if any)
└── modules/
    ├── terraform-talos-secrets/        # Generates Talos secrets and machine configs
    ├── terraform-proxmox-talos-master/ # Creates and configures master VMs
    ├── terraform-proxmox-talos-worker/ # Creates and configures worker VMs
    └── terraform-proxmox-lxc/          # LXC container module
```

## Cluster Specifications

| Component | Value |
|-----------|-------|
| Cluster Name | `hasunosora` |
| Talos Version | v1.11.6 |
| Kubernetes Version | v1.34.2 |
| Pod CIDR | 10.100.0.0/16 |
| Service CIDR | 10.200.0.0/16 |
| CNI | Cilium (kube-proxy disabled, flannel disabled) |
| Network MTU | 1492 (PPPoE) |

## Nodes

### Master Nodes (Control Plane)

| Name | IP | CPU | Memory | Disk | Proxmox Host |
|------|-----|-----|--------|------|--------------|
| master-0 | 192.168.18.210 | 2 | 4GB | 20GB | ayumu |
| master-1 | 192.168.18.211 | 2 | 4GB | 20GB | ayumu |
| master-2 | 192.168.18.212 | 2 | 4GB | 20GB | ayumu |

### Worker Nodes

| Name | IP | CPU | Memory | Disk | Workload | Proxmox Host |
|------|-----|-----|--------|------|----------|--------------|
| worker-tier-0 | 192.168.18.213 | 2 | 4GB | 20GB | tier-0 | ayumu |
| worker-tier-core-naufal | 192.168.18.217 | 2 | 4GB | 20GB | tier-core | ayumu |

## Features

### Node Labels (Workers)

Worker nodes are automatically labeled with:

- `node.kubernetes.io/cluster` - Cluster name
- `node.kubernetes.io/ip` - Node IP address
- `node.kubernetes.io/cpu` - CPU cores
- `node.kubernetes.io/memory` - Memory in MB
- `node.kubernetes.io/proxmox-host` - Proxmox host name
- `node.kubernetes.io/workload` - Workload tier (if set)

### Node Taints (Workers)

Workers with a `workload` defined get tainted with:

```
workload=<tier>:NoSchedule
```

### Graceful Node Cleanup

When destroying VMs, the modules automatically:

1. Drain the node (`kubectl drain`)
2. Delete from Kubernetes (`kubectl delete node`)
3. For masters: Remove from etcd cluster (`talosctl etcd remove-member`)

## Prerequisites

- Proxmox VE 8.x
- Talos nocloud ISO uploaded to Proxmox (`talos-nocloud-1.11.6.iso`)
- Terraform >= 1.6.0 or OpenTofu

## Providers

| Provider | Version | Purpose |
|----------|---------|---------|
| bpg/proxmox | >= 0.73.0 | Proxmox VE management |
| siderolabs/talos | >= 0.7.0 | Talos configuration |
| hashicorp/null | >= 3.2.0 | Provisioners |
| hashicorp/external | >= 2.3.0 | External data sources |

## Usage

### Initialize

```bash
cd terraform/hasunosora-k8s
terraform init
```

### Plan

```bash
terraform plan
```

### Apply

```bash
terraform apply
```

### Get Kubeconfig

```bash
terraform output -raw kubeconfig > kubeconfig.yaml
export KUBECONFIG=$(pwd)/kubeconfig.yaml
kubectl get nodes
```

### Get Talosconfig

```bash
terraform output -raw talosconfig > talosconfig.yaml
talosctl --talosconfig talosconfig.yaml -n 192.168.18.210 health
```

## Module Reference

### terraform-proxmox-talos-master

Creates Talos control plane VMs on Proxmox.

**Inputs:**

| Variable | Type | Description |
|----------|------|-------------|
| `cluster_config` | object | Cluster name, endpoint, kubernetes version, interfaces, root_disk |
| `talos_secrets` | object | Client configuration and controlplane machine configuration |
| `master_config` | object | ISO filename, installer image, kernel modules |
| `master_vms` | map(map(object)) | VM definitions grouped by Proxmox host |
| `network` | object | Gateway, CIDR, DNS, MTU |
| `proxmox` | object | Proxmox connection details |
| `master_ips` | list(string) | Static list of master IPs |
| `kubeconfig_path` | string | Path to kubeconfig for cleanup |
| `talosconfig_path` | string | Path to talosconfig for cleanup |

**Outputs:**

| Output | Description |
|--------|-------------|
| `kubeconfig` | Kubernetes kubeconfig |
| `talosconfig` | Talos client configuration |
| `cluster_endpoint` | Kubernetes API endpoint |
| `master_ips` | List of master IP addresses |
| `master_vm_ids` | Map of VM IDs |

### terraform-proxmox-talos-worker

Creates Talos worker VMs on Proxmox.

**Inputs:**

| Variable | Type | Description |
|----------|------|-------------|
| `cluster_config` | object | Cluster name, endpoint, kubernetes version, interfaces, root_disk |
| `talos_secrets` | object | Client configuration and worker machine configuration |
| `worker_config` | object | ISO filename, installer image, kernel modules |
| `worker_vms` | map(map(object)) | VM definitions grouped by Proxmox host |
| `network` | object | Gateway, CIDR, DNS, MTU |
| `proxmox` | object | Proxmox connection details |
| `kubeconfig_path` | string | Path to kubeconfig for cleanup |

**VM Object:**

```hcl
{
  ip              = string  # Static IP address
  cpu             = number  # CPU cores
  ram_dedicated   = number  # Memory in MB
  disk_size       = number  # Disk size in GB
  bandwidth_limit = number  # Network bandwidth limit (0 = unlimited)
  datastore_id    = string  # Proxmox storage ID
  workload        = string  # Optional: workload tier for labels/taints
}
```

**Outputs:**

| Output | Description |
|--------|-------------|
| `worker_ips` | List of worker IP addresses |
| `worker_vm_ids` | Map of VM IDs |

## Deployment Flow

1. **Secrets Generation**: `terraform-talos-secrets` generates cluster secrets
2. **VM Creation**: Master and worker VMs created on Proxmox (parallel)
3. **Config Apply**: Talos machine configuration applied to all masters (parallel)
4. **Wait for API**: Wait for master-0 apid to be ready
5. **Bootstrap**: Bootstrap cluster on master-0
6. **etcd Formation**: Wait for all masters to join etcd as voters
7. **Worker Config**: Apply configuration to worker nodes
8. **Kubeconfig**: Retrieve kubeconfig from cluster

## Maintenance

### Modifying Master Nodes

When making changes that restart master VMs, apply one at a time:

```bash
terraform apply -target='module.talos_master.proxmox_virtual_environment_vm.master["master-0"]'
terraform apply -target='module.talos_master.proxmox_virtual_environment_vm.master["master-1"]'
terraform apply -target='module.talos_master.proxmox_virtual_environment_vm.master["master-2"]'
```

### Adding a Worker

1. Add the worker definition to `talos-worker.tf`:

```hcl
"worker-new" = {
  ip              = "192.168.18.218"
  cpu             = 2
  ram_dedicated   = 4096
  disk_size       = 20
  bandwidth_limit = 100
  datastore_id    = "teamgroup-ssd"
  workload        = "tier-0"
}
```

2. Apply:

```bash
terraform apply
```

### Removing a Worker

1. Remove the worker from `talos-worker.tf`
2. Apply - the destroy provisioner will drain and delete the node automatically:

```bash
terraform apply
```

## Troubleshooting

### Check Talos Node Status

```bash
talosctl --talosconfig talosconfig.yaml -n 192.168.18.210 -e 192.168.18.210 get machinestatus
```

### Check etcd Members

```bash
talosctl --talosconfig talosconfig.yaml -n 192.168.18.210 -e 192.168.18.210 etcd members
```

### Check Services

```bash
talosctl --talosconfig talosconfig.yaml -n 192.168.18.210 -e 192.168.18.210 services
```

### View Logs

```bash
talosctl --talosconfig talosconfig.yaml -n 192.168.18.210 -e 192.168.18.210 logs kubelet
```
