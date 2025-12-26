# Install Cilium CNI with IPv6 support (using values file)
.PHONY: install
install:
	@echo "Installing Cilium CNI with dual-stack support..."
	helm upgrade --install cilium cilium/cilium \
		--namespace kube-system \
		--values values.yaml
	@echo "Cilium with dual-stack support installed!"