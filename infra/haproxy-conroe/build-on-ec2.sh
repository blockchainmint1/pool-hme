#!/usr/bin/env bash
#
# build-on-ec2.sh — spin up an Ubuntu 24.04 EC2 box in us-east-2, apply the
# haproxy-conroe config to it, and print the public IP for miner burn-in.
#
# Uses EC2 Instance Connect: no permanent keypair, no .pem file to manage.
#
# Usage:
#   ./build-on-ec2.sh                    # create + configure
#   ./build-on-ec2.sh --destroy          # tear down the tagged instance
#
set -euo pipefail

REGION="${AWS_REGION:-us-east-2}"
INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-t3.small}"
TAG="haproxy-conroe-burnin"
SG_NAME="haproxy-conroe-burnin-sg"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_KEY="$(mktemp -u /tmp/haproxy-conroe-ssh-XXXXXX)"

destroy() {
  echo "==> destroying instances tagged $TAG in $REGION"
  IDS=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$TAG" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  if [[ -n "$IDS" ]]; then
    aws ec2 terminate-instances --region "$REGION" --instance-ids $IDS >/dev/null
    echo "    terminated: $IDS"
  else
    echo "    nothing to destroy"
  fi
  exit 0
}

cleanup_key() {
  rm -f "$TMP_KEY" "$TMP_KEY.pub"
}
trap cleanup_key EXIT

if [[ "${1:-}" == "--destroy" ]]; then
  destroy
fi

# generate a temporary ed25519 key; Instance Connect pushes the public half
ssh-keygen -t ed25519 -N "" -f "$TMP_KEY" -C "haproxy-conroe-temp" >/dev/null

echo "==> region: $REGION   type: $INSTANCE_TYPE"

echo "==> resolve latest Ubuntu 24.04 AMI"
AMI=$(aws ec2 describe-images --region "$REGION" \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' --output text)
echo "    AMI: $AMI"

echo "==> ensure security group $SG_NAME (open :22 and :3433 to the world for burn-in)"
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  SG_ID=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "$SG_NAME" --description "haproxy-conroe burn-in" \
    --query 'GroupId' --output text)
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --protocol tcp --port 22   --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
    --protocol tcp --port 3433 --cidr 0.0.0.0/0 >/dev/null
fi
echo "    SG: $SG_ID"

echo "==> launch instance"
IID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI" --instance-type "$INSTANCE_TYPE" \
  --security-group-ids "$SG_ID" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "    instance: $IID  (waiting for running)"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"

IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "    public IP: $IP"

AZ=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)

push_key() {
  aws ec2-instance-connect send-ssh-public-key \
    --region "$REGION" \
    --instance-id "$IID" \
    --availability-zone "$AZ" \
    --instance-os-user ubuntu \
    --ssh-public-key "file://${TMP_KEY}.pub" \
    >/dev/null
}

ssh_cmd() {
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      -o IdentitiesOnly=yes \
      -i "$TMP_KEY" "ubuntu@$IP" "$@"
}

echo "==> wait for SSH via EC2 Instance Connect"
for i in {1..30}; do
  push_key
  if ssh_cmd 'true' 2>/dev/null; then
    break
  fi
  sleep 5
done

echo "==> ship config and run restore.sh --skip-netplan"
push_key
scp -o StrictHostKeyChecking=no -o IdentitiesOnly=yes \
    -i "$TMP_KEY" -r "$SRC_DIR" "ubuntu@$IP:/tmp/haproxy-conroe"

push_key
ssh_cmd 'sudo bash /tmp/haproxy-conroe/restore.sh --skip-netplan'

cat <<EOF

==> HAProxy burn-in box is up.

    instance-id: $IID
    az:          $AZ
    public-ip:   $IP

    # reconnect via EC2 Instance Connect (requires ec2-instance-connect-cli)
    mssh ubuntu@$IID --region $REGION

    # or push a fresh key manually and ssh:
    #   ssh-keygen -t ed25519 -N "" -f /tmp/haproxy-conroe-temp -C temp
    #   aws ec2-instance-connect send-ssh-public-key \
    #     --region $REGION --instance-id $IID --availability-zone $AZ \
    #     --instance-os-user ubuntu --ssh-public-key file:///tmp/haproxy-conroe-temp.pub
    #   ssh -i /tmp/haproxy-conroe-temp ubuntu@$IP

    # tail live traffic:
    sudo tail -f /var/log/haproxy.log

    # session census:
    sudo /opt/haproxy-conroe/watch-sessions.sh

    # point ONE test miner at:
    stratum+tcp://$IP:3433

    # tear down when done:
    ./build-on-ec2.sh --destroy

EOF
