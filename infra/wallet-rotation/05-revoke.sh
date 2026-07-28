#!/usr/bin/env bash
# Final revocation pass: remove stale SSH key material from the box and print
# the AWS-side checklist (which cannot be done from here).
#
#   sudo ./05-revoke.sh                  # report only
#   sudo ./05-revoke.sh CONFIRM_REVOKE   # delete stale key files
set -euo pipefail

CONFIRM="${1:-}"
FORENSICS="/root/ssh-forensics"

echo "=== Access revocation ==="
echo

echo "--- live authorized_keys (should be empty) ---"
for f in /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys; do
  [ -f "$f" ] && printf "%s : %s bytes\n" "$f" "$(stat -c %s "$f")"
done
echo

echo "--- stale key files still on disk ---"
STALE=$(ls -1 /home/ubuntu/.ssh/authorized_keys.* 2>/dev/null || true)
if [ -z "$STALE" ]; then
  echo "(none)"
else
  for f in $STALE; do
    echo "$f"
    awk '{print "    " $1, $NF}' "$f"
  done
fi
echo

echo "--- forensic archive ---"
ls -la "$FORENSICS" 2>/dev/null || echo "(missing -- archive before deleting!)"
echo

echo "--- sshd posture ---"
grep -rhiE "^(PasswordAuthentication|PermitRootLogin|AuthorizedKeysFile)" \
  /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null
echo "amazon-ssm-agent: $(systemctl is-active amazon-ssm-agent 2>/dev/null || echo absent)"
echo

echo "--- recent logins (18.206.107.x = EC2 Instance Connect, us-east-1) ---"
last -n 10 2>/dev/null | head -10
echo

if [ "$CONFIRM" = "CONFIRM_REVOKE" ]; then
  if [ ! -d "$FORENSICS" ] || [ -z "$(ls -A "$FORENSICS" 2>/dev/null)" ]; then
    echo "REFUSING: $FORENSICS is empty. Archive the key files first."
    exit 1
  fi
  for f in $STALE; do
    rm -f "$f"
    echo "removed $f"
  done
else
  echo "Report only. Re-run with: sudo $0 CONFIRM_REVOKE  (deletes stale key files)"
fi

cat <<'AWS'

=============================================================
AWS-side checklist -- do this in the console, not from here
=============================================================
SSH into this box is brokered by EC2 Instance Connect (all logins originate
from the 18.206.107.0/24 service range), so key files are NOT the real door.
IAM is.

1. IAM -> Users / Roles: find every principal with
     ec2-instance-connect:SendSSHPublicKey
   scoped to this instance. Remove all but your own.
2. IAM -> Users: deactivate access keys belonging to the former operator.
   Look for a principal matching the 'godthebest' key comment.
3. EC2 -> Security Groups: confirm port 22 is not open to 0.0.0.0/0.
4. EC2 -> Snapshots / AMIs: any snapshot of this volume taken before today
   contains the OLD, UNENCRYPTED wallet.dat files and therefore the old HD
   seeds. Delete every snapshot you do not need, and check the "Shared with
   other accounts" tab on the ones you keep.
5. CloudTrail: search ConsoleLogin, SendSSHPublicKey, and CreateSnapshot for
   the last 90 days to see whether anyone else has been in.

Item 4 is the one people miss. A pre-rotation EBS snapshot is a full copy of
the compromised seeds.
AWS
