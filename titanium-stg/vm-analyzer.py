#!/usr/bin/env python3
"""
VM Analyzer - Analyzes Terraform VM configurations for resource utilization and CPU affinity.

Usage: python3 vm-analyzer.py
"""

import re
import sys
import argparse
from pathlib import Path
from dataclasses import dataclass, field
from typing import Dict, List, Set, Tuple, Optional
from collections import defaultdict

# =============================================================================
# NODE CONFIGURATION - Define your Proxmox hosts here
# =============================================================================
NODES = {
    "ayumu": {
        "sockets": 1,
        "cores": 16,        # Total CPU cores
        "memory": 61440,   # Memory in MB (60GB)
    },
    # Add more nodes here:
    # "node2": {
    #     "sockets": 2,
    #     "cores": 16,
    #     "memory": 131072,  # 128GB
    # },
}

# =============================================================================

# ANSI colors
class Colors:
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    MAGENTA = '\033[95m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    BOLD = '\033[1m'
    RESET = '\033[0m'

@dataclass
class VM:
    name: str
    host_node: str
    role: str  # "master" or "worker"
    ip: str
    cpu: int
    cpu_affinity: str
    numa: bool
    ram_dedicated: int  # MB
    disk_size: int  # GB
    bandwidth_limit: int
    datastore_id: str
    workload: Optional[str] = None
    additional_disks: Dict[str, dict] = field(default_factory=dict)

def parse_affinity(affinity: str) -> Set[int]:
    """Parse CPU affinity string like '0-1' or '0,2,4' into set of CPU numbers."""
    cpus = set()
    if not affinity:
        return cpus

    for part in affinity.split(','):
        part = part.strip()
        if '-' in part:
            start, end = part.split('-')
            cpus.update(range(int(start), int(end) + 1))
        else:
            cpus.add(int(part))
    return cpus

def parse_terraform_block(content: str, block_name: str) -> str:
    """Extract a Terraform block by name."""
    pattern = rf'{block_name}\s*=\s*\{{'
    match = re.search(pattern, content)
    if not match:
        return ""

    start = match.end() - 1
    depth = 0
    end = start

    for i, char in enumerate(content[start:], start):
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                end = i + 1
                break

    return content[start:end]

def extract_vms_from_block(block: str, host_node: str, role: str) -> List[VM]:
    """Extract VM definitions from a Terraform block."""
    vms = []

    # Find all VM definitions (quoted keys followed by block)
    vm_pattern = r'"([^"]+)"\s*=\s*\{'

    pos = 0
    while True:
        match = re.search(vm_pattern, block[pos:])
        if not match:
            break

        vm_name = match.group(1)
        block_start = pos + match.end() - 1

        # Find matching closing brace
        depth = 0
        block_end = block_start
        for i, char in enumerate(block[block_start:], block_start):
            if char == '{':
                depth += 1
            elif char == '}':
                depth -= 1
                if depth == 0:
                    block_end = i + 1
                    break

        vm_block = block[block_start:block_end]

        # Extract VM properties
        def get_value(pattern: str, default: str = "") -> str:
            m = re.search(pattern, vm_block)
            return m.group(1) if m else default

        def get_int(pattern: str, default: int = 0) -> int:
            m = re.search(pattern, vm_block)
            return int(m.group(1)) if m else default

        def get_bool(pattern: str, default: bool = False) -> bool:
            m = re.search(pattern, vm_block)
            return m.group(1).lower() == 'true' if m else default

        vm = VM(
            name=vm_name,
            host_node=host_node,
            role=role,
            ip=get_value(r'ip\s*=\s*"([^"]+)"'),
            cpu=get_int(r'cpu\s*=\s*(\d+)'),
            cpu_affinity=get_value(r'cpu_affinity\s*=\s*"([^"]*)"'),
            numa=get_bool(r'numa\s*=\s*(true|false)'),
            ram_dedicated=get_int(r'ram_dedicated\s*=\s*(\d+)'),
            disk_size=get_int(r'disk_size\s*=\s*(\d+)'),
            bandwidth_limit=get_int(r'bandwidth_limit\s*=\s*(\d+)'),
            datastore_id=get_value(r'datastore_id\s*=\s*"([^"]+)"'),
            workload=get_value(r'workload\s*=\s*"([^"]+)"') or None,
        )

        # Extract additional disks
        disks_match = re.search(r'additional_disks\s*=\s*\{', vm_block)
        if disks_match:
            disks_start = disks_match.end() - 1
            depth = 0
            disks_end = disks_start
            for i, char in enumerate(vm_block[disks_start:], disks_start):
                if char == '{':
                    depth += 1
                elif char == '}':
                    depth -= 1
                    if depth == 0:
                        disks_end = i + 1
                        break
            disks_block = vm_block[disks_start:disks_end]

            # Parse individual disks
            disk_pattern = r'"([^"]+)"\s*=\s*\{'
            disk_pos = 0
            while True:
                disk_match = re.search(disk_pattern, disks_block[disk_pos:])
                if not disk_match:
                    break
                disk_name = disk_match.group(1)
                disk_block_start = disk_pos + disk_match.end() - 1
                depth = 0
                disk_block_end = disk_block_start
                for i, char in enumerate(disks_block[disk_block_start:], disk_block_start):
                    if char == '{':
                        depth += 1
                    elif char == '}':
                        depth -= 1
                        if depth == 0:
                            disk_block_end = i + 1
                            break
                disk_block = disks_block[disk_block_start:disk_block_end]
                size_match = re.search(r'size\s*=\s*(\d+)', disk_block)
                vm.additional_disks[disk_name] = {
                    'size': int(size_match.group(1)) if size_match else 0
                }
                disk_pos = disk_block_end

        vms.append(vm)
        pos = block_end

    return vms

def parse_tf_files(directory: Path) -> List[VM]:
    """Parse all .tf files in directory and extract VM definitions."""
    vms = []

    for tf_file in directory.glob("*.tf"):
        content = tf_file.read_text()

        # Determine role from filename or content
        if "master" in tf_file.name.lower() or "master_vms" in content:
            role = "master"
            vms_block_name = "master_vms"
        elif "worker" in tf_file.name.lower() or "worker_vms" in content:
            role = "worker"
            vms_block_name = "worker_vms"
        else:
            continue

        # Extract the VMs block
        vms_block = parse_terraform_block(content, vms_block_name)
        if not vms_block:
            continue

        # Find host nodes (first level keys)
        host_pattern = r'"([^"]+)"\s*=\s*\{'
        pos = 1  # Skip opening brace
        while True:
            match = re.search(host_pattern, vms_block[pos:])
            if not match:
                break

            host_node = match.group(1)
            host_start = pos + match.end() - 1

            # Find matching closing brace for host block
            depth = 0
            host_end = host_start
            for i, char in enumerate(vms_block[host_start:], host_start):
                if char == '{':
                    depth += 1
                elif char == '}':
                    depth -= 1
                    if depth == 0:
                        host_end = i + 1
                        break

            host_block = vms_block[host_start:host_end]
            vms.extend(extract_vms_from_block(host_block, host_node, role))
            pos = host_end

    return vms

def analyze_vms(vms: List[VM]):
    """Analyze VMs and print report."""

    # Group by host
    by_host: Dict[str, List[VM]] = defaultdict(list)
    for vm in vms:
        by_host[vm.host_node].append(vm)

    print(f"\n{Colors.BOLD}{'='*80}{Colors.RESET}")
    print(f"{Colors.BOLD}{Colors.CYAN}VM RESOURCE ANALYSIS REPORT{Colors.RESET}")
    print(f"{Colors.BOLD}{'='*80}{Colors.RESET}\n")

    # =========================================================================
    # 1. Overall Node Utilization
    # =========================================================================
    print(f"{Colors.BOLD}{Colors.BLUE}1. OVERALL NODE UTILIZATION{Colors.RESET}")
    print(f"{'-'*80}\n")

    for host, host_vms in sorted(by_host.items()):
        # Get host specs from NODES config
        node_config = NODES.get(host, {"cores": 8, "memory": 32768, "sockets": 1})
        host_cpus = node_config["cores"]
        host_memory = node_config["memory"]
        host_sockets = node_config.get("sockets", 1)

        total_vcpu = sum(vm.cpu for vm in host_vms)
        total_memory = sum(vm.ram_dedicated for vm in host_vms)
        total_disk = sum(vm.disk_size + sum(d['size'] for d in vm.additional_disks.values()) for vm in host_vms)

        cpu_pct = (total_vcpu / host_cpus) * 100 if host_cpus else 0
        mem_pct = (total_memory / host_memory) * 100 if host_memory else 0

        cpu_color = Colors.GREEN if cpu_pct <= 80 else Colors.YELLOW if cpu_pct <= 100 else Colors.RED
        mem_color = Colors.GREEN if mem_pct <= 80 else Colors.YELLOW if mem_pct <= 100 else Colors.RED

        print(f"{Colors.BOLD}Host: {host}{Colors.RESET} ({host_sockets} socket, {host_cpus} cores, {host_memory/1024:.0f}GB RAM)")
        print(f"  VMs: {len(host_vms)}")
        print(f"  vCPUs: {total_vcpu}/{host_cpus} ({cpu_color}{cpu_pct:.1f}%{Colors.RESET})")
        print(f"  Memory: {total_memory}MB/{host_memory}MB ({mem_color}{mem_pct:.1f}%{Colors.RESET})")
        print(f"  Total Disk: {total_disk}GB")
        print()

        # Per-VM details
        print(f"  {'VM Name':<25} {'Role':<8} {'vCPU':<6} {'RAM':<10} {'Affinity':<12} {'NUMA':<6} {'Workload':<15}")
        print(f"  {'-'*25} {'-'*8} {'-'*6} {'-'*10} {'-'*12} {'-'*6} {'-'*15}")

        for vm in sorted(host_vms, key=lambda v: v.name):
            print(f"  {vm.name:<25} {vm.role:<8} {vm.cpu:<6} {vm.ram_dedicated:<10} {vm.cpu_affinity or 'N/A':<12} {str(vm.numa):<6} {vm.workload or '-':<15}")
        print()

    # =========================================================================
    # 2. CPU Affinity Analysis
    # =========================================================================
    print(f"\n{Colors.BOLD}{Colors.BLUE}2. CPU AFFINITY ANALYSIS{Colors.RESET}")
    print(f"{'-'*80}\n")

    for host, host_vms in sorted(by_host.items()):
        node_config = NODES.get(host, {"cores": 8, "memory": 32768, "sockets": 1})
        host_cpus = node_config["cores"]

        print(f"{Colors.BOLD}Host: {host}{Colors.RESET}")

        # Collect all used CPUs
        used_cpus: Dict[int, List[str]] = defaultdict(list)
        all_used_cpus: Set[int] = set()

        for vm in host_vms:
            affinity_cpus = parse_affinity(vm.cpu_affinity)
            all_used_cpus.update(affinity_cpus)
            for cpu in affinity_cpus:
                used_cpus[cpu].append(vm.name)

        # Find overlapping CPUs
        overlapping = {cpu: vms for cpu, vms in used_cpus.items() if len(vms) > 1}

        # Find free CPUs
        all_cpus = set(range(host_cpus))
        free_cpus = all_cpus - all_used_cpus

        # VMs without affinity
        no_affinity = [vm for vm in host_vms if not vm.cpu_affinity]

        # CPU usage visualization
        print(f"\n  CPU Map (0-{host_cpus-1}):")
        print(f"  ", end="")
        for cpu in range(host_cpus):
            if cpu in overlapping:
                print(f"{Colors.RED}{Colors.BOLD}█{Colors.RESET}", end="")
            elif cpu in all_used_cpus:
                print(f"{Colors.GREEN}█{Colors.RESET}", end="")
            else:
                print(f"{Colors.WHITE}░{Colors.RESET}", end="")
            if (cpu + 1) % 8 == 0:
                print(" ", end="")
        print()

        # CPU numbers row
        print(f"  ", end="")
        for cpu in range(host_cpus):
            print(f"{cpu % 10}", end="")
            if (cpu + 1) % 8 == 0:
                print(" ", end="")
        print()

        print(f"\n  Legend: {Colors.GREEN}█{Colors.RESET} used   {Colors.WHITE}░{Colors.RESET} free   {Colors.RED}{Colors.BOLD}█{Colors.RESET} overlap")

        # Free CPU ranges
        if free_cpus:
            ranges = []
            sorted_free = sorted(free_cpus)
            start = sorted_free[0]
            end = start
            for cpu in sorted_free[1:]:
                if cpu == end + 1:
                    end = cpu
                else:
                    ranges.append(f"{start}-{end}" if start != end else str(start))
                    start = end = cpu
            ranges.append(f"{start}-{end}" if start != end else str(start))
            print(f"\n  {Colors.GREEN}Free CPU ranges:{Colors.RESET} {', '.join(ranges)}")
            print(f"  {Colors.GREEN}Free CPU count:{Colors.RESET} {len(free_cpus)}")
        else:
            print(f"\n  {Colors.YELLOW}No free CPUs available!{Colors.RESET}")

        # Overlapping warnings
        if overlapping:
            print(f"\n  {Colors.RED}{Colors.BOLD}OVERLAPPING CPU AFFINITY DETECTED!{Colors.RESET}")
            for cpu, vm_names in sorted(overlapping.items()):
                print(f"    CPU {cpu}: {', '.join(vm_names)}")
        else:
            print(f"\n  {Colors.GREEN}No CPU affinity overlaps detected.{Colors.RESET}")

        # VMs without affinity
        if no_affinity:
            print(f"\n  {Colors.YELLOW}VMs without CPU affinity:{Colors.RESET}")
            for vm in no_affinity:
                print(f"    - {vm.name}")

        print()

    # =========================================================================
    # 3. Network Analysis
    # =========================================================================
    print(f"\n{Colors.BOLD}{Colors.BLUE}3. NETWORK ANALYSIS{Colors.RESET}")
    print(f"{'-'*80}\n")

    # IP allocation
    ips = [(vm.ip, vm.name, vm.host_node) for vm in vms]
    print(f"  {'IP Address':<20} {'VM Name':<25} {'Host':<15}")
    print(f"  {'-'*20} {'-'*25} {'-'*15}")
    for ip, name, host in sorted(ips):
        print(f"  {ip:<20} {name:<25} {host:<15}")

    # Check for duplicate IPs
    ip_counts = defaultdict(list)
    for vm in vms:
        ip_counts[vm.ip].append(vm.name)

    duplicates = {ip: names for ip, names in ip_counts.items() if len(names) > 1}
    if duplicates:
        print(f"\n  {Colors.RED}{Colors.BOLD}DUPLICATE IP ADDRESSES DETECTED!{Colors.RESET}")
        for ip, names in duplicates.items():
            print(f"    {ip}: {', '.join(names)}")
    else:
        print(f"\n  {Colors.GREEN}No duplicate IP addresses.{Colors.RESET}")

    # Bandwidth limits
    limited = [(vm.name, vm.bandwidth_limit) for vm in vms if vm.bandwidth_limit > 0]
    if limited:
        print(f"\n  VMs with bandwidth limits:")
        for name, limit in sorted(limited):
            print(f"    {name}: {limit} MB/s")

    # =========================================================================
    # 4. Storage Analysis
    # =========================================================================
    print(f"\n{Colors.BOLD}{Colors.BLUE}4. STORAGE ANALYSIS{Colors.RESET}")
    print(f"{'-'*80}\n")

    # By datastore
    by_datastore: Dict[str, List[Tuple[str, int]]] = defaultdict(list)
    for vm in vms:
        total_size = vm.disk_size + sum(d['size'] for d in vm.additional_disks.values())
        by_datastore[vm.datastore_id].append((vm.name, total_size))

    for ds, items in sorted(by_datastore.items()):
        total = sum(size for _, size in items)
        print(f"  {Colors.BOLD}Datastore: {ds}{Colors.RESET}")
        print(f"    Total allocated: {total}GB")
        print(f"    VMs: {len(items)}")
        for name, size in sorted(items):
            print(f"      {name}: {size}GB")
        print()

    # VMs with additional disks
    with_disks = [vm for vm in vms if vm.additional_disks]
    if with_disks:
        print(f"  VMs with additional disks:")
        for vm in with_disks:
            disks_str = ", ".join(f"{k}:{v['size']}GB" for k, v in vm.additional_disks.items())
            print(f"    {vm.name}: {disks_str}")

    # =========================================================================
    # 5. Recommendations
    # =========================================================================
    print(f"\n{Colors.BOLD}{Colors.BLUE}5. RECOMMENDATIONS{Colors.RESET}")
    print(f"{'-'*80}\n")

    recommendations = []

    # Check for overlapping affinities
    for host, host_vms in by_host.items():
        used_cpus: Dict[int, List[str]] = defaultdict(list)
        for vm in host_vms:
            for cpu in parse_affinity(vm.cpu_affinity):
                used_cpus[cpu].append(vm.name)
        overlapping = {cpu: vms for cpu, vms in used_cpus.items() if len(vms) > 1}
        if overlapping:
            recommendations.append(f"{Colors.RED}[CRITICAL]{Colors.RESET} Host '{host}' has overlapping CPU affinities. Fix immediately for CPU pinning to work correctly.")

    # Check for missing affinities
    for vm in vms:
        if not vm.cpu_affinity:
            recommendations.append(f"{Colors.YELLOW}[WARNING]{Colors.RESET} VM '{vm.name}' has no CPU affinity set.")

    # Check for NUMA consistency
    for host, host_vms in by_host.items():
        numa_enabled = [vm for vm in host_vms if vm.numa]
        numa_disabled = [vm for vm in host_vms if not vm.numa]
        if numa_enabled and numa_disabled:
            recommendations.append(f"{Colors.YELLOW}[WARNING]{Colors.RESET} Host '{host}' has mixed NUMA settings. Consider enabling NUMA for all VMs for consistency.")

    # Check for overcommit
    for host, host_vms in by_host.items():
        node_config = NODES.get(host, {"cores": 8, "memory": 32768, "sockets": 1})
        host_cpus = node_config["cores"]
        host_memory = node_config["memory"]

        total_vcpu = sum(vm.cpu for vm in host_vms)
        total_memory = sum(vm.ram_dedicated for vm in host_vms)
        if total_vcpu > host_cpus:
            recommendations.append(f"{Colors.YELLOW}[WARNING]{Colors.RESET} Host '{host}' has vCPU overcommit ({total_vcpu}/{host_cpus}). This may cause performance issues with CPU pinning.")
        if total_memory > host_memory:
            recommendations.append(f"{Colors.RED}[CRITICAL]{Colors.RESET} Host '{host}' has memory overcommit ({total_memory}MB/{host_memory}MB). VMs may fail to start or be OOM killed.")

    # Check for single points of failure
    masters_by_host = defaultdict(list)
    for vm in vms:
        if vm.role == "master":
            masters_by_host[vm.host_node].append(vm)

    if len(masters_by_host) == 1 and len(list(masters_by_host.values())[0]) > 1:
        recommendations.append(f"{Colors.YELLOW}[WARNING]{Colors.RESET} All master nodes are on a single host. Consider distributing across hosts for HA.")

    if recommendations:
        for rec in recommendations:
            print(f"  {rec}")
    else:
        print(f"  {Colors.GREEN}No issues found. Configuration looks good!{Colors.RESET}")

    print(f"\n{Colors.BOLD}{'='*80}{Colors.RESET}\n")

def main():
    parser = argparse.ArgumentParser(description="Analyze Terraform VM configurations")
    parser.add_argument("--dir", type=str, default=".", help="Directory containing .tf files")
    args = parser.parse_args()

    directory = Path(args.dir)
    if not directory.exists():
        print(f"Error: Directory '{directory}' does not exist")
        sys.exit(1)

    vms = parse_tf_files(directory)

    if not vms:
        print("No VMs found in Terraform files")
        sys.exit(1)

    # Print node configuration
    print(f"\n{Colors.BOLD}Configured Nodes:{Colors.RESET}")
    for name, config in NODES.items():
        print(f"  {name}: {config['cores']} cores, {config['memory']/1024:.0f}GB RAM, {config.get('sockets', 1)} socket(s)")

    print(f"\nFound {len(vms)} VMs in Terraform configuration")
    analyze_vms(vms)

if __name__ == "__main__":
    main()
