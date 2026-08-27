# Minimal values for the EKS bootstrap Cilium install (aws-bootstrap module).
# The Terraform-side counterpart of rendering/cilium/values.yaml on Talos:
# keep this to what a node needs to reach Ready — full runtime config lives
# in gitops/aws/cilium/helmrelease.yaml and Flux reconciles to it once the
# cluster is up. Every value here must agree with that file, or the takeover
# rolls the datapath.

# Kube-proxy replacement (Cilium handles all service routing; the cluster is
# created with bootstrap_self_managed_addons=false, so kube-proxy never runs)
kubeProxyReplacement: true

# With kube-proxy absent, the in-cluster Service VIP is not routable until
# Cilium's own datapath is up — agent and operator must reach the API server
# through the EKS endpoint directly (resolves to the private endpoint ENIs
# inside the VPC).
k8sServiceHost: ${k8s_service_host}
k8sServicePort: "443"

# ENI IPAM — pods get VPC-routable IPs from ENIs the operator manages using
# the node role's AmazonEKS_CNI_Policy (no IRSA by decision).
eni:
  enabled: true
ipam:
  mode: eni
routingMode: native
# The chart defaults IPv4 masquerade OFF when eni.enabled is set — pods are
# VPC-routable, but internet egress through the IGW still needs SNAT to the
# node IP (public subnets, no NAT). Explicitly on; the interface pattern
# below picks the devices. The native-routing CIDR is auto-derived from the
# VPC in ENI mode.
enableIPv4Masquerade: true
# ens+ — EKS AL2023 AMIs use predictable NIC names (ens5, ens6, ...); the
# classic eth+ matches nothing there, which silently disables masquerading
# and strands pod egress to the internet (found live: EBS CSI controller
# i/o-timeout on ec2.<region>.amazonaws.com while hostNetwork pods worked).
egressMasqueradeInterfaces: "ens+"

# Gateway API must be enabled at bootstrap even though Flux owns the full
# config: it sets enable-gateway-api/enable-envoy-config, and the operator
# only registers the CiliumEnvoyConfig CRDs at startup based on those flags.
gatewayAPI:
  enabled: true

# Flux enables Hubble with cluster-generated certs after takeover.
hubble:
  enabled: false

# Config changes only take effect when pods restart — the agent reads
# cilium-config at startup and flag flips never touch the pod templates.
# Same trap and same cure as the gitops values files; without these, a
# terraform-side helm upgrade (e.g. the ens+ masquerade fix) lands in the
# ConfigMap and silently never applies.
rollOutCiliumPods: true

operator:
  replicas: 1
  rollOutPods: true
