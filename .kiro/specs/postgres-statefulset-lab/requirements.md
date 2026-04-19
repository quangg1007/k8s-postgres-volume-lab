# Requirements Document

## Introduction

This document defines the requirements for a hands-on Kubernetes lab that deploys a production-aware PostgreSQL StatefulSet on Minikube. The lab proves three critical behaviors: data survives a Pod crash and restart, data survives a full StatefulSet deletion and recreation, and credentials are managed securely via Kubernetes Secrets. All resources are scoped to a dedicated namespace and use a custom StorageClass with a Retain reclaim policy.

## Glossary

- **StorageClass**: A Kubernetes resource that defines how PersistentVolumes are dynamically provisioned, including the provisioner and reclaim policy.
- **StatefulSet**: A Kubernetes workload controller that manages pods with stable identities, persistent storage, and ordered deployment.
- **PersistentVolumeClaim (PVC)**: A request for storage by a pod, bound to a PersistentVolume.
- **PersistentVolume (PV)**: A cluster-level storage resource provisioned by a StorageClass.
- **Headless_Service**: A Kubernetes Service with `clusterIP: None` that provides individual DNS records for each pod instead of a single virtual IP.
- **Secret**: A Kubernetes resource that stores sensitive data such as credentials, encoded in base64.
- **Verification_Script**: A shell script (`verify.sh`) that orchestrates the full lab lifecycle — deploy, test, break, recover, and verify.
- **Pod**: The smallest deployable unit in Kubernetes, running one or more containers.
- **Namespace**: A Kubernetes mechanism for isolating groups of resources within a cluster.
- **Retain_Policy**: A PersistentVolume reclaim policy that preserves the volume and its data when the associated PVC is deleted.

## Requirements

### Requirement 1: Custom StorageClass with Retain Policy

**User Story:** As a lab participant, I want a custom StorageClass with a Retain reclaim policy, so that PersistentVolumes are preserved when PVCs are deleted and data is not lost.

#### Acceptance Criteria

1. THE StorageClass manifest SHALL define a resource named `postgres-storage` using the `k8s.io/minikube-hostpath` provisioner
2. THE StorageClass SHALL specify `reclaimPolicy: Retain` to prevent automatic PersistentVolume deletion when a PVC is released
3. THE StorageClass SHALL set `volumeBindingMode: Immediate` to bind volumes without waiting for pod scheduling
4. THE StorageClass SHALL enable `allowVolumeExpansion: true` to support future storage growth
5. THE StorageClass SHALL NOT be annotated as the default storage class for the cluster

### Requirement 2: Secure Credential Management via Kubernetes Secret

**User Story:** As a lab participant, I want PostgreSQL credentials stored in a Kubernetes Secret, so that no passwords are hardcoded in workload manifests.

#### Acceptance Criteria

1. THE Secret manifest SHALL define a resource named `postgres-credentials` in the `postgres-lab` namespace with type `Opaque`
2. THE Secret SHALL contain base64-encoded values for `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB` keys
3. THE StatefulSet manifest SHALL reference the Secret via `envFrom.secretRef` to inject credentials as environment variables
4. THE StatefulSet manifest SHALL contain zero hardcoded database credentials in its container spec

### Requirement 3: StatefulSet with Stable Identity and Persistent Storage

**User Story:** As a lab participant, I want a PostgreSQL StatefulSet with stable pod identity and persistent storage, so that the database maintains its state across pod lifecycle events.

#### Acceptance Criteria

1. THE StatefulSet manifest SHALL define a resource named `postgres` in the `postgres-lab` namespace with `replicas: 1`
2. THE StatefulSet SHALL reference `serviceName: postgres` matching the Headless_Service name for stable DNS resolution
3. THE StatefulSet SHALL use the `postgres:16` container image
4. THE StatefulSet SHALL define a `volumeClaimTemplates` entry named `data` requesting 1Gi of `ReadWriteOnce` storage from the `postgres-storage` StorageClass
5. THE StatefulSet SHALL mount the volume at `/var/lib/postgresql/data` and set the `PGDATA` environment variable to `/var/lib/postgresql/data/pgdata` to avoid the `lost+found` directory conflict
6. THE StatefulSet SHALL specify resource requests of 250m CPU and 256Mi memory, and resource limits of 500m CPU and 512Mi memory

### Requirement 4: Headless Service for Stable DNS

**User Story:** As a lab participant, I want a headless Service for the StatefulSet, so that pods have stable, addressable DNS entries.

#### Acceptance Criteria

1. THE Service manifest SHALL define a resource named `postgres` in the `postgres-lab` namespace with `clusterIP: None`
2. THE Headless_Service SHALL select pods with the label `app: postgres` and expose port 5432
3. WHEN the StatefulSet pod is running, THE Headless_Service SHALL enable DNS resolution at `postgres-0.postgres.postgres-lab.svc.cluster.local`

### Requirement 5: Data Persistence Across Pod Crash

**User Story:** As a lab participant, I want to verify that data survives a pod crash and restart, so that I can confirm Kubernetes StatefulSets provide crash recovery.

#### Acceptance Criteria

1. WHEN the PostgreSQL pod is ready, THE Verification_Script SHALL create a `test_data` table and insert a test row via `kubectl exec`
2. WHEN the Verification_Script deletes the pod `postgres-0`, THE StatefulSet controller SHALL recreate the pod with the same identity and re-mount the existing PVC
3. WHEN the replacement pod reaches ready state, THE Verification_Script SHALL query the `test_data` table and confirm the previously inserted row is returned
4. WHILE the pod is deleted and recreated, THE PVC `data-postgres-0` and its bound PV SHALL remain intact

### Requirement 6: Data Persistence Across StatefulSet Deletion and Recreation

**User Story:** As a lab participant, I want to verify that data survives a full StatefulSet deletion and recreation, so that I can confirm PVCs outlive their parent StatefulSet.

#### Acceptance Criteria

1. WHEN the Verification_Script deletes the StatefulSet `postgres`, THE PVC `data-postgres-0` SHALL continue to exist in the namespace
2. WHEN the Verification_Script deletes the StatefulSet `postgres`, THE bound PV SHALL remain in `Bound` state
3. WHEN the Verification_Script re-applies the StatefulSet manifest, THE new pod `postgres-0` SHALL re-mount the existing PVC `data-postgres-0`
4. WHEN the recreated pod reaches ready state, THE Verification_Script SHALL query the `test_data` table and confirm the previously inserted row is returned

### Requirement 7: Verification Script Orchestration

**User Story:** As a lab participant, I want an automated verification script, so that I can run the entire lab lifecycle and see clear pass/fail results.

#### Acceptance Criteria

1. THE Verification_Script SHALL apply all Kubernetes manifests in the correct dependency order: namespace, StorageClass, Secret, Service, StatefulSet
2. WHEN applying manifests, THE Verification_Script SHALL wait for the PostgreSQL pod to reach ready state before executing database commands
3. WHEN a verification step succeeds, THE Verification_Script SHALL print a clear success indicator
4. WHEN a verification step fails, THE Verification_Script SHALL print a clear failure indicator and exit with a non-zero status code
5. WHEN all verification steps complete successfully, THE Verification_Script SHALL print an educational summary explaining why data survived each failure scenario

### Requirement 8: Namespace Isolation

**User Story:** As a lab participant, I want all lab resources scoped to a dedicated namespace, so that the lab does not interfere with other workloads on the cluster.

#### Acceptance Criteria

1. THE Verification_Script SHALL create a `postgres-lab` namespace before deploying any resources
2. THE Secret, Service, StatefulSet, and PVC resources SHALL all reside in the `postgres-lab` namespace
