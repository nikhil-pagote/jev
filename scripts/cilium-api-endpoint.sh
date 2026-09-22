#!/usr/bin/env bash
# Resolves the in-cluster Kubernetes API server address/port that Cilium's
# agents must use for k8sServiceHost/k8sServicePort. Works even before any
# CNI is installed because the apiserver itself populates the "kubernetes"
# Endpoints object, independent of pod networking.
set -euo pipefail

API_IP=$(kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}')
API_PORT=$(kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[0].ports[0].port}')

echo "${API_IP} ${API_PORT}"
