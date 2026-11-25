# Throwaway sshd used by native/scripts/e2e-ssh: password sshd, key sshd and a PSMP-like gateway (all one image).
FROM debian:12-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server openssh-client sshpass ca-certificates && apt-get clean && mkdir -p /run/sshd
COPY entrypoint.sh psmp-gw.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/psmp-gw.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
