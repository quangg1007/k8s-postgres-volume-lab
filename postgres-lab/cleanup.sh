#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="postgres-lab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${CYAN}ℹ️  $1${NC}"; }
done_msg() { echo -e "${GREEN}✅ $1${NC}"; }
step() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

step "Cleaning up PostgreSQL StatefulSet lab"

# Delete StatefulSet first to stop the pod
info "Deleting StatefulSet..."
kubectl delete statefulset postgres -n "${NAMESPACE}" --ignore-not-found

# Delete PVC explicitly (StatefulSet deletion doesn't remove it)
info "Deleting PVC data-postgres-0..."
kubectl delete pvc data-postgres-0 -n "${NAMESPACE}" --ignore-not-found

# Delete remaining namespaced resources via manifests
info "Deleting Service..."
kubectl delete -f "${SCRIPT_DIR}/service.yaml" --ignore-not-found
info "Deleting Secret..."
kubectl delete -f "${SCRIPT_DIR}/secret.yaml" --ignore-not-found

# Delete the namespace (catches anything we missed)
info "Deleting namespace ${NAMESPACE}..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

# Delete cluster-scoped StorageClass
info "Deleting StorageClass..."
kubectl delete -f "${SCRIPT_DIR}/storageclass.yaml" --ignore-not-found

# Collect hostPath directories from PVs before deleting them
info "Collecting hostPath locations from postgres-storage PVs..."
HOST_PATHS=$(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="postgres-storage")]}{.spec.hostPath.path}{"\n"}{end}' 2>/dev/null || true)

# Clean up any PVs that were provisioned by our StorageClass
info "Cleaning up PVs from postgres-storage..."
LEFTOVER_PVS=$(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="postgres-storage")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [[ -n "${LEFTOVER_PVS}" ]]; then
  echo "${LEFTOVER_PVS}" | xargs -r kubectl delete pv
  done_msg "PVs deleted"
else
  info "No leftover PVs found"
fi

# Remove actual data from the Minikube node's filesystem
info "Removing hostPath data from Minikube node..."
if [[ -n "${HOST_PATHS}" ]]; then
  while IFS= read -r hp; do
    [[ -z "${hp}" ]] && continue
    info "Removing ${hp} on Minikube node..."
    minikube ssh "sudo rm -rf ${hp}" 2>/dev/null || true
  done <<< "${HOST_PATHS}"
  done_msg "Host path data removed"
else
  # Fallback: wipe the known provisioner directory for our namespace
  info "No PV paths captured — wiping default provisioner path for ${NAMESPACE}..."
  minikube ssh "sudo rm -rf /tmp/hostpath-provisioner/${NAMESPACE}" 2>/dev/null || true
  done_msg "Default provisioner path cleaned"
fi

# ---------------------------------------------------------------------------
# Verification — confirm nothing is left behind
# ---------------------------------------------------------------------------
step "Verifying cleanup"

ERRORS=0

if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  info "Namespace ${NAMESPACE} still terminating — waiting up to 60s..."
  kubectl wait --for=delete namespace/"${NAMESPACE}" --timeout=60s 2>/dev/null || true
fi
if kubectl get namespace "${NAMESPACE}" &>/dev/null; then
  echo -e "${CYAN}⚠️  Namespace ${NAMESPACE} still exists (may be terminating)${NC}"
  ERRORS=$((ERRORS + 1))
else
  done_msg "Namespace ${NAMESPACE} gone"
fi

REMAINING_PVS=$(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="postgres-storage")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [[ -n "${REMAINING_PVS}" ]]; then
  echo -e "${CYAN}⚠️  Leftover PVs: ${REMAINING_PVS}${NC}"
  ERRORS=$((ERRORS + 1))
else
  done_msg "No leftover PVs"
fi

if kubectl get storageclass postgres-storage &>/dev/null; then
  echo -e "${CYAN}⚠️  StorageClass postgres-storage still exists${NC}"
  ERRORS=$((ERRORS + 1))
else
  done_msg "StorageClass postgres-storage gone"
fi

HOST_DATA=$(minikube ssh "ls /tmp/hostpath-provisioner/${NAMESPACE} 2>/dev/null" 2>/dev/null || true)
if [[ -n "${HOST_DATA}" ]]; then
  echo -e "${CYAN}⚠️  Data still on Minikube node: /tmp/hostpath-provisioner/${NAMESPACE}${NC}"
  ERRORS=$((ERRORS + 1))
else
  done_msg "No data on Minikube node"
fi

if [[ "${ERRORS}" -eq 0 ]]; then
  step "Cleanup complete — everything is gone 🧹"
else
  step "Cleanup finished with ${ERRORS} warning(s) — check above"
fi
