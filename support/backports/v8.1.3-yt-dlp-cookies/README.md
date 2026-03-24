# v8.1.3 yt-dlp Cookies Backport

This toolkit backports commit `35e7afbe68b175ec8e75694d51878b070043b3cb`
(`Adds cookies to yt-dlp config and docker env`) onto the official `v8.1.3`
release shape.

It contains:

- `generate-payload.sh`: rebuilds the local and Docker payload from `v8.1.3`
  and the backported commit, then refreshes the checked-in payload,
  manifests, and diffs.
- `apply-local.sh`: patches a standard production install such as
  `/var/www/peertube`.
- `apply-docker.sh`: patches a running Docker deployment and its host-side
  `.env`.

The apply scripts are conservative by default:

- They verify the target PeerTube version is `8.1.3`.
- They compare runtime files against the expected `v8.1.3` checksums.
- They stop on unexpected file contents unless `--force` is used.
- They create timestamped backups before replacing files.
- They ask for approval before editing live config files such as
  `production.yaml` or `.env`.

For standard Docker installs, the Docker script now relies on `.env` overrides
for `storage.import`. If `docker-volume/config/local-production.json` exists,
the script will leave it alone and add `PEERTUBE_STORAGE_IMPORT=/data/import/`
to `.env` instead.

Typical usage:

```bash
# Refresh the checked-in payload after changing the backport commit or script logic
./support/backports/v8.1.3-yt-dlp-cookies/generate-payload.sh

# Patch a classic production install
./support/backports/v8.1.3-yt-dlp-cookies/apply-local.sh

# Patch a Docker deployment from its compose directory
cd /path/to/peertube-docker
/path/to/PeerTube/support/backports/v8.1.3-yt-dlp-cookies/apply-docker.sh
```

Useful flags:

- `--yes`: skip interactive approvals
- `--force`: allow patching when a runtime file checksum differs from both the
  expected base and patched values
- `--skip-restart`: do not offer a restart at the end
