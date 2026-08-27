machine:
  network:
    nameservers:
%{ for ns in nameservers ~}
      - ${ns}
%{ endfor ~}
