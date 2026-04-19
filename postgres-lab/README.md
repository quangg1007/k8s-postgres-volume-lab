# PostgreSQL StatefulSet Lab on Minikube

A hands-on Kubernetes lab that deploys a production-aware PostgreSQL StatefulSet on Minikube and proves data persistence across pod crashes and full StatefulSet deletion/recreation.

## Prerequisites

- [Minikube](https://minikube.sigs.k8s.io/docs/start/) installed and running (`minikube start`)
- `kubectl` configured to talk to the Minikube cluster

## Project Structure

```
postgres-lab/
├── storageclass.yaml   # Custom StorageClass (Retain policy)
├── secret.yaml         # PostgreSQL credentials (base64-encoded)
├── service.yaml        # Headless Service for stable DNS
├── statefulset.yaml    # PostgreSQL StatefulSet (1 replica)
├── verify.sh           # Automated deploy + verification script
├── cleanup.sh          # Teardown script (removes everything including host data)
└── README.md           # This file
```

## Quick Start

```bash
# Run the full lab (deploy → write data → crash → verify → delete → verify)
./postgres-lab/verify.sh

# Clean up everything when done
./postgres-lab/cleanup.sh
```

---

## What Each Manifest Does

### 1. StorageClass (`storageclass.yaml`)

Defines a custom StorageClass named `postgres-storage` using the Minikube hostpath provisioner.

Key settings:
- `reclaimPolicy: Retain` — PersistentVolumes are preserved when PVCs are deleted, preventing accidental data loss. This is the core of the lab. The default Minikube StorageClass uses `Delete`, which destroys the PV and its data.
- `volumeBindingMode: Immediate` — volumes bind as soon as the PVC is created, without waiting for a pod to be scheduled.
- `allowVolumeExpansion: true` — supports resizing volumes later.
- Not annotated as the default StorageClass, so it won't interfere with other workloads.

### 2. Secret (`secret.yaml`)

Stores PostgreSQL credentials as base64-encoded values in a Kubernetes Secret named `postgres-credentials` in the `postgres-lab` namespace.

Contains three keys:
- `POSTGRES_USER` → `pguser`
- `POSTGRES_PASSWORD` → `pgpassword123`
- `POSTGRES_DB` → `appdb`

The StatefulSet references this Secret via `envFrom.secretRef`, so no passwords are hardcoded in the workload manifest.

### 3. Headless Service (`service.yaml`)

A Service named `postgres` with `clusterIP: None` (headless). Instead of providing a single virtual IP with load balancing, it creates individual DNS A records for each StatefulSet pod.

This enables stable DNS resolution at:
```
postgres-0.postgres.postgres-lab.svc.cluster.local
```

Required by the StatefulSet's `serviceName` field for stable network identity.

### 4. StatefulSet (`statefulset.yaml`)

The PostgreSQL workload controller named `postgres` with `replicas: 1`.

Key design decisions:
- `serviceName: postgres` — must match the headless Service name for DNS resolution.
- `image: postgres:16` — uses the official PostgreSQL 16 image.
- `envFrom.secretRef` — injects all Secret keys as environment variables (no hardcoded credentials).
- `PGDATA=/var/lib/postgresql/data/pgdata` — set to a subdirectory because mounting a volume at `/var/lib/postgresql/data` may contain a `lost+found` directory from the filesystem, which PostgreSQL rejects as a non-empty PGDATA directory.
- `volumeClaimTemplates` — creates a PVC named `data` (resulting in `data-postgres-0`) requesting 1Gi of `ReadWriteOnce` storage from the `postgres-storage` StorageClass.
- Resource requests (250m CPU, 256Mi memory) and limits (500m CPU, 512Mi memory) for production-awareness.

---

## What the Verification Script Proves

`verify.sh` runs an automated end-to-end lifecycle test:

### Step 1: Deploy
Creates the `postgres-lab` namespace and applies all manifests in dependency order: StorageClass → Secret → Service → StatefulSet. Waits for `postgres-0` to be ready and for PostgreSQL to accept connections.

### Step 2: Write Test Data
Creates a `test_data` table and inserts a row via `kubectl exec -i` (non-interactive).

### Step 3: Simulate Pod Crash
Deletes pod `postgres-0` with `kubectl delete pod`. The StatefulSet controller automatically recreates it with the same identity and re-mounts the existing PVC.

### Step 4: Verify Crash Recovery
Queries `test_data` and confirms the row is still there. Data survived because the PVC and PV were never deleted — only the pod was.

### Step 5: Delete the StatefulSet
Deletes the entire StatefulSet object (not the PVC). This removes the pod but PVCs created by `volumeClaimTemplates` are intentionally preserved by Kubernetes.

### Step 6: Verify PVC/PV Survival
Confirms `data-postgres-0` PVC still exists and its bound PV is still in `Bound` state.

### Step 7: Recreate the StatefulSet
Re-applies `statefulset.yaml`. The new pod `postgres-0` matches the existing PVC by name convention (`data-postgres-0`) and re-mounts it.

### Step 8: Verify Data After Recreation
Queries `test_data` again and confirms the row survived a full StatefulSet deletion and recreation.

---

## Why Data Survives

| Scenario | Why it works |
|---|---|
| Pod crash | StatefulSet controller recreates the pod with the same identity. The PVC remains bound to the PV throughout. PostgreSQL recovers from its write-ahead log (WAL). |
| StatefulSet deletion | Kubernetes does not delete PVCs when a StatefulSet is deleted. The PVC `data-postgres-0` persists independently. When the StatefulSet is re-created, the new pod re-mounts the existing PVC by matching the `volumeClaimTemplates` name. |
| PVC deletion (hypothetical) | The `reclaimPolicy: Retain` on the StorageClass means the PV transitions to `Released` state instead of being destroyed. The data remains on disk. |

---

## Cleanup

`cleanup.sh` tears down everything in the correct order:

1. Deletes the StatefulSet (stops the pod)
2. Deletes the PVC `data-postgres-0` (which StatefulSet deletion doesn't remove)
3. Deletes the Service and Secret
4. Deletes the `postgres-lab` namespace
5. Deletes the `postgres-storage` StorageClass
6. Deletes any orphaned PVs left behind by the Retain policy
7. Removes the actual data from the Minikube node's filesystem via `minikube ssh` (the hostpath provisioner stores data under `/tmp/hostpath-provisioner/`)
8. Runs a verification check confirming namespace, PVs, StorageClass, and host data are all gone

This last step is critical — with `reclaimPolicy: Retain`, deleting Kubernetes PV objects does not remove the underlying data on the Minikube node. Without the `minikube ssh rm -rf` step, re-running the lab would find old data still on disk.

---

## Lessons Learned / Gotchas

1. **`kubectl wait --for=condition=ready` is not enough for PostgreSQL.** The pod's readiness probe can pass before PostgreSQL finishes initializing its Unix socket. The script adds a retry loop that polls `psql -c "SELECT 1;"` to confirm the database is actually accepting connections.

2. **`kubectl exec -i` not `-it`.** Using `-it` (interactive + TTY) fails in scripts because there's no terminal attached. Always use `-i` only for scripted `kubectl exec` calls.

3. **`reclaimPolicy: Retain` preserves PVs but not disk cleanup.** After deleting a PV object, the Minikube hostpath provisioner does not remove the data directory on the node. You must explicitly clean up via `minikube ssh` or the data persists across lab runs.

4. **PGDATA subdirectory trick.** Mounting a volume at `/var/lib/postgresql/data` can expose a `lost+found` directory from the filesystem. PostgreSQL refuses to initialize in a non-empty directory. Setting `PGDATA` to a subdirectory (`/var/lib/postgresql/data/pgdata`) avoids this.

5. **Namespace isolation.** All namespaced resources (Secret, Service, StatefulSet, PVC) are scoped to `postgres-lab` so the lab doesn't interfere with other workloads on the cluster.
