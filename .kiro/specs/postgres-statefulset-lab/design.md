# Design Document: PostgreSQL StatefulSet Lab on Minikube

## Overview

This lab provides a hands-on exercise for deploying a production-aware PostgreSQL StatefulSet on Minikube. The goal is to demonstrate three critical Kubernetes behaviors: data persistence across pod crashes, data survival after StatefulSet deletion and recreation, and secure credential management via Kubernetes Secrets.

The lab creates a custom StorageClass with `reclaimPolicy: Retain` to ensure PersistentVolumes are not deleted when their claims are released. A headless Service provides stable DNS for the StatefulSet pod. A verification script orchestrates the full lifecycle — deploying resources, writing test data, simulating failures, and proving data survives each scenario.

The design targets a single-node Minikube environment with all resources scoped to the `postgres-lab` namespace. The architecture deliberately avoids the default `standard` StorageClass (which uses `reclaimPolicy: Delete`) to teach the difference between Retain and Delete reclaim policies.

## Architecture

```mermaid
graph TD
    subgraph "Minikube Node"
        subgraph "Namespace: postgres-lab"
            Secret["Secret<br/>postgres-credentials"]
            SVC["Headless Service<br/>postgres (ClusterIP: None)<br/>Port 5432"]
            STS["StatefulSet<br/>postgres<br/>replicas: 1"]
            POD["Pod<br/>postgres-0<br/>postgres:16"]
            PVC["PVC<br/>data-postgres-0<br/>1Gi RWO"]
        end
        SC["StorageClass<br/>postgres-storage<br/>reclaimPolicy: Retain"]
        PV["PersistentVolume<br/>(auto-provisioned)<br/>minikube-hostpath"]
        DISK["Host Path<br/>/tmp/hostpath-provisioner/..."]
    end

    STS -->|manages| POD
    STS -->|creates via<br/>volumeClaimTemplates| PVC
    POD -->|envFrom| Secret
    SVC -->|selects| POD
    PVC -->|bound to| PV
    PV -->|provisioned by| SC
    PV -->|backed by| DISK
```

## Sequence Diagrams

### Main Deployment Flow

```mermaid
sequenceDiagram
    participant User as verify.sh
    participant K8s as Kubernetes API
    participant SC as StorageClass
    participant STS as StatefulSet Controller
    participant Pod as postgres-0
    participant PVC as PVC: data-postgres-0
    participant PV as PersistentVolume

    User->>K8s: kubectl apply storage-class.yaml
    K8s->>SC: Create postgres-storage (Retain)

    User->>K8s: kubectl apply secret.yaml
    K8s-->>K8s: Store Secret postgres-credentials

    User->>K8s: kubectl apply service.yaml
    K8s-->>K8s: Create headless Service

    User->>K8s: kubectl apply statefulset.yaml
    K8s->>STS: Create StatefulSet postgres
    STS->>PVC: Create data-postgres-0 (1Gi, RWO)
    PVC->>SC: Request volume from postgres-storage
    SC->>PV: Provision hostpath volume
    PV-->>PVC: Bind PV to PVC
    STS->>Pod: Create postgres-0
    Pod->>PVC: Mount /var/lib/postgresql/data
    Pod-->>Pod: Init PostgreSQL (PGDATA=/var/lib/postgresql/data/pgdata)
```

### Crash Recovery Flow (Steps 3–5)

```mermaid
sequenceDiagram
    participant User as verify.sh
    participant K8s as Kubernetes API
    participant STS as StatefulSet Controller
    participant Pod as postgres-0
    participant PVC as PVC: data-postgres-0
    participant PV as PersistentVolume

    User->>Pod: kubectl exec: CREATE TABLE, INSERT
    Pod-->>User: Data written to PV via PVC

    User->>K8s: kubectl delete pod postgres-0
    K8s->>Pod: Terminate postgres-0
    Note over PVC,PV: PVC and PV remain intact
    STS->>Pod: Recreate postgres-0 (same identity)
    Pod->>PVC: Re-mount data-postgres-0
    Pod-->>Pod: PostgreSQL recovers from WAL

    User->>Pod: kubectl exec: SELECT * FROM test_data
    Pod-->>User: Row returned — data survived crash
```

### StatefulSet Deletion & Recreation Flow (Steps 6–9)

```mermaid
sequenceDiagram
    participant User as verify.sh
    participant K8s as Kubernetes API
    participant STS as StatefulSet Controller
    participant Pod as postgres-0
    participant PVC as PVC: data-postgres-0
    participant PV as PersistentVolume

    User->>K8s: kubectl delete statefulset postgres
    K8s->>STS: Delete StatefulSet
    STS->>Pod: Terminate postgres-0
    Note over PVC,PV: PVCs are NOT deleted<br/>(StatefulSet deletion preserves PVCs)

    User->>K8s: kubectl get pvc — confirms PVC exists
    User->>K8s: kubectl get pv — confirms PV Bound

    User->>K8s: kubectl apply statefulset.yaml
    K8s->>STS: Recreate StatefulSet postgres
    STS->>Pod: Create postgres-0
    Note over PVC: Existing PVC data-postgres-0<br/>matches volumeClaimTemplate name
    Pod->>PVC: Re-mount existing data-postgres-0
    PVC-->>PV: Already bound

    User->>Pod: kubectl exec: SELECT * FROM test_data
    Pod-->>User: Row returned — data survived full deletion
```

## Components and Interfaces

### Component 1: StorageClass (`storage-class.yaml`)

**Purpose**: Defines a custom storage provisioner with Retain reclaim policy to prevent automatic PV deletion.

**Interface**:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: postgres-storage
  # No annotation for default — must NOT be default class
provisioner: k8s.io/minikube-hostpath
reclaimPolicy: Retain
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

**Responsibilities**:
- Provision hostpath-backed PersistentVolumes on Minikube
- Ensure PVs are retained when PVCs are deleted (`reclaimPolicy: Retain`)
- Allow immediate binding without waiting for pod scheduling
- Support volume expansion for future growth

**Key Design Decision**: Using `Retain` instead of `Delete` is the core of the lab. When a PVC is deleted, the PV transitions to `Released` state instead of being destroyed, preserving the underlying data on disk.

### Component 2: Secret (`secret.yaml`)

**Purpose**: Stores PostgreSQL credentials as base64-encoded values, decoupling secrets from workload manifests.

**Interface**:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: postgres-lab
type: Opaque
data:
  POSTGRES_USER: <base64(pguser)>
  POSTGRES_PASSWORD: <base64(pgpassword123)>
  POSTGRES_DB: <base64(appdb)>
```

**Responsibilities**:
- Store database credentials securely (base64-encoded)
- Provide env vars to the StatefulSet pod via `envFrom`
- Ensure no hardcoded passwords appear in statefulset.yaml

### Component 3: StatefulSet (`statefulset.yaml`)

**Purpose**: Manages the PostgreSQL pod with stable identity, persistent storage, and secret-based configuration.

**Interface**:
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: postgres-lab
spec:
  serviceName: postgres        # Must match headless Service name
  replicas: 1                  # Single node Minikube constraint
  selector:
    matchLabels:
      app: postgres
  template:
    spec:
      containers:
        - name: postgres
          image: postgres:16
          envFrom:
            - secretRef:
                name: postgres-credentials
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          resources:
            limits:
              cpu: 500m
              memory: 512Mi
            requests:
              cpu: 250m
              memory: 256Mi
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        storageClassName: postgres-storage
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
```

**Responsibilities**:
- Maintain stable pod identity (`postgres-0`)
- Create PVC `data-postgres-0` via volumeClaimTemplates
- Inject credentials from Secret without hardcoding
- Set PGDATA to subdirectory to avoid the `lost+found` mount issue
- Enforce resource limits for production-awareness

**Key Design Decisions**:
- `PGDATA=/var/lib/postgresql/data/pgdata`: PostgreSQL requires PGDATA to be an empty directory on init. Mounting a volume at `/var/lib/postgresql/data` may contain `lost+found` from the filesystem. Setting PGDATA to a subdirectory avoids this.
- `envFrom.secretRef`: Injects all Secret keys as env vars in one declaration, cleaner than individual `secretKeyRef` entries.
- `serviceName: postgres`: Must match the headless Service name for proper DNS resolution (`postgres-0.postgres.postgres-lab.svc.cluster.local`).

### Component 4: Headless Service (`service.yaml`)

**Purpose**: Provides stable DNS entries for StatefulSet pods without load balancing.

**Interface**:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: postgres-lab
spec:
  clusterIP: None              # Headless — required for StatefulSet
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
```

**Responsibilities**:
- Enable DNS resolution: `postgres-0.postgres.postgres-lab.svc.cluster.local`
- No load balancing (headless) — direct pod addressing
- Required by StatefulSet's `serviceName` field

**Key Design Decision**: `clusterIP: None` makes this a headless Service. Unlike a normal ClusterIP Service that provides a single virtual IP, a headless Service creates individual DNS A records for each pod. This is required for StatefulSets to maintain stable network identities.

### Component 5: Verification Script (`verify.sh`)

**Purpose**: Orchestrates the full lab lifecycle — deploy, test, break, recover, verify.

**Responsibilities**:
- Apply all manifests in correct order
- Wait for pod readiness before executing commands
- Write and read test data via `kubectl exec -i` (non-interactive)
- Simulate pod crash and StatefulSet deletion
- Verify data persistence after each failure scenario
- Print educational summary explaining why data survived

## Data Models

### PostgreSQL Test Data Schema

```sql
CREATE TABLE test_data (
    id SERIAL PRIMARY KEY,
    message TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Test row
INSERT INTO test_data (message) VALUES ('Hello from Kubernetes StatefulSet lab');
```

**Validation Rules**:
- Table must exist after pod restart (crash recovery)
- Row must be queryable after StatefulSet deletion and recreation (PVC survival)
- `id` auto-increments — proves no data reset occurred

### Kubernetes Resource Relationships

```mermaid
erDiagram
    StorageClass ||--o{ PersistentVolume : provisions
    PersistentVolume ||--|| PersistentVolumeClaim : "bound to"
    PersistentVolumeClaim }o--|| StatefulSet : "created by volumeClaimTemplates"
    StatefulSet ||--|| Pod : manages
    Pod ||--|| PersistentVolumeClaim : mounts
    Pod }o--|| Secret : "reads env from"
    Service ||--|| Pod : "selects via label"
    StatefulSet ||--|| Service : "references via serviceName"
```

## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system — essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

### Property 1: No hardcoded credentials in workload manifests

*For any* credential value stored in the Secret's `data` section (decoded from base64), that value SHALL NOT appear as plaintext anywhere in the StatefulSet manifest. This ensures secrets are decoupled from workload definitions.

**Validates: Requirement 2.4**

### Property 2: StatefulSet serviceName matches Headless Service name

*For any* pair of StatefulSet and Service manifests in the lab, the StatefulSet's `spec.serviceName` field SHALL equal the Service's `metadata.name` field. This ensures stable DNS resolution for StatefulSet pods.

**Validates: Requirement 3.2**

### Property 3: All namespaced resources target the lab namespace

*For all* Kubernetes manifests in the lab that define namespaced resources (Secret, Service, StatefulSet), the `metadata.namespace` field SHALL equal `postgres-lab`. This ensures complete namespace isolation.

**Validates: Requirement 8.2**

