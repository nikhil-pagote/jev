CLUSTER_NAME := jev
NAMESPACE_ARGOCD := argocd
NAMESPACE_CILIUM := kube-system
KONG_PROXY_NODEPORT := 30080
KONG_MANAGER_NODEPORT := 30002
KONG_ADMIN_NODEPORT := 30001
HUBBLE_UI_NODEPORT := 30003

.PHONY: cluster cilium argocd bootstrap all urls destroy

# Cilium mounts bpffs and loads eBPF into the shared host kernel — this
# needs real host capabilities rootless Podman's userns doesn't have, so
# cluster creation runs under sudo (rootful Podman). `--kubeconfig ~/.kube/config`
# is expanded by your own shell before sudo runs, so it still lands in
# *your* home directory, not root's; the chown after makes it yours again.
cluster:
	sudo KIND_EXPERIMENTAL_PROVIDER=podman kind create cluster --config kind-config.yaml --kubeconfig ~/.kube/config
	sudo chown $$(id -u):$$(id -g) ~/.kube/config

cilium:
	helm repo add cilium https://helm.cilium.io --force-update
	helm repo update cilium
	$(eval API_ENDPOINT := $(shell ./scripts/cilium-api-endpoint.sh))
	$(eval API_IP := $(word 1,$(API_ENDPOINT)))
	$(eval API_PORT := $(word 2,$(API_ENDPOINT)))
	helm install cilium cilium/cilium \
		-n $(NAMESPACE_CILIUM) \
		--set kubeProxyReplacement=true \
		--set k8sServiceHost=$(API_IP) \
		--set k8sServicePort=$(API_PORT) \
		--set hubble.relay.enabled=true \
		--set hubble.ui.enabled=true \
		--set hubble.ui.service.type=NodePort \
		--set hubble.ui.service.nodePort=$(HUBBLE_UI_NODEPORT) \
		--wait --timeout 10m
	kubectl get nodes

argocd:
	helm repo add argo https://argoproj.github.io/argo-helm --force-update
	helm repo update argo
	helm install argocd argo/argo-cd \
		-n $(NAMESPACE_ARGOCD) --create-namespace \
		--set server.extraArgs="{--insecure,--rootpath=/argocd}" \
		--wait

bootstrap:
	kubectl apply -f bootstrap/root-app.yaml

all: cluster cilium argocd bootstrap

urls:
	@NODE_IP=$$(kubectl get nodes jev-control-plane -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'); \
	echo "Node IP: $$NODE_IP  (Kong proxy NodePort: $(KONG_PROXY_NODEPORT), Kong Manager NodePort: $(KONG_MANAGER_NODEPORT))"; \
	echo "  Grafana       http://$$NODE_IP:$(KONG_PROXY_NODEPORT)/grafana"; \
	echo "  Prometheus    http://$$NODE_IP:$(KONG_PROXY_NODEPORT)/prometheus"; \
	echo "  Jaeger        http://$$NODE_IP:$(KONG_PROXY_NODEPORT)/jaeger"; \
	echo "  ArgoCD        http://$$NODE_IP:$(KONG_PROXY_NODEPORT)/argocd"; \
	echo "  Kong Manager  http://$$NODE_IP:$(KONG_MANAGER_NODEPORT)/ (read-only, DB-less)"; \
	echo "  Kong Admin    http://$$NODE_IP:$(KONG_ADMIN_NODEPORT)/ (Admin API, read-only, DB-less)"; \
	echo "  Hubble UI     http://$$NODE_IP:$(HUBBLE_UI_NODEPORT)/ (own NodePort — its build hardcodes a root base path, can't live behind Kong's /hubble prefix)"

destroy:
	sudo KIND_EXPERIMENTAL_PROVIDER=podman kind delete cluster --name $(CLUSTER_NAME)
