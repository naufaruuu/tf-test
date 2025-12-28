repo:
	helm repo add fluent https://fluent.github.io/helm-charts

install:
	kubectl create ns logging || true
	helm upgrade --install fluent-bit fluent/fluent-bit -f values.yaml --namespace logging

delete:
	helm3 delete fluent-bit --namespace logging
