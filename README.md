# Legacy MinIO to AIStor: two-node Linux upgrade

This folder is a manual alternative to the existing AWX playbook. It follows
MinIO's Linux upgrade sequence: export metadata, replace the binary on every
node, issue **one simultaneous cluster restart**, then register the license.

The migration from open-source MinIO to AIStor is permanent. Test it first,
schedule a maintenance window, and copy the generated metadata backup to
durable secure storage before changing either node.

## Prepare a protected operator configuration

Do not edit or commit `upgrade.env.example`. Copy it to a protected path and
set the existing local `mc` alias that points at the cluster being upgraded:

```sh
install -m 0600 upgrade.env.example /secure/aistor-upgrade.env
editor /secure/aistor-upgrade.env
```

The script does not install `mc`, set an alias, or accept `mc` credentials. It
uses the alias already configured for the user who runs `backup` and
`restart-and-license`. Run those phases as that same user; do not use `sudo`
unless root owns the same configured alias.

## Runbook

Run the metadata backup **once** from the operator/control host. Give
`AISTOR_BACKUP_DIR` a durable, secure location; the script creates any missing
parent directories and refuses to reuse an existing final backup directory.

```sh
./upgrade-to-aistor.sh backup \
  --config /secure/aistor-upgrade.env --confirm-permanent
```

Confirm the directory contains these artifacts and copy it off the control
host: `minio-config-export.txt`, `legacy-minio-bucket-metadata.zip`, and
`legacy-minio-iam-info.zip` (the exact prefix is your `MC_ALIAS`).

Then run the following on **each of the two MinIO nodes**. It verifies the
service is active, saves a timestamped local copy of the old binary, downloads
or uses your supplied AIStor binary, and replaces the binary without a restart.

```sh
sudo ./upgrade-to-aistor.sh install-binary \
  --config /secure/aistor-upgrade.env --confirm-permanent
```

Do not use `systemctl restart minio` between nodes. Once both binaries are in
place, run this **once** from the control host:

```sh
./upgrade-to-aistor.sh restart-and-license \
  --config /secure/aistor-upgrade.env --confirm-permanent
```

This invokes `mc admin service restart`, waits up to 150 seconds for `mc admin
info`, and calls `mc license register`. The license is stored in the object
store and replicated cluster-wide, which is MinIO's recommended registration
method; no per-node `MINIO_LICENSE` configuration is necessary.

## Air-gapped nodes

Place an approved AIStor binary on each target node and set
`AISTOR_BINARY_FILE=/secure/artifacts/aistor-minio` in the protected config.
The script uses that local file instead of downloading from `dl.min.io`.

The configuration file, license file, and optional local binary are inputs, so
their parent directories and files must already exist. Only the backup location
is created by the script.

## If AIStor does not start cleanly

Keep the exports. MinIO documents that older configurations may need manual
restoration using `mc admin config import`, `mc admin cluster bucket import`,
and `mc admin cluster iam import`, followed by a cluster restart. Review the
official troubleshooting guide before running any imports.

Official procedure: <https://docs.min.io/aistor/administration/upgrade-aistor-server/open-source-minio/linux/>.

## Ansible alternative

`playbook.yaml` implements the same sequence without configuring `mc` or
aliases. Create an inventory with both target nodes in a `minio` group, then
run the playbook as the local user that already owns the configured `mc` alias:

```ini
[minio]
minio-node-1 ansible_host=192.0.2.10
minio-node-2 ansible_host=192.0.2.11
```

```sh
ansible-playbook -i inventory.ini playbook.yaml \
  -e aistor_upgrade_confirm_permanent=true \
  -e mc_alias=legacy-minio \
  -e aistor_license_file=/secure/minio.license \
  -e aistor_backup_dir=/secure/backups/minio-to-aistor
```

By default this runs all phases. To run them in separate maintenance-window
steps, add `-e aistor_upgrade_phase=backup`, then `install-binary`, and finally
`restart-and-license`. `aistor_binary_file` takes precedence over
`aistor_binary_url`; otherwise each node downloads the standard AIStor binary
for its architecture.
