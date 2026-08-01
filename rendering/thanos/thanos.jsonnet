// Thanos configuration for Mojaloop CC observability
// Renders to YAML manifests in gitops/tooling-observability/thanos/
//
// Components: Receive (remote_write), Query, Store Gateway, Compactor
// S3 storage: MinIO at minio.minio:9000, bucket: thanos

local t = import 'kube-thanos/thanos.libsonnet';

local commonConfig = {
  namespace: 'observability',
  version: 'v0.42.2',
  image: 'quay.io/thanos/thanos:v0.42.2',
  objectStorageConfig: {
    name: 'thanos-objstore-config',
    key: 'objstore.yml',
  },
};

// --- Receive: accepts remote_write from Alloy ---
local receive = t.receive(commonConfig {
  replicas: 1,
  replicationFactor: 1,
  replicaLabels: ['replica'],
  retention: '6h',
  resources: {
    requests: { cpu: '271m', memory: '443Mi' },
    limits: { memory: '1Gi' },
  },
  volumeClaimTemplate: {
    spec: {
      accessModes: ['ReadWriteOnce'],
      resources: { requests: { storage: '2Gi' } },
    },
  },
});

// --- Query: PromQL engine, Grafana queries this ---
local query = t.query(commonConfig {
  replicas: 1,
  replicaLabels: ['replica'],
  stores: [
    'dnssrv+_grpc._tcp.thanos-receive.observability.svc.cluster.local',
    'dnssrv+_grpc._tcp.thanos-store.observability.svc.cluster.local',
  ],
  resources: {
    requests: { cpu: '50m', memory: '128Mi' },
    limits: { memory: '256Mi' },
  },
});

// --- Store Gateway: serves historical data from S3 ---
local store = t.store(commonConfig {
  replicas: 1,
  resources: {
    requests: { cpu: '50m', memory: '128Mi' },
    limits: { memory: '256Mi' },
  },
  volumeClaimTemplate: {
    spec: {
      accessModes: ['ReadWriteOnce'],
      resources: { requests: { storage: '1Gi' } },
    },
  },
});

// --- Compactor: compacts S3 blocks, enforces retention ---
local compact = t.compact(commonConfig {
  replicas: 1,
  retentionResolutionRaw: '168h',
  retentionResolution5m: '0d',
  retentionResolution1h: '0d',
  disableDownsampling: true,
  resources: {
    requests: { cpu: '50m', memory: '128Mi' },
    limits: { memory: '256Mi' },
  },
  volumeClaimTemplate: {
    spec: {
      accessModes: ['ReadWriteOnce'],
      resources: { requests: { storage: '2Gi' } },
    },
  },
});

// --- Object store config secret ---
// This is a placeholder structure. The actual secret is created via ExternalSecret
// from Vault, but Thanos needs to reference it by name.
local objstoreSecret = {
  apiVersion: 'v1',
  kind: 'Secret',
  metadata: {
    name: 'thanos-objstore-config',
    namespace: 'observability',
  },
  type: 'Opaque',
  stringData: {
    'objstore.yml': |||
      type: S3
      config:
        bucket: thanos
        endpoint: minio.minio:9000
        insecure: true
        access_key: PLACEHOLDER
        secret_key: PLACEHOLDER
    |||,
  },
};

// Output all manifests
{
  'thanos-receive-service': receive.service,
  'thanos-receive-serviceAccount': receive.serviceAccount,
  'thanos-receive-statefulSet': receive.statefulSet,
  'thanos-query-service': query.service,
  'thanos-query-serviceAccount': query.serviceAccount,
  'thanos-query-deployment': query.deployment,
  'thanos-store-service': store.service,
  'thanos-store-serviceAccount': store.serviceAccount,
  'thanos-store-statefulSet': store.statefulSet,
  'thanos-compact-service': compact.service,
  'thanos-compact-serviceAccount': compact.serviceAccount,
  'thanos-compact-statefulSet': compact.statefulSet,
}
