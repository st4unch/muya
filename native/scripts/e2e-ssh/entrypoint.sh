#!/bin/bash
# MODE=password | key | psmp. Throwaway credentials come from the environment (the e2e script's fake values).
set -e
ssh-keygen -A >/dev/null
cat > /etc/ssh/sshd_config.d/e2e.conf <<CONF
UsePAM no
LogLevel VERBOSE
CONF
case "$MODE" in
  password)
    useradd -m -s /bin/bash "$SSH_USER"; echo "$SSH_USER:$SSH_PASS" | chpasswd
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/e2e.conf ;;
  key)
    useradd -m -s /bin/bash "$SSH_USER"; passwd -u -d "$SSH_USER" >/dev/null 2>&1 || true; usermod -p '*' "$SSH_USER"
    install -d -m 700 -o "$SSH_USER" "/home/$SSH_USER/.ssh"
    printf '%s\n' "$SSH_PUBKEY" > "/home/$SSH_USER/.ssh/authorized_keys"
    chown "$SSH_USER" "/home/$SSH_USER/.ssh/authorized_keys"; chmod 600 "/home/$SSH_USER/.ssh/authorized_keys"
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config.d/e2e.conf ;;
  psmp)
    # The login name is "vaultUser@targetUser@targetHost" like a real PSMP; ssh's own password prompt takes the vault password,
    # then the gateway script shows a banner, an optional typed RADIUS challenge, and proxies to the target.
    useradd --badname -m -s /bin/bash "$GW_USER"; echo "$GW_USER:$PSMP_VAULT_PW" | chpasswd
    cat >> /etc/ssh/sshd_config.d/e2e.conf <<CONF
PasswordAuthentication yes
Match User $GW_USER
    ForceCommand /usr/local/bin/psmp-gw.sh
CONF
    ;;
esac
# sshd does not pass its environment to sessions: the gateway script reads its settings from a file.
( umask 022; env | grep "^PSMP_" > /etc/psmp.env || true )
exec /usr/sbin/sshd -D -e
