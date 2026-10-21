# AWS VPC Lab

Builds a small AWS network lab with one command using the AWS CLI v2, and
tears it all down with another.

## What it does

- VPC `10.0.0.0/16` with DNS hostnames enabled
- Public subnet `10.0.1.0/24` and private subnet `10.0.2.0/24`
- Internet Gateway attached to the VPC
- Public route table (`0.0.0.0/0` → IGW) associated with the public subnet
- Security groups: bastion (SSH from your IP only) and private (SSH from bastion only)
- Network ACLs for each subnet
- Key pair + two EC2 instances (Amazon Linux 2023): bastion in public, app in private
- Optional: verifies SSH to both instances through the bastion (jump host)

```
                 Internet
                     │
              Internet Gateway
                     │
 ┌──────────── VPC 10.0.0.0/16 ─────────────┐
 │  Public subnet 10.0.1.0/24               │
 │    └─ bastion (public IP) ──SSH──┐       │
 │                                  ▼       │
 │  Private subnet 10.0.2.0/24              │
 │    └─ app instance (no internet)         │
 └──────────────────────────────────────────┘
```

## Prerequisites

- AWS CLI v2 with credentials configured (`aws sts get-caller-identity` works)
- `curl` and `ssh`
- IAM permissions for EC2, VPC and SSM `GetParameter`

## Usage

```bash
./vpc-lab.sh up            # create everything
./vpc-lab.sh up --verify   # create + test SSH through the bastion
./vpc-lab.sh down          # delete everything
```

When `up` finishes it prints ready-to-use SSH commands for the jump-host and
agent-forwarding methods.

### Configuration

| Variable | Default | Description |
|---|---|---|
| `AWS_REGION` | `us-east-1` | Region to deploy into |
| `INSTANCE_TYPE` | `t3.micro` | Size of both instances |
| `PROJECT` | `vpc-lab` | Name prefix for tags, key file and state file |
| `MY_IP` | auto-detected | IP allowed to SSH to the bastion |

```bash
AWS_REGION=eu-west-1 INSTANCE_TYPE=t3.small ./vpc-lab.sh up
```

## Cleanup

```bash
./vpc-lab.sh down
```

Use the same `AWS_REGION` and `PROJECT` values you used for `up`. Resource IDs
are tracked in `<PROJECT>.state`, which `down` reads.

## Notes

- Two running `t3.micro` instances cost a few cents per hour; run `down` when finished.
- The private subnet has no NAT Gateway, so it has no internet access by design.
- `<PROJECT>-key.pem` and `<PROJECT>.state` are created in the current directory and are git-ignored.
