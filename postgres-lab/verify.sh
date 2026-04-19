#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="postgres-lab"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

pass() { echo -e "${GREEN}✅ PASS: $1${NC}"; }
fail() { echo -e "${RED}❌ FAIL: $1${NC}"; exit 1; }
info() { echo -e "${CYAN}ℹ️  $1${NC}"; }
step() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

# ---------------------------------------------------------------------------
# Step 1 — Namespace setup and resource deployment
# ---------------------------------------------------------------------------
step "Step 1: Create namespace and deploy resources"

info "Creating namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
pass "Namespace ${NAMESPACE} ready"

info "Applying StorageClass..."
kubectl apply -f "${SCRIPT_DIR}/storageclass.yaml"
pass "StorageClass applied"

info "Applying Secret..."
kubectl apply -f "${SCRIPT_DIR}/secret.yaml"
pass "Secret applied"

info "Applying headless Service..."
kubectl apply -f "${SCRIPT_DIR}/service.yaml"
pass "Service applied"

info "Applying StatefulSet..."
kubectl apply -f "${SCRIPT_DIR}/statefulset.yaml"
pass "StatefulSet applied"

info "Waiting for pod postgres-0 to be ready (timeout 120s)..."
kubectl wait --for=condition=ready pod/postgres-0 \
  -n "${NAMESPACE}" --timeout=120s
pass "Pod postgres-0 is ready"

# ---------------------------------------------------------------------------
# Step 2 — Crash recovery verification
# ---------------------------------------------------------------------------
step "Step 2: Write test data"

info "Waiting for PostgreSQL to accept connections..."
for i in $(seq 1 30); do
  if kubectl exec -i postgres-0 -n "${NAMESPACE}" -- \
    psql -U pguser -d appdb -c "SELECT 1;" &>/dev/null; then
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    fail "PostgreSQL did not become ready within 30 seconds"
  fi
  sleep 1
done
pass "PostgreSQL is accepting connections"

info "Creating test_data table and inserting a row..."
kubectl exec -i postgres-0 -n "${NAMESPACE}" -- \
  psql -U pguser -d appdb <<'SQL'
CREATE TABLE IF NOT EXISTS test_data (
    id SERIAL PRIMARY KEY,
    message TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO test_data (message) VALUES ('Hello from Kubernetes StatefulSet lab');
SQL
pass "Test data written"

step "Step 3: Simulate pod crash"

info "Deleting pod postgres-0..."
kubectl delete pod postgres-0 -n "${NAMESPACE}"
pass "Pod postgres-0 deleted"

info "Waiting for replacement pod to be ready (timeout 120s)..."
kubectl wait --for=condition=ready pod/postgres-0 \
  -n "${NAMESPACE}" --timeout=120s
pass "Replacement pod postgres-0 is ready"

step "Step 4: Verify data after pod crash"

info "Waiting for PostgreSQL to accept connections..."
for i in $(seq 1 30); do
  if kubectl exec -i postgres-0 -n "${NAMESPACE}" -- \
    psql -U pguser -d appdb -c "SELECT 1;" &>/dev/null; then
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    fail "PostgreSQL did not become ready within 30 seconds"
  fi
  sleep 1
done

RESULT=$(kubectl exec -i postgres-0 -n "${NAMESPACE}" -- \
  psql -U pguser -d appdb -t -A -c \
  "SELECT message FROM test_data WHERE message = 'Hello from Kubernetes StatefulSet lab' LIMIT 1;")

if [[ "${RESULT}" == *"Hello from Kubernetes StatefulSet lab"* ]]; then
  pass "Data survived pod crash — row returned successfully"
else
  fail "Data NOT found after pod crash"
fi

# ---------------------------------------------------------------------------
# Step 5 — StatefulSet deletion and recreation verification
# ---------------------------------------------------------------------------
step "Step 5: Delete StatefulSet (keep PVC)"

info "Deleting StatefulSet postgres..."
kubectl delete statefulset postgres -n "${NAMESPACE}"
pass "StatefulSet deleted"

step "Step 6: Verify PVC and PV survive"

info "Checking PVC data-postgres-0 still exists..."
if kubectl get pvc data-postgres-0 -n "${NAMESPACE}" &>/dev/null; then
  pass "PVC data-postgres-0 still exists"
else
  fail "PVC data-postgres-0 is missing after StatefulSet deletion"
fi

info "Checking bound PV is still in Bound state..."
PV_STATUS=$(kubectl get pvc data-postgres-0 -n "${NAMESPACE}" \
  -o jsonpath='{.status.phase}')
if [[ "${PV_STATUS}" == "Bound" ]]; then
  pass "PVC is in Bound state — PV intact"
else
  fail "PVC is in '${PV_STATUS}' state, expected 'Bound'"
fi

step "Step 7: Recreate StatefulSet"

info "Re-applying StatefulSet manifest..."
kubectl apply -f "${SCRIPT_DIR}/statefulset.yaml"
pass "StatefulSet re-applied"

info "Waiting for pod postgres-0 to be ready (timeout 120s)..."
kubectl wait --for=condition=ready pod/postgres-0 \
  -n "${NAMESPACE}" --timeout=120s
pass "Pod postgres-0 is ready after recreation"

step "Step 8: Verify data after StatefulSet recreation"

info "Waiting for PostgreSQL to accept connections..."
for i in $(seq 1 30); do
  if kubectl exec -i postgres-0 -n "${NAMESPACE}" -- \
    psql -U pguser -d appdb -c "SELECT 1;" &>/dev/null; then
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    fail "PostgreSQL did not become ready within 30 seconds"
  fi
  sleep 1
done

RESULT=$(kubectl exec -i postgres-0 -n "${NAMESPACE}" -- \
  psql -U pguser -d appdb -t -A -c \
  "SELECT message FROM test_data WHERE message = 'Hello from Kubernetes StatefulSet lab' LIMIT 1;")

if [[ "${RESULT}" == *"Hello from Kubernetes StatefulSet lab"* ]]; then
  pass "Data survived StatefulSet deletion and recreation"
else
  fail "Data NOT found after StatefulSet recreation"
fi

# ---------------------------------------------------------------------------
# Step 9 — Educational summary
# ---------------------------------------------------------------------------
step "All verifications passed!"

cat <<'EOF'

╔═══════════════════════════════════════════════════════════════════╗
║                    WHY DID DATA SURVIVE?                          ║
╠═══════════════════════════════════════════════════════════════════╣
║                                                                   ║
║  1. Pod crash recovery                                            ║
║     The StatefulSet controller recreated postgres-0 with the      ║
║     same identity and re-mounted the existing PVC. PostgreSQL     ║
║     recovered from its write-ahead log (WAL) on startup.          ║
║     The PVC and its bound PV were never deleted.                  ║
║                                                                   ║
║  2. StatefulSet deletion & recreation                             ║
║     Deleting a StatefulSet does NOT delete its PVCs. When the     ║
║     StatefulSet was re-applied, the new pod matched the           ║
║     existing PVC by name (data-postgres-0) and re-mounted it.     ║
║                                                                   ║
║  3. reclaimPolicy: Retain                                         ║
║     The custom StorageClass uses Retain instead of Delete.        ║
║     Even if the PVC were deleted, the underlying PersistentVolume ║
║     would transition to Released state — not destroyed.           ║
║     This is the safety net that prevents accidental data loss.    ║
║                                                                   ║
║  4. Secret-based credential injection                             ║
║     Credentials were stored in a Kubernetes Secret and injected   ║
║     via envFrom.secretRef. No passwords were hardcoded in the     ║
║     StatefulSet manifest, keeping secrets decoupled from          ║
║     workload definitions.                                         ║
║                                                                   ║
╚═══════════════════════════════════════════════════════════════════╝
EOF
