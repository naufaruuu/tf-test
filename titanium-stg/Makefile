init:
	@command -v sshpass >/dev/null 2>&1 || { echo "Error: sshpass is not installed. Please install it first."; exit 1; }
	tofu init


plan:
	@command -v sshpass >/dev/null 2>&1 || { echo "Error: sshpass is not installed. Please install it first."; exit 1; }
	tofu plan

apply:
	tofu apply
	tofu output -raw kubeconfig > kubeconfig.yaml
	tofu output -raw talosconfig > talosconfig.yaml

apply-nginx:
	tofu apply -target=module.nginx_lb

apply-master:
	tofu apply -target=module.talos_master

apply-worker:
	tofu apply -target=module.talos_worker

export:
	tofu output -raw kubeconfig > kubeconfig.yaml
	tofu output -raw talosconfig > talosconfig.yaml

update-master:
	tofu apply -target='module.talos_master.proxmox_virtual_environment_vm.master["master-0"]'
	tofu apply -target='module.talos_master.proxmox_virtual_environment_vm.master["master-1"]'
	tofu apply -target='module.talos_master.proxmox_virtual_environment_vm.master["master-2"]'
