# Implementation Plan: PostgreSQL StatefulSet Lab on Minikube

## Overview

Build a hands-on Kubernetes lab that deploys a production-aware PostgreSQL StatefulSet on Minikube. The implementation creates five files in `postgres-lab/`: a StorageClass, Secret, StatefulSet, headless Service, and a verification script. Each manifest is applied declaratively (no `kubectl run` shortcuts), credentials are injected via a Kubernetes Secret, and the verification script proves data survives both pod crashes and full StatefulSet deletion/recreation.

## Tasks

- [ ] 1. Create StorageClass manifest
  - [ ] 1.1 Create `postgres-lab/storage-class.yaml` by copying the existing `storageclass.yaml` from the workspace root
    - The file must define a StorageClass named `postgres-storage` with provisioner `k8s.io/minikube-hostpath`
    - Must set `reclaimPolicy: Retain`, `volumeBindingMode: Immediate`, and `allowVolumeExpansion: true`
    - Must NOT be annotated as the default storage class
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_

- [ ] 2. Create Secret manifest
  - [ ] 2.1 Create `postgres-lab/secret.yaml` with the PostgreSQL credentials Secret
    - Define a Secret named `postgres-credentials` in namespace `postgres-lab` with type `Opaque`
    - Include base64-encoded values for keys: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`
    - _Requirements: 2.1, 2.2_

- [ ] 3. Create headless Service manifest
  - [ ] 3.1 Create `postgres-lab/service.yaml` with the headless Service definition
    - Define a Service named `postgres` in namespace `postgres-lab` with `clusterIP: None`
    - Select pods with label `app: postgres` and expose port 5432
    - _Requirements: 4.1, 4.2, 4.3_

- [ ] 4. Create StatefulSet manifest
  - [ ] 4.1 Create `postgres-lab/statefulset.yaml` with the PostgreSQL StatefulSet
    - Define a StatefulSet named `postgres` in namespace `postgres-lab` with `replicas: 1`
    - Set `serviceName: postgres` to match the headless Service name
    - Use `postgres:16` image
    - Reference the Secret via `envFrom.secretRef` with name `postgres-credentials`
    - Set env var `PGDATA` to `/var/lib/postgresql/data/pgdata`
    - Define resource requests (250m CPU, 256Mi memory) and limits (500m CPU, 512Mi memory)
    - Define `volumeClaimTemplates` entry named `data` requesting 1Gi `ReadWriteOnce` from `postgres-storage` StorageClass
    - Mount the volume at `/var/lib/postgresql/data`
    - Must contain zero hardcoded database credentials
    - _Requirements: 2.3, 2.4, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

  - [ ]* 4.2 Write property tests for YAML manifests
    - **Property 1: No hardcoded credentials in workload manifests** — verify that decoded Secret values do not appear as plaintext in statefulset.yaml
    - **Property 2: StatefulSet serviceName matches Headless Service name** — verify `spec.serviceName` in statefulset.yaml equals `metadata.name` in service.yaml
    - **Property 3: All namespaced resources target the lab namespace** — verify `metadata.namespace` equals `postgres-lab` in secret.yaml, service.yaml, and statefulset.yaml
    - **Validates: Requirements 2.4, 3.2, 8.2**

- [ ] 5. Checkpoint — Review all manifests
  - Ensure all four YAML manifests are syntactically valid and consistent with each other. Ensure all tests pass, ask the user if questions arise.

- [x] 6. Create verification script
  - [x] 6.1 Create `postgres-lab/verify.sh` — namespace setup and resource deployment
    - Script must be executable (`#!/usr/bin/env bash`, `set -euo pipefail`)
    - Create the `postgres-lab` namespace (use `kubectl create namespace` or `kubectl apply`)
    - Apply manifests in dependency order: StorageClass, Secret, Service, StatefulSet
    - Wait for pod `postgres-0` to reach ready state using `kubectl wait`
    - _Requirements: 7.1, 7.2, 8.1_

  - [x] 6.2 Add crash recovery verification to `verify.sh`
    - Use `kubectl exec -i` (not `-it`) to create `test_data` table and insert a test row
    - Delete pod `postgres-0` with `kubectl delete pod`
    - Wait for the replacement pod to reach ready state
    - Query `test_data` table and confirm the row is returned
    - Print clear success/failure indicators for each step
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 7.3, 7.4_

  - [x] 6.3 Add StatefulSet deletion and recreation verification to `verify.sh`
    - Delete the StatefulSet `postgres` (not the PVC)
    - Verify PVC `data-postgres-0` still exists
    - Verify the bound PV remains in `Bound` state
    - Re-apply the StatefulSet manifest
    - Wait for pod `postgres-0` to reach ready state
    - Query `test_data` table and confirm the row is returned
    - Print clear success/failure indicators for each step
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 7.3, 7.4_

  - [x] 6.4 Add educational summary to `verify.sh`
    - After all verification steps pass, print a summary explaining why data survived each failure scenario
    - Explain the role of `reclaimPolicy: Retain`, PVC lifecycle independence from StatefulSet, and Secret-based credential injection
    - _Requirements: 7.5_

- [ ] 7. Final checkpoint — Full review
  - Ensure all files are present in `postgres-lab/` (storage-class.yaml, secret.yaml, service.yaml, statefulset.yaml, verify.sh). Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate manifest correctness properties from the design document
- The verification script uses `kubectl exec -i` (not `-it`) to remain non-interactive and scriptable
- No `kubectl run` shortcuts — every resource is a declarative YAML manifest
- All namespaced resources must specify `namespace: postgres-lab`
