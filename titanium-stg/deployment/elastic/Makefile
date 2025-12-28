repo:
	helm repo add elastic https://helm.elastic.co

install-operator:
	helm upgrade --install elastic-operator elastic/eck-operator -n logging --create-namespace -f operator.yaml

install:
	kubectl apply -f values.yaml
