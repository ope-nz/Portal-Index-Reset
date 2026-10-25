# Portal Index Reset

Reset the Portal for ArcGIS 12.x search index to an empty state that boots, so a Full Reindex can be run from the Portal Admin UI when the embedded OpenSearch cluster refuses to start.

Portal for ArcGIS 12.x keeps its search index in an embedded **OpenSearch 2.x** cluster under the portal index directory (by default `C:\arcgisportal\index`). After a hard reboot or a crash-consistent DR restore, the cluster state on disk can be torn and OpenSearch fails at startup with a `CorruptIndexException`. Esri's supported repairs, **Reconfigure** and **Reindex** in the Portal Admin API, are driven through the index service itself, so they cannot run when it is down. The 10.x/11.x workaround of unpacking `empty_index.zip` no longer exists. This toolkit fills that gap by working at the file level.

**Status:** verified on Portal for ArcGIS 12.1 (build 20379) with OpenSearch 2.18.0 on Windows Server 2022. A deliberately corrupted cluster was reset and fully repopulated by a Full Reindex in a single rehearsal with no rollback. See [Verification](#verification).

> ## ⚠️ KEEP `elastic.options` AT ALL COSTS
>
> **The single file nothing can rebuild is `C:\arcgisportal\index\elastic.options`**, Portal's encrypted bundle of index connection details, written once when the index service is created and never again.
>
> Verified 24 October 2026: Portal does **not** recreate it when missing. Portal Admin's Reconfigure does not. This toolkit cannot. A copy from another Portal is useless because it is encrypted with this deployment's key. A byte-level scan of the whole machine, including Portal's Postgres database and WAL, found **no second copy anywhere**.
>
> Everything else in the index directory can be regenerated. Lose this one file with no golden copy and the only ways back are a webgisdr restore or Esri Support.
>
> **Protect it:** run `SaveGoldenConfig` today, schedule `Reset-PortalIndex.cmd SaveGoldenConfig` daily, and keep the golden folder off the machine. The same copy also preserves `internal_users.yml`, needed whenever the cluster is emptied.

## How it works

```
C:\arcgisportal\index\
  config\                 opensearch.yml, jvm.options, keystore, certs\, opensearch-security\*.yml   <- keep
  elastic.options         Portal's encrypted copy of the index credentials                            <- keep
  nodes\0\                cluster state + every index                                                 <- derived
```

Everything under `nodes\` is derived data:

- `ago-items`, `ago-users`, `ago-groups` are created and filled by a Full Reindex from the Portal database. Portal does not create them at startup, so after a reset they are absent until the reindex runs.
- `.opendistro_security` is rebuilt from `config\opensearch-security\*.yml` on first boot (`plugins.security.allow_default_init_securityindex: true`).
- The small `esri-ds-*` and `.dsconfig` indices were created by the ArcGIS Data Store runtime when the cluster was first built. They are not recreated after a reset and Portal runs without them.

So an empty `nodes\` plus the existing `config\` is an empty index that boots. The script stops Portal, moves `nodes\` aside, starts Portal, and verifies the new cluster over TLS. Nothing is deleted; every reset is a move into a timestamped backup folder and can be rolled back.

The script talks to OpenSearch without Portal's stored password. Portal generates an admin certificate (`config\certs\admin.pem`, CN = cluster name) that the security plugin treats as super-admin. The script wraps it into a client certificate with the bundled `openssl.exe` and presents it on every REST call.

## Files

| File | Purpose |
|---|---|
| `Reset-PortalIndex.ps1` | All the logic. Five actions, backup and rollback, admin-certificate access to OpenSearch. |
| `Reset-PortalIndex.cmd` | Double-click launcher. Self-elevates through UAC, shows a menu, keeps the window open. Accepts an action on the command line for unattended use. |
| `docs/Portal Index Reset.html` | Full documentation: anatomy, actions, runbook, troubleshooting, rehearsal recipes, verification. |
| `PLAN.md` | Investigation notes and the reset ladder. |

## Requirements

- Portal for ArcGIS 12.x on Windows with the default embedded OpenSearch index. Tested on 12.1 / OpenSearch 2.18.0.
- Windows PowerShell 5.1 or PowerShell 7, run elevated.
- The Portal install directory is found through the `AGSPORTAL` environment variable that the Portal installer sets, falling back to `C:\ArcGIS\Portal`. Override with `-InstallDir` or the `PORTAL_INSTALLDIR` environment variable. The index directory is read from `dir.index` in `portal-config.properties` (framework copy, then the installer's `etc` copy, then the content-store copy).
- Local Administrator on the Portal machine. The reset actions stop and start the *Portal for ArcGIS* service.

## Quick start

Copy `Reset-PortalIndex.ps1` and `Reset-PortalIndex.cmd` into one folder on the Portal machine, for example `C:\Admin\PortalIndex`.

**On a healthy day**

```
Reset-PortalIndex.cmd Diagnose           # read-only baseline report
Reset-PortalIndex.cmd SaveGoldenConfig   # snapshot config + certs + elastic.options
```

Copy the resulting `golden_config` folder somewhere off the machine. It contains private keys.

**When the index will not come up**

```
Reset-PortalIndex.cmd Diagnose           # confirms the failure and which rung you need
Reset-PortalIndex.cmd ResetCluster       # stop Portal, empty the cluster, start Portal
```

Then in Portal Admin: **System > Indexer > Reindex**, mode **Full**. Watch **Status** until every `databaseCount` equals its `indexCount` and `syncStatus` is `true`.

Or just double-click `Reset-PortalIndex.cmd` and pick from the menu.

## Actions

| Action | Stops Portal? | What it does |
|---|---|---|
| `Diagnose` | no | Service and leftover `java.exe` check, lock files, zero-byte files, disk, DNS for the bind names, certificate and key parsing, cluster health, indices and shards, security plugin health, log tails with the real cause line extracted. Writes a report folder. |
| `SaveGoldenConfig` | no | Copies `config\`, `elastic.options` and the dsdata json files to `index_backups\golden_config`. This is the per-deployment template for a bootable empty index. It cannot be shared between Portals. |
| `ResetCluster` | yes | Moves `nodes\` aside and starts Portal on an empty cluster. Add `-FromGolden` (menu option 4) to also restore `config\` and `elastic.options` from the golden copy when certificates or yml files are damaged. Auto-rollback if OpenSearch does not answer within `-WaitMinutes`. |
| `RebuildConfig` | yes | For a damaged `config\` with no golden copy. Regenerates the certificates with the bundled openssl using Portal's own recipe, rebuilds `opensearch.yml` and the other config files from the install's templates, keeps the cluster name and ports, and carries over the two credential files (`elastic.options`, `internal_users.yml`) that cannot be regenerated. Refuses if either of those is damaged. Add `-WithResetCluster` (menu option 6) to also empty the cluster. Auto-rollback if OpenSearch does not come up. |
| `Rollback` | yes | Puts a chosen backup back. |

Everything moved aside lands in `<index parent>\index_backups\<timestamp>_<Action>\`. Transcripts of every run are written next to it.

## Verification

Rehearsed on a test machine on 24 October 2026:

| Step | Result |
|---|---|
| Break: truncate `nodes\0\_state\segments_*` to half its length | OpenSearch fails at `NodeEnvironment.loadNodeMetadata` with `CorruptIndexException`; nothing listening on the HTTP port; Portal health check "Connection to the indexer service failed"; Portal retries the index service every two minutes. Reconfigure unreachable. |
| `ResetCluster` | Service stopped in 12 s; `nodes\` moved in under 1 s; OpenSearch green and empty 4 min 33 s after service start; no rollback. |
| Portal on the new cluster | Created its indices without complaint; the Data Store runtime accepted the new cluster UUID. |
| Full Reindex from the UI | 13,652 items, 498 groups, 51 users; database and index counts equal; `syncStatus: true`. |

Also tested the same day: starting Portal with the whole index directory absent. Portal reported "Started Index Service" after 15 seconds, then failed every health check and created no files in 20 minutes; Portal Admin's Reconfigure in that state created nothing either. Portal does not rebuild its index service outside an upgrade, which is why `RebuildConfig` does it instead. `RebuildConfig` was then verified live: with everything in `config\` deleted except `internal_users.yml`, it regenerated the folder (cluster identity from the Data Store runtime's json), and OpenSearch was up 4 min 38 s after service start with all five indices and their data intact. `ResetCluster -FromGolden` was verified the same way (4 min 36 s), and `RebuildConfig -WithResetCluster` with both config and cluster state damaged came up in 4 min 33 s, needing a Full Reindex afterwards. When `nodes` is kept, `internal_users.yml` is not required, because the live security index already holds the hash.

The rehearsal recipes, including how to break the index deterministically and how to put the test box back, are in the documentation.

## Things worth knowing

- **Yellow is normal.** Every index is configured with one replica on a single node, so replica shards can never be placed and the cluster never goes green once indices exist. Diagnose says so and only warns when a *primary* shard is not started.
- **Two log messages are noise.** `Not yet initialized (you may need to run securityadmin)` three times in the OpenSearch log, and `SEVERE Error in generating Portal Indices in Portal Index Builder Plugin` in the Portal log, appear on every healthy start. They are a startup race, not corruption.
- **Judge a reindex by Portal's Status counts**, not by OpenSearch's `docs.count`, which counts documents rather than Portal items and runs higher.
- **Windows PowerShell 5.1 and client certificates.** A script-block `ServerCertificateValidationCallback` fails intermittently with "The underlying connection was closed: An unexpected error occurred on a send", and Schannel cannot present a client certificate whose key is not in a persisted container. The script uses a compiled callback and a persisted machine key, and deletes the key container on exit.
- **The one irreplaceable file.** `elastic.options` is Portal's encrypted bundle of index connection details. Portal does not recreate it when missing (tested), and a byte-level scan of the whole machine including Portal's Postgres data found no second copy. Everything else in the index directory can be regenerated. Schedule `Reset-PortalIndex.cmd SaveGoldenConfig` daily and keep the golden folder off the machine.
- **Prevention.** Stop the Portal service before VM snapshots used for DR. Keep the machine name resolvable after a restore, because OpenSearch binds to it. Schedule webgisdr.

## Caveats

- Written for the default single-machine, embedded-index deployment. Not tested with Portal high availability or an external index.
- Verified on one deployment. Run `Diagnose` and `SaveGoldenConfig` first, and rehearse `ResetCluster` and `RebuildConfig` on a test machine before relying on them in production.
- The service name is assumed to be `Portal for ArcGIS`.
- `Reconfigure` and `Reindex` in the Portal Admin API remain the Esri-supported path whenever OpenSearch is running and Portal's web tier is up. This toolkit is for the case where they cannot run.

## References

- [Reconfigure Index (Portal Admin API)](https://developers.arcgis.com/rest/enterprise-administration/portal/reconfigure-index/)
- [Reindex (Portal Admin API)](https://developers.arcgis.com/rest/enterprise-administration/portal/reindex/)
- [Esri KB 000020175: manual index rebuild, no longer valid after 10.7.1](https://support.esri.com/en-us/knowledge-base/how-to-manually-rebuild-the-index-in-portal-for-arcgis-000020175)
- [OpenSearch securityadmin](https://docs.opensearch.org/latest/security/configuration/security-admin/)

## Licence, disclaimer and copyright

Copyright © 2026 Ope Ltd.

Licensed under the [Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0). You may not use these files except in compliance with the License. Software distributed under the License is distributed on an "AS IS" basis, without warranties or conditions of any kind, either express or implied. See the `LICENSE` file for the full terms.

This toolkit is **not** an Esri product and is **not supported, endorsed or reviewed by Esri**. It works directly on the files of Portal for ArcGIS and its embedded OpenSearch index, outside Esri's supported administration interfaces. Running it may put a deployment into a state Esri Support will not assist with.

It is provided **as is**, without warranty of any kind, express or implied, including fitness for a particular purpose. Ope Ltd accepts no liability for data loss, downtime or any other consequence of its use. **Use it at your own discretion and risk**, rehearse on a non-production machine first, and keep current backups (webgisdr and a golden config) before touching a production Portal.

Portal for ArcGIS, ArcGIS Enterprise and ArcGIS Data Store are trademarks of Esri. OpenSearch is a trademark of Amazon.com, Inc. or its affiliates.
