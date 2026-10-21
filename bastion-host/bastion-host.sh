#!/usr/bin/env bash
# bastion-host.sh — build (or tear down) a small AWS VPC lab with the AWS CLI.
#
# Creates:
#   - VPC (10.0.0.0/16) with DNS hostnames enabled
#   - Public subnet (10.0.1.0/24) + private subnet (10.0.2.0/24)
#   - Internet Gateway attached to the VPC
#   - Public route table (0.0.0.0/0 -> IGW) associated with the public subnet
#   - Security groups: bastion (SSH from your IP) and private (SSH from bastion only)
#   - A shared Network ACL for each subnet
#   - Key pair + two EC2 instances (bastion in public, app in private)
#   - SSH verification through the bastion (jump host)
#
# Usage:
#   ./bastion-host.sh up [--verify]     # create everything
#   ./bastion-host..sh down              # delete everything created by "up"
#
# Env overrides: AWS_REGION, PROJECT, INSTANCE_TYPE, MY_IP
# Requires: aws CLI v2 (credentials configured), curl, ssh

set -euo pipefail

PROJECT="${PROJECT:-vpc-lab}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
VPC_CIDR="10.0.0.0/16"
PUBLIC_CIDR="10.0.1.0/24"
PRIVATE_CIDR="10.0.2.0/24"
KEY_NAME="${PROJECT}-key"
KEY_FILE="./${KEY_NAME}.pem"
STATE_FILE="./${PROJECT}.state"
AMI_PARAM="/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

export AWS_DEFAULT_REGION="$REGION"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# Tag spec helper: tags RESOURCE_TYPE NAME
tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=${PROJECT}-$2},{Key=Project,Value=${PROJECT}}]"; }

# Persist resource IDs so "down" can clean up.
save() { echo "$1=$2" >> "$STATE_FILE"; }

# ---------------------------------------------------------------------------
up() {
  local verify="${1:-}"
  command -v aws >/dev/null || die "aws CLI not found"
  aws sts get-caller-identity >/dev/null || die "AWS credentials not configured"
  [[ -f "$STATE_FILE" ]] && die "$STATE_FILE exists — run '$0 down' first"

  MY_IP="${MY_IP:-$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')}"
  [[ -n "$MY_IP" ]] || die "could not detect your public IP (set MY_IP)"
  log "Region: $REGION | Your IP: $MY_IP"
  : > "$STATE_FILE"

  # --- VPC ---
  VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
    --tag-specifications "$(tags vpc vpc)" --query Vpc.VpcId --output text)
  save VPC_ID "$VPC_ID"
  aws ec2 wait vpc-available --vpc-ids "$VPC_ID"
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
  log "VPC: $VPC_ID"

  # --- Subnets (same AZ) ---
  AZ=$(aws ec2 describe-availability-zones --filters Name=state,Values=available \
    --query 'AvailabilityZones[0].ZoneName' --output text)
  PUB_SUBNET=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PUBLIC_CIDR" \
    --availability-zone "$AZ" --tag-specifications "$(tags subnet public)" \
    --query Subnet.SubnetId --output text)
  save PUB_SUBNET "$PUB_SUBNET"

  # -- Enables Auto Public IP Assignment for the EC2 instances in public subnet
  aws ec2 modify-subnet-attribute --subnet-id "$PUB_SUBNET" --map-public-ip-on-launch

  PRIV_SUBNET=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$PRIVATE_CIDR" \
    --availability-zone "$AZ" --tag-specifications "$(tags subnet private)" \
    --query Subnet.SubnetId --output text)
  save PRIV_SUBNET "$PRIV_SUBNET"
  log "Subnets ($AZ): public=$PUB_SUBNET private=$PRIV_SUBNET"

  # --- Internet Gateway ---
  IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "$(tags internet-gateway igw)" \
    --query InternetGateway.InternetGatewayId --output text)
  save IGW_ID "$IGW_ID"
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  log "Internet Gateway attached: $IGW_ID"

  # --- Public route table ---
  RTB_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
    --tag-specifications "$(tags route-table public-rt)" \
    --query RouteTable.RouteTableId --output text)
  save RTB_ID "$RTB_ID"
  aws ec2 create-route --route-table-id "$RTB_ID" \
    --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
  aws ec2 associate-route-table --route-table-id "$RTB_ID" --subnet-id "$PUB_SUBNET" >/dev/null
  log "Route table $RTB_ID: 0.0.0.0/0 -> $IGW_ID (public subnet)"
  # Private subnet stays on the VPC main route table (local only, no internet).

  # --- Security groups ---
  BASTION_SG=$(aws ec2 create-security-group --vpc-id "$VPC_ID" \
    --group-name "${PROJECT}-bastion-sg" --description "SSH from admin IP" \
    --tag-specifications "$(tags security-group bastion-sg)" --query GroupId --output text)
  save BASTION_SG "$BASTION_SG"
  aws ec2 authorize-security-group-ingress --group-id "$BASTION_SG" \
    --protocol tcp --port 22 --cidr "${MY_IP}/32" >/dev/null

  PRIVATE_SG=$(aws ec2 create-security-group --vpc-id "$VPC_ID" \
    --group-name "${PROJECT}-private-sg" --description "SSH from bastion only" \
    --tag-specifications "$(tags security-group private-sg)" --query GroupId --output text)
  save PRIVATE_SG "$PRIVATE_SG"
  aws ec2 authorize-security-group-ingress --group-id "$PRIVATE_SG" \
    --protocol tcp --port 22 --source-group "$BASTION_SG" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$PRIVATE_SG" \
    --protocol icmp --port -1 --cidr "$VPC_CIDR" >/dev/null
  log "Security groups: bastion=$BASTION_SG private=$PRIVATE_SG"

  # --- Network ACLs ---

  # 1. Create shared Network ACL
  SHARED_NACL=$(aws ec2 create-network-acl \
      --vpc-id "$VPC_ID" \
      --query 'NetworkAcl.NetworkAclId' \
      --output text)

  save SHARED_NACL "$SHARED_NACL"

  # 2. Rule 100: Allow all inbound IPv4 traffic
  aws ec2 create-network-acl-entry \
      --network-acl-id "$SHARED_NACL" \
      --ingress \
      --rule-number 100 \
      --protocol -1 \
      --cidr-block 0.0.0.0/0 \
      --rule-action allow

  # 3. Rule 100: Allow all outbound IPv4 traffic
  aws ec2 create-network-acl-entry \
      --network-acl-id "$SHARED_NACL" \
      --egress \
      --rule-number 100 \
      --protocol -1 \
      --cidr-block 0.0.0.0/0 \
      --rule-action allow

  # 4. Associate shared NACL with both subnets
  for subnet in "$PUB_SUBNET" "$PRIV_SUBNET"; do
      assoc=$(aws ec2 describe-network-acls \
          --filters Name=association.subnet-id,Values="$subnet" \
          --query 'NetworkAcls[0].Associations[0].NetworkAclAssociationId' \
          --output text)

      aws ec2 replace-network-acl-association \
          --association-id "$assoc" \
          --network-acl-id "$SHARED_NACL" >/dev/null
  done

  # --- Key pair ---
  aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
    --tag-specifications "$(tags key-pair key)" \
    --query KeyMaterial --output text > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  save KEY_NAME "$KEY_NAME"
  log "Key pair: $KEY_NAME -> $KEY_FILE"

  # --- EC2 instances ---
  AMI_ID=$(aws ssm get-parameter --name "$AMI_PARAM" --region "$REGION" --query Parameter.Value --output text)
  log "AMI: $AMI_ID (Amazon Linux 2023)"

  BASTION_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --subnet-id "$PUB_SUBNET" --security-group-ids "$BASTION_SG" \
    --metadata-options HttpTokens=required \
    --tag-specifications "$(tags instance bastion)" \
    --query 'Instances[0].InstanceId' --output text)
  save BASTION_ID "$BASTION_ID"

  PRIVATE_ID=$(aws ec2 run-instances --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" --subnet-id "$PRIV_SUBNET" --security-group-ids "$PRIVATE_SG" \
    --metadata-options HttpTokens=required \
    --tag-specifications "$(tags instance private)" \
    --query 'Instances[0].InstanceId' --output text)
  save PRIVATE_ID "$PRIVATE_ID"

  log "Waiting for instances to run: $BASTION_ID $PRIVATE_ID"
  aws ec2 wait instance-running --instance-ids "$BASTION_ID" "$PRIVATE_ID"

  BASTION_IP=$(aws ec2 describe-instances --instance-ids "$BASTION_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$PRIVATE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

  cat <<EOF

$(log "Done!")
  Bastion (public):  $BASTION_ID  public IP $BASTION_IP
  App (private):     $PRIVATE_ID  private IP $PRIVATE_IP

SSH to the bastion:
  ssh -i $KEY_FILE ec2-user@$BASTION_IP

SSH to the private instance via jump host:
  ssh -i $KEY_FILE -o ProxyCommand="ssh -i $KEY_FILE -W %h:%p ec2-user@$BASTION_IP" ec2-user@$PRIVATE_IP

Or with agent forwarding:
  ssh-add $KEY_FILE
  ssh -A ec2-user@$BASTION_IP     # then, on the bastion: ssh ec2-user@$PRIVATE_IP

Tear down with: $0 down
EOF

  [[ "$verify" == "--verify" ]] && verify_ssh "$BASTION_IP" "$PRIVATE_IP"
  return 0
}

# ---------------------------------------------------------------------------
verify_ssh() {
  local bastion_ip="$1" private_ip="$2"
  local opts=(-i "$KEY_FILE" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
  local proxy="ssh ${opts[*]} -W %h:%p ec2-user@$bastion_ip"

  log "Verifying SSH to bastion (may take ~1 min while sshd starts)..."
  for _ in $(seq 1 18); do
    ssh "${opts[@]}" "ec2-user@$bastion_ip" true 2>/dev/null && break
    sleep 10
  done
  ssh "${opts[@]}" "ec2-user@$bastion_ip" 'echo "  bastion OK: $(hostname)"' \
    || { warn "SSH to bastion failed"; return 1; }

  log "Verifying SSH to private instance through bastion..."
  for _ in $(seq 1 12); do
    ssh "${opts[@]}" -o ProxyCommand="$proxy" "ec2-user@$private_ip" true 2>/dev/null && break
    sleep 10
  done
  ssh "${opts[@]}" -o ProxyCommand="$proxy" "ec2-user@$private_ip" \
    'echo "  private OK: $(hostname)"; curl -s -m 5 https://checkip.amazonaws.com >/dev/null && echo "  (unexpected: has internet)" || echo "  no internet access, as expected"' \
    || { warn "SSH to private instance failed"; return 1; }
}

# ---------------------------------------------------------------------------
down() {
  [[ -f "$STATE_FILE" ]] || die "no $STATE_FILE found — nothing to delete"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  set +e  # keep going on partial failures

  local ids=()
  [[ -n "${BASTION_ID:-}" ]] && ids+=("$BASTION_ID")
  [[ -n "${PRIVATE_ID:-}" ]] && ids+=("$PRIVATE_ID")
  if ((${#ids[@]})); then
    log "Terminating instances: ${ids[*]}"
    aws ec2 terminate-instances --instance-ids "${ids[@]}" >/dev/null
    aws ec2 wait instance-terminated --instance-ids "${ids[@]}"
  fi

  [[ -n "${KEY_NAME:-}" ]] && { log "Deleting key pair"; aws ec2 delete-key-pair --key-name "$KEY_NAME"; rm -f "$KEY_FILE"; }
  [[ -n "${PRIVATE_SG:-}" ]] && { log "Deleting SG $PRIVATE_SG"; aws ec2 delete-security-group --group-id "$PRIVATE_SG"; }
  [[ -n "${BASTION_SG:-}" ]] && { log "Deleting SG $BASTION_SG"; aws ec2 delete-security-group --group-id "$BASTION_SG"; }
  [[ -n "${PUB_SUBNET:-}" ]]  && { log "Deleting subnet $PUB_SUBNET"; aws ec2 delete-subnet --subnet-id "$PUB_SUBNET"; }
  [[ -n "${PRIV_SUBNET:-}" ]] && { log "Deleting subnet $PRIV_SUBNET"; aws ec2 delete-subnet --subnet-id "$PRIV_SUBNET"; }
  [[ -n "${PUB_NACL:-}" ]]    && { log "Deleting NACL $PUB_NACL"; aws ec2 delete-network-acl --network-acl-id "$PUB_NACL"; }
  [[ -n "${PRIV_NACL:-}" ]]   && { log "Deleting NACL $PRIV_NACL"; aws ec2 delete-network-acl --network-acl-id "$PRIV_NACL"; }
  [[ -n "${RTB_ID:-}" ]]      && { log "Deleting route table $RTB_ID"; aws ec2 delete-route-table --route-table-id "$RTB_ID"; }
  if [[ -n "${IGW_ID:-}" ]]; then
    log "Detaching/deleting IGW $IGW_ID"
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
  fi
  [[ -n "${VPC_ID:-}" ]] && { log "Deleting VPC $VPC_ID"; aws ec2 delete-vpc --vpc-id "$VPC_ID"; }

  rm -f "$STATE_FILE"
  log "Teardown complete."
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  up)   up "${2:-}" ;;
  down) down ;;
  *)    echo "Usage: $0 {up [--verify]|down}"; exit 1 ;;
esac
