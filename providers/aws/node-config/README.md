# EKS node OS config fragments (nodeadm NodeConfig)

The node-OS half of the per-class materialization seat on AWS — the EKS
counterpart of `providers/proxmox/patches/` Talos fragments. A class in
`providers/aws/classes.yaml` names a fragment here via `node_config:`, and the
engine bakes it into that class's per-node-group launch template as MIME
multipart user data (`Content-Type: application/node.eks.aws`). EKS AL2023
nodeadm merges it with the NodeConfig EKS generates, so a fragment carries
ONLY the class's deltas — never cluster wiring (name, endpoint, CA — EKS owns
those).

Example (`worker-kafka.yaml`, wired with
`classes.worker-kafka.node_config: worker-kafka.yaml`):

```yaml
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  kubelet:
    config:
      allowedUnsafeSysctls:
        - net.core.somaxconn
```

Tuning values enter classes **from measured need only** — the seat exists
before the sysctls do, not the other way around. This directory being empty is
the expected steady state until a measurement says otherwise.

Changing a fragment bumps the launch-template version and EKS rolls the
class's node groups — plan before applying on a live environment.
