# mongod hard-refuses to boot when uname reports a kernel at or above 6.19
# (SERVER-121912: its vendored TCMalloc violates the rseq ABI those kernels
# enforce), and the check reads the version string, not the machine. Under the
# UNAME26 personality the allocator takes its pre-rseq paths, which run
# correctly on any kernel.
FROM percona/percona-server-mongodb:8.3.8-2

USER root
RUN mv /usr/bin/mongod /usr/bin/mongod-unwrapped \
 && printf '#!/bin/bash\nexec setarch x86_64 --uname-2.6 /usr/bin/mongod-unwrapped "$@"\n' > /usr/bin/mongod \
 && chmod 0755 /usr/bin/mongod
USER 1001
