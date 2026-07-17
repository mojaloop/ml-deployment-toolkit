machine:
  time:
    servers:
%{ for srv in ntp_servers ~}
      - ${srv}
%{ endfor ~}
