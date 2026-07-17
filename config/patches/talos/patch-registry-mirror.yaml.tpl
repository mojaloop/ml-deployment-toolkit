machine:
  registries:
    mirrors:
      docker.io:
        overridePath: true
        endpoints:
          - https://${proxy_url}/v2/docker-hub
      ghcr.io:
        overridePath: true
        endpoints:
          - https://${proxy_url}/v2/ghcr
      quay.io:
        overridePath: true
        endpoints:
          - https://${proxy_url}/v2/quay
      registry.k8s.io:
        overridePath: true
        endpoints:
          - https://${proxy_url}/v2/k8s
    config:
      ${proxy_url}:
        auth:
          username: ${proxy_username}
          password: ${proxy_password}
