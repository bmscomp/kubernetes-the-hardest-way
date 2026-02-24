# Kubernetes on QEMU + NixOS (The Hardest Way)
# Orchestration Makefile

include cluster.env
export

.PHONY: help all download check \
        certs kubeconfigs encryption pki \
        configs-alpha configs-sigma configs-gamma configs prepare \
        install-alpha install-sigma install-gamma install \
        boot-alpha boot-sigma boot-gamma up down \
        wait status network dns metrics storage dashboard monitoring smoke test \
        snapshot restore reconfig \
        etcd-snapshot etcd-restore \
        add-worker remove-worker \
        ssh-alpha ssh-sigma ssh-gamma \
        clean clobber

help: ## Show this help message
	@echo "Kubernetes the Hardest Way — Deployment Automation"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Lifecycle:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

check: ## Verify prerequisites (QEMU, kubectl, expect, firmware)
	cd bin && ./check-prereqs.sh

download: ## Download the minimal NixOS base image
	cd bin && ./download-iso.sh

all: check download ## Full build: prereqs + PKI + install + boot + network + DNS
	cd bin && ./bootstrap-cluster.sh

certs: ## Generate PKI certificates (CA, components, nodes)
	cd bin && ./generate-certs.sh

kubeconfigs: ## Generate kubeconfig files for all components
	cd bin && ./generate-kubeconfigs.sh

encryption: ## Generate the etcd encryption configuration
	cd bin && ./generate-encryption-config.sh

pki: certs kubeconfigs encryption ## Generate all PKI assets

configs-alpha: ## Stage NixOS configs for the control plane (alpha)
	cd bin && ./generate-nocloud-iso.sh alpha

configs-sigma: ## Stage NixOS configs for worker 1 (sigma)
	cd bin && ./generate-nocloud-iso.sh sigma

configs-gamma: ## Stage NixOS configs for worker 2 (gamma)
	cd bin && ./generate-nocloud-iso.sh gamma

configs: configs-alpha configs-sigma configs-gamma ## Stage configs for all nodes

prepare: pki configs ## Generate all PKI assets and stage all node configs

install-alpha: ## One-time: Install NixOS on alpha via Live CD
	cd bin && ./provision.sh --iso alpha control-plane $(CONTROL_PLANE_MEM) $(MAC_alpha) $(SSH_PORTS_alpha)

install-sigma: ## One-time: Install NixOS on sigma via Live CD
	cd bin && ./provision.sh --iso sigma worker $(WORKER_MEM) $(MAC_sigma) $(SSH_PORTS_sigma)

install-gamma: ## One-time: Install NixOS on gamma via Live CD
	cd bin && ./provision.sh --iso gamma worker $(WORKER_MEM) $(MAC_gamma) $(SSH_PORTS_gamma)

install: install-alpha install-sigma install-gamma ## Install NixOS on all nodes sequentially

boot-alpha: ## Boot the already-installed Alpha control plane
	cd bin && ./provision.sh alpha control-plane $(CONTROL_PLANE_MEM) $(MAC_alpha) $(SSH_PORTS_alpha)

boot-sigma: ## Boot the already-installed Sigma worker
	cd bin && ./provision.sh sigma worker $(WORKER_MEM) $(MAC_sigma) $(SSH_PORTS_sigma)

boot-gamma: ## Boot the already-installed Gamma worker
	cd bin && ./provision.sh gamma worker $(WORKER_MEM) $(MAC_gamma) $(SSH_PORTS_gamma)

up: boot-alpha boot-sigma boot-gamma ## Boot all installed nodes

down: ## Gracefully shut down all nodes
	cd bin && ./shutdown.sh

wait: ## Show a live dashboard while waiting for the cluster to boot
	cd bin && ./wait-for-cluster.sh

status: ## Show comprehensive cluster health status
	cd bin && ./cluster-status.sh

network: ## Install Cilium CNI + RBAC + node labels + endpoint fix
	export KUBECONFIG=$(PWD)/configs/admin.kubeconfig && cd bin && ./install-cilium.sh

dns: network ## Deploy CoreDNS for cluster DNS (10.32.0.10)
	cd bin && ./deploy-coredns.sh

metrics: ## Deploy Metrics Server (kubectl top nodes/pods)
	cd bin && ./deploy-metrics-server.sh

storage: ## Deploy local-path-provisioner for PVCs
	cd bin && ./deploy-local-storage.sh

smoke: ## Deploy nginx and verify pod networking
	@export KUBECONFIG=$(PWD)/configs/admin.kubeconfig && \
	kubectl create deployment nginx --image=nginx --dry-run=client -o yaml | kubectl apply -f - && \
	kubectl expose deployment nginx --port 80 --type NodePort --dry-run=client -o yaml | kubectl apply -f - && \
	echo "Waiting for nginx rollout..." && \
	kubectl rollout status deployment/nginx --timeout=120s && \
	echo "" && echo "Smoke test passed! Nginx is running:" && \
	kubectl get pods -l app=nginx -o wide

test: ## Run the full cluster test suite
	cd bin && ./test-cluster.sh

add-worker: ## Add a new worker node (usage: make add-worker NAME=delta)
	@[ -n "$(NAME)" ] || (echo "Usage: make add-worker NAME=<worker-name>" && exit 1)
	cd bin && ./add-worker.sh $(NAME)

remove-worker: ## Remove a worker node (usage: make remove-worker NAME=sigma)
	@[ -n "$(NAME)" ] || (echo "Usage: make remove-worker NAME=<worker-name>" && exit 1)
	cd bin && ./remove-worker.sh $(NAME)

dashboard: ## Deploy Kubernetes Dashboard web UI
	cd bin && ./deploy-dashboard.sh

monitoring: ## Deploy Prometheus + Grafana monitoring stack
	cd bin && ./deploy-monitoring.sh

snapshot: ## Save cluster state for instant restore later
	cd bin && ./snapshot.sh

restore: ## Restore cluster from last snapshot (~30s vs ~15min rebuild)
	cd bin && ./restore.sh

reconfig: ## Push config changes to running nodes (no reinstall)
	cd bin && ./reconfig.sh

etcd-snapshot: ## Create an etcd data snapshot (saved to backups/)
	cd bin && ./etcd-backup.sh snapshot

etcd-restore: ## Restore etcd from the latest snapshot
	cd bin && ./etcd-backup.sh restore

ssh-alpha: ## SSH into the Alpha control plane
	ssh -p $(SSH_PORTS_alpha) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1

ssh-sigma: ## SSH into the Sigma worker
	ssh -p $(SSH_PORTS_sigma) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1

ssh-gamma: ## SSH into the Gamma worker
	ssh -p $(SSH_PORTS_gamma) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1

clean: ## Remove generated TLS certs, configs, and staging dirs
	rm -rf tls cloud-init
	find configs -type f ! -name "nixos-base.nix" -delete 2>/dev/null || true

clobber: clean ## Destroy everything including disk images (Caution!)
	rm -f images/*.qcow2 images/*-efivars.fd images/*-install.log images/*-console.log
	rm -rf backups logs

logs: ## Tail the latest build log
	@ls -t logs/*.log 2>/dev/null | head -1 | xargs tail -f 2>/dev/null || echo "No logs found. Run 'make all' first."
