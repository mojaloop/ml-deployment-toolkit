# Minimal values for the kind bootstrap Cilium install: keep this to what a
# node needs to reach Ready — full runtime config lives in
# gitops/kind/values/cilium/cilium.yaml and Flux reconciles to it once the
# cluster is up. Every value here must agree with that file, or the takeover
# rolls the datapath.

# Kube-proxy replacement (the cluster is created with kubeProxyMode none, so
# kube-proxy never runs)
kubeProxyReplacement: true

k8sServiceHost: ${k8s_service_host}
k8sServicePort: "6443"

ipam:
  mode: kubernetes

# Gateway API support (CRDs applied by the cluster module before this install)
gatewayAPI:
  enabled: true

# The gateway LB IPs: pools from the vendor layer, announced over the kind
# docker bridge so the host reaches them
lbIPAM:
  enabled: true
l2announcements:
  enabled: true

operator:
  replicas: 1
  rollOutPods: true

rollOutCiliumPods: true
