#!/bin/bash
# A CyberArk-PSMP lookalike: (vault password is sshd's own password auth) banner, optional typed RADIUS challenge, then it proxies to the
# target container with the target's password (kept here, like the vault keeps it). Logs never contain the passwords.
set -a; . /etc/psmp.env; set +a
IFS='@' read -r VAULT_USER T_USER T_HOST <<<"$USER"
echo "CyberArk Privileged Session Manager (simulator)"
echo "Connecting $VAULT_USER -> $T_USER@$T_HOST"
if [ "${PSMP_CHALLENGE:-0}" = "1" ]; then
  printf "Enter your RADIUS passcode: "; read -r -s OTP; echo
  if [ "$OTP" != "$PSMP_OTP" ]; then echo "Challenge failed"; exit 1; fi
fi
export SSHPASS="$PSMP_TARGET_PW"
OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
if [ -n "$SSH_ORIGINAL_COMMAND" ]; then exec sshpass -e ssh "${OPTS[@]}" "$T_USER@$T_HOST" "$SSH_ORIGINAL_COMMAND"; fi
exec sshpass -e ssh -t "${OPTS[@]}" "$T_USER@$T_HOST"
