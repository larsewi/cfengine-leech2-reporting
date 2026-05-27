# Plan: leech2-based reporting as a CFEngine Community cfbs module

## Goal

Give CFEngine **Community** users a hub-side reporting pipeline they don't get out of the box. Distribute it as a `cfbs` module so consumers `cfbs add` it and get:

1. **PostgreSQL** installed on the policy server, owned by this module.
2. **pgAdmin** installed on the policy server for ad-hoc query access.
3. Agents producing leech2 patches from CSV state.
4. The hub pulling patches via `copy_from` and applying them as SQL into the module's DB.

This module assumes Community. It is **not** designed to coexist with Enterprise (`cf-hub`, `cfdb`, Mission Portal) — see "Non-goals".

## Architecture

```
┌────────────────────────────── agent ──────────────────────────────┐
│ cf-agent promises  ──writes──▶  CSVs in leech2 workdir            │
│        │                                                          │
│        └─ commands: lch block create                              │
│        └─ commands: lch patch create   ──▶  workdir/patches/*.bin │
└──────────────────────────────────┬────────────────────────────────┘
                                   │ files copy_from (cf-serverd)
                                   ▼
┌─────────────────────────── policy server ─────────────────────────┐
│ packages: postgresql, pgadmin4 (installed & enabled by module)    │
│ files copy_from  ──▶  /var/cfengine/state/leech2/<hostkey>/*.bin  │
│        │                                                          │
│        └─ commands: lch patch inject hostkey $(host)              │
│        └─ commands: lch patch sql | psql leech2db                 │
│        └─ on success: lch patch applied   (else lch patch failed) │
└───────────────────────────────────────────────────────────────────┘
```

## cfbs module layout

```
cfengine-leech2-reporting/
├── cfbs.json
├── README.md
├── def.json                       # module vars (DB name, paths, etc.)
├── policy/
│   ├── leech2_common.cf           # bundle: paths, helpers, lch binary
│   ├── leech2_packages.cf         # bundle agent: install postgres + pgadmin (hub only)
│   ├── leech2_db.cf               # bundle agent: createdb, schema bootstrap (hub only)
│   ├── leech2_agent.cf            # bundle agent: csv prep + lch run
│   ├── leech2_hub.cf              # bundle agent: copy + apply patches
│   └── leech2_access.cf           # bundle server: access rules
└── templates/
    └── config.toml.mustache       # leech2 table config (per agent)
```

`cfbs.json` declares build steps: `copy` for `def.json`, `policy_files` for the bundles, `augments` for `def.json`. Bundles get wired into `services_autorun`.

## Installing PostgreSQL and pgAdmin on the policy server

`leech2_packages.cf` runs only on `policy_server`. Two layers:

1. **OS packages.** Use a `packages` promise with `package_module => "apt_get"` / `"yum"` resolved by class:

   ```cfengine3
   vars:
     debian:: "pg_pkgs" slist => { "postgresql", "postgresql-contrib" };
     redhat:: "pg_pkgs" slist => { "postgresql-server", "postgresql-contrib" };

   packages:
     policy_server::
       "$(pg_pkgs)"
         policy => "present",
         package_module => default:generic;
   ```

   pgAdmin is trickier — Debian/Ubuntu has it in the official pgAdmin apt repo, RHEL via the pgAdmin yum repo. Module ships a small `commands` step that adds the repo + key if missing, then `packages` installs `pgadmin4-web` (or `pgadmin4-desktop` if the consumer prefers — module-level variable).

2. **Service + init.**
   - `services` promise to enable + start `postgresql`.
   - On RHEL, first-run `postgresql-setup --initdb` via a `commands` promise gated on the absence of `PG_VERSION` in the data dir.
   - For pgAdmin web: run the post-install setup non-interactively (`PGADMIN_SETUP_EMAIL` / `PGADMIN_SETUP_PASSWORD` env vars passed to `/usr/pgadmin4/bin/setup-web.sh`). Both come from `def.json` — consumers MUST override the default password.

`leech2_db.cf` then:

- Creates a role `leech2` with a password from `def.json`.
- Creates database `leech2db` owned by that role.
- Applies a baseline schema (the module ships a `.sql` file, applied via `commands` gated on a sentinel table existing).

## def.json (module variables)

```json
{
  "variables": {
    "default:leech2.db_name":     { "value": "leech2db" },
    "default:leech2.db_role":     { "value": "leech2" },
    "default:leech2.db_password": { "value": "CHANGE_ME" },
    "default:leech2.pgadmin_email":    { "value": "admin@example.com" },
    "default:leech2.pgadmin_password": { "value": "CHANGE_ME" },
    "default:leech2.workdir":     { "value": "/var/cfengine/state/leech2" }
  }
}
```

No `classes` block needed — Community has nothing to disable. `cf-monitord` keeps running but its output is unused; we don't touch it.

## Agent-side pipeline

`leech2_agent.cf`, run from `services_autorun`:

1. **Render `config.toml`** from `templates/config.toml.mustache` into `$(leech2.workdir)/config.toml`. Tables come from a module-level variable so consumers can extend.
2. **Populate CSVs.** Two sources:
   - Things cf-agent already knows (lastseen via `cf-key -s --output-format=csv`, hostname, OS facts from `sys.*`).
   - Custom data via `reports` or `commands` writing to `$(leech2.workdir)/<table>.csv`.
3. **Run leech2** with `commands` promises:

   ```cfengine3
   commands:
     "lch block create"
       contain => in_dir("$(leech2.workdir)"),
       handle => "leech2_block_create";

     "lch patch create"
       contain => in_dir("$(leech2.workdir)"),
       handle => "leech2_patch_create",
       depends_on => { "leech2_block_create" };
   ```

4. **Expose the patch file**. Write `lch patch create`'s output to `outgoing/<timestamp>.bin`. Mark applied only after the hub confirms — see "confirmation" below.

## Hub-side pipeline

`leech2_hub.cf` runs on `policy_server`:

1. **Pull patches** from each known host:

   ```cfengine3
   files:
     "$(leech2.workdir)/incoming/$(host)/."
       copy_from => secure_cp("$(leech2.workdir)/outgoing/", "$(host)"),
       depth_search => recurse("inf"),
       file_select => by_name(".*\.bin");
   ```

   Hosts come from a `slist` produced however the consumer wants (lastseen, file in policy, etc.).

2. **Apply patches** for each new file via a `commands` promise that:
   - Calls `lch patch inject hostkey "$(host)"` so the hub overrides client-supplied identity.
   - Pipes `lch patch sql` into `psql -d $(leech2.db_name) -U $(leech2.db_role)`.
   - On success, moves the patch to `applied/`.
   - On failure, moves to `failed/` and writes a flag the agent reads next run.

3. **Acknowledge back to agent**: hub writes a small marker file per applied patch back into a directory the agent fetches with another `copy_from`. The agent runs `lch patch applied` only when the marker appears (otherwise `lch patch failed`).

## cf-serverd access rules

`leech2_access.cf` ships:

```cfengine3
bundle server leech2_access {
  access:
    "$(leech2.workdir)/outgoing"
      handle    => "leech2_grant_outgoing",
      comment   => "Allow hub to pull patches",
      admit_keys => { "@(sys.policy_hub_key)" };
}
```

And on the hub, an `access` rule granting clients read on `$(leech2.workdir)/ack/$(connecting_hostkey)/`.

## Database schema

Module ships a baseline schema with one core table:

```sql
CREATE TABLE hosts (
  hostkey    TEXT PRIMARY KEY,
  hostname   TEXT,
  last_seen  TIMESTAMPTZ
);
```

Plus whatever extra tables we ship out of the box (software inventory, OS facts). The schema lives in `policy/schema/001_baseline.sql`; migrations are numbered `00N_*.sql` and applied in order by `leech2_db.cf` using a `schema_migrations` sentinel table.

leech2's `config.toml` `[[injected-fields]]` adds `hostkey` to every table so the hub-side identity injection lines up.

## Risks & open questions

1. **Existing PostgreSQL on the host.** If the operator already runs Postgres on the policy server (their own apps, or for some other reason), our `packages` + `services` steps must not stomp on it. Module should: detect an existing cluster (`pg_lsclusters` / `systemctl is-active postgresql`), and either skip install or refuse to proceed with a clear error. Default to refuse.
2. **pgAdmin exposure.** `pgadmin4-web` listens on a port — by default behind Apache on 80/443. Document this; the module should not silently expose pgAdmin to the world. Either bind to localhost-only by default and require the consumer to opt into broader exposure, or ship a sane reverse-proxy snippet.
3. **Default passwords.** `def.json` defaults are `CHANGE_ME`. Module's `commands` promises must `abort` if either DB or pgAdmin password is still `CHANGE_ME` at apply time.
4. **Authority of `hostkey`.** Agents must not be trusted to declare their own hostkey — always overwrite with `lch patch inject hostkey <derived>` on the hub.
5. **Patch ordering per host.** If two patches from the same host land out of order, leech2's `applied` pointer logic must still converge. Confirm with leech2 README's "If SQL application fails, force full state on next patch" flow.
6. **Concurrency on the hub.** Many hosts → many `psql` invocations. Either serialize via a lockfile (`flock`) inside the `commands` promise, or batch using a hub-local queue runner.
7. **leech2 install.** Module needs a `packages` promise (or download+extract step) for `libleech2`/`lch`. Pick distribution channel before milestone 2.
8. **Schema migrations.** As tables get added, existing deployments need migrations applied automatically. The `00N_*.sql` ordering helps; need to decide whether the module ever does destructive changes (drop columns) or always additive.

## Milestones

1. **Skeleton module** — `cfbs.json`, `def.json`, empty bundles. `cfbs build` produces something installable.
2. **Postgres + pgAdmin install** — running `cfbs add` + bootstrap on a fresh Community policy server leaves Postgres running with the `leech2db` DB created and pgAdmin reachable on localhost. Idempotent across re-runs.
3. **Agent pipeline against a static CSV** — prove `lch block create` + `lch patch create` runs cleanly under `cf-agent`, file lands in `outgoing/`.
4. **Hub pipeline against a synthetic patch** — `copy_from` works, `lch patch sql | psql` against `leech2db`.
5. **Real data, one table** (`hosts` with `(hostkey, hostname, last_seen)`). End-to-end on a 1-hub, 2-agent test rig.
6. **Confirmation + retry** (applied/failed markers, retry on next run).
7. **Add tables** until parity with what the consumer actually queries.

## Non-goals

- **Enterprise support.** This module assumes Community. On Enterprise, the user already has `cfdb`, Mission Portal, and `cf-hub`; the right answer there is to use those, not to layer this module on top.
- Replicating Mission Portal's UI. pgAdmin is the query surface; building dashboards is the consumer's problem.
- Replacing `cf-serverd`'s collect_call protocol. We route around it.
- Managing Postgres at scale (replication, PITR, tuning). Module installs a single-node Postgres suitable for reporting workloads of a small-to-medium fleet; bigger deployments should point leech2 at their own DB by overriding `def.json`.
