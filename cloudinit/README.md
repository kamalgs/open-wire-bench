# cloudinit/

Source of truth for what every bench instance runs. Deployed to S3 via
`scripts/deploy-cloudinit.sh`; each EC2 instance pulls from S3 on boot
(and on-demand via SSH for re-runs).

## Layout

```
cloudinit/
├── scripts/
│   ├── bootstrap.sh          common: sync binaries + systemd, enable sync timer
│   └── role-<role>.sh        per-role: enable role-specific services
└── systemd/
    ├── common/               units every node runs (bench-sync.timer)
    ├── hub/                  broker units (open-wire, nats-server)
    └── observability/        prometheus unit
```

## Contract

Cloud-init (in terraform user-data) does exactly this, same for every role:

```bash
aws s3 cp --recursive s3://${bucket}/cloudinit/ /opt/bench/cloudinit/
bash /opt/bench/cloudinit/scripts/bootstrap.sh
bash /opt/bench/cloudinit/scripts/role-$(cat /etc/bench/role).sh
```

`bootstrap.sh` is the universal setup. `role-*.sh` is everything specific
to that role — if a role grows past ~20 lines, split it into
`role-<name>/{install,start,validate}.sh` and have `role-<name>.sh`
dispatch.

## Environment contract

Each instance has `/etc/bench/env` (written by terraform user-data)
containing:

```
BENCH_BUCKET=open-wire-bench-results
BENCH_ENV=mini-simple
BENCH_ROLE=hub          # also in /etc/bench/role for convenience
BENCH_CLUSTER_NAME=open-wire-bench-mini-simple
BENCH_HUB_PEERS=10.0.1.10,10.0.1.11,10.0.1.12   # hubs only
```

Every script sources `/etc/bench/env` before doing anything.

## Updating running instances

Edit a script locally → commit in git → `./scripts/deploy-cloudinit.sh`
→ `./scripts/bench-fleet-reload.sh` to re-run bootstrap + role scripts
on each node via SSH.

New instances (ASG scale-out) pick up the latest automatically at boot.
