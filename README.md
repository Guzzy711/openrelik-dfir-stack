# OpenRelik DFIR stack

One script that gives you a forensic workbench on your own computer:

- **OpenRelik**: upload evidence and run tools on it from your browser.
- **UAC worker**: reads Linux/macOS/Unix collections made with [UAC](https://github.com/tclahr/uac).
- **iLEAPP worker**: reads iPhone extractions and iTunes backups with [iLEAPP](https://github.com/abrignoni/iLEAPP).
- **ALEAPP worker**: reads Android extractions with [ALEAPP](https://github.com/abrignoni/ALEAPP).
- **Dissect and Hayabusa worker**: reads Windows disk images (E01, VMDK, VHDX, raw) and KAPE
  collections with [Dissect](https://github.com/fox-it/dissect), and finds suspicious events
  in event logs with [Hayabusa](https://github.com/Yamato-Security/hayabusa).
- **Takajo worker**: triage of Windows event logs with
  [Takajo](https://github.com/Yamato-Security/takajo): logons, suspicious processes,
  services, tasks, IOC lists and a MITRE ATT&CK summary, from Hayabusa's results.
- **Elasticsearch + Kibana**: search and graph the timelines, every tool together in one
  **Super timeline** with the same columns.

Everything runs in Docker on your machine. Nothing is sent anywhere.

---

## 1. What you need

- A computer with **Linux** (Ubuntu works well) or **macOS**
- **16 GB of RAM** (8 GB works for small cases)
- **50 GB of free disk**, plus room for your evidence
- **Docker** with the Compose plugin

Check whether Docker is installed:

```bash
docker compose version
```

If that prints a version, skip to step 2. If not, install Docker:

- **Ubuntu / Debian**
  ```bash
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker $USER
  ```
  Then **log out and log in again** so you can use Docker without `sudo`.
- **macOS**: install [Docker Desktop](https://www.docker.com/products/docker-desktop/) and start it.

## 2. Start everything

```bash
git clone https://github.com/Guzzy711/openrelik-dfir-stack.git
cd openrelik-dfir-stack
./setup.sh
```

The first run takes 5 to 15 minutes, depending on your internet speed.

When it asks **which version to install**, press **Enter** to get the recommended one.

At the end OpenRelik prints a line like this:

```
Username: admin
Password: Xy7%k2...
```

**Write the password down.** It is shown only once.

## 3. Open it

| What | Address |
| --- | --- |
| OpenRelik | http://localhost:8711 |
| Kibana | http://localhost:5601 |

Log in to OpenRelik as `admin` with the password from step 2.

## 4. Your first case

### A Linux machine (UAC)

1. In OpenRelik, create a folder and upload the UAC archive (`uac-<host>-....tar.gz`).
2. Click the file, then **Create workflow**.
3. Add **UAC: Collection report** to see what is in the collection.
4. Add **UAC: Timeline (Timesketch / Elasticsearch)**, and after it **Elasticsearch Export**:
   - *Elasticsearch index name*: `uac-myhost`
   - *Parse input as JSON lines*: on
5. Click **Run**.
6. In Kibana, open **Discover**, pick **UAC timelines**, and set the time range
   (top right) to cover when the collection was made, for example *Last 1 year*.

### An iPhone (iLEAPP)

1. Upload one of these:
   - a full file system extraction (`.zip` or `.tar` from GrayKey, Cellebrite, and so on)
   - an iTunes or Finder backup: **zip the backup folder first**
2. Create a workflow with **iLEAPP: iOS artifacts**.
   - Encrypted backup? Enter its password in *iTunes backup password*.
   - *Timeline format*: Elasticsearch bulk NDJSON
3. Add **Elasticsearch Export** after it: index name `ileapp-myphone`, *Parse input as
   JSON lines* on.
4. Click **Run**. When it is done, download the **report zip** and open
   `ileapp_report/index.html`, or search the timeline in Kibana under **iLEAPP timelines**.

### An Android phone (ALEAPP)

1. Upload the full file system extraction (`.zip`, `.tar` or `.tar.gz`) or a disk image
   (`.E01`, `.img`).
2. Create a workflow with **ALEAPP: Android artifacts**.
   - *Timeline format*: Elasticsearch bulk NDJSON
   - Signal backup on the phone? Enter its recovery key in *Signal recovery key*.
3. Add **Elasticsearch Export** after it: index name `aleapp-myphone`, *Parse input as
   JSON lines* on.
4. Click **Run**. Download the **report zip** and open `aleapp_report/index.html`, or search
   the timeline in Kibana under **ALEAPP timelines**.

### A Windows computer (E01 or KAPE)

1. Upload the image. For a split E01, upload **all** parts (`.E01`, `.E02`, ...). A KAPE
   collection: zip the `tout` folder, or upload KAPE's `.vhdx`.
2. Create a workflow on the file(s) (select all E01 parts together) with:
   - **Dissect: Windows artifacts**: preset *Windows triage* parses event logs, prefetch,
     Amcache, Shimcache, registry, LNK, jump lists, shellbags, browsers and more.
   - **Hayabusa: Event log detections**: finds suspicious events with Sigma rules.
   - **Takajo: Hayabusa results analysis**: runs Hayabusa itself, then Takajo, so add it
     directly on the image (not after the Hayabusa task). Also takes `.evtx` files.
3. Add **Elasticsearch Export** after Dissect and after Hayabusa, with index name
   `dissect-mypc` and `hayabusa-mypc`, *Parse input as JSON lines* on. Not after Takajo:
   its results are CSV files and an HTML report.
4. Click **Run**. In Kibana, open the **Super timeline** (see below). The task reports in
   OpenRelik show the computer name, OS and the detections per level. Download Takajo's
   `*_takajo_html_report.zip` and open `index.html` for a summary per rule and computer;
   start with `TimelineSuspiciousProcesses.csv` and `TimelineLogon.csv`.

**Everything Plaso finds:** run **Plaso Log2Timeline** on the image, then **Plaso Psort**
with output format `json_line`, then **Elasticsearch Export** (index `openrelik-mypc`). This
takes much longer, and shows in the Super timeline too.

## 5. The Super timeline

Every timeline you export, from any tool, lands in one Kibana view with the same columns:

| Column | What it shows |
| --- | --- |
| `@timestamp` | when it happened |
| `host.name` | the computer or phone |
| `event.category` | the [ECS category](https://www.elastic.co/guide/en/ecs/current/ecs-allowed-values-event-category.html): `process`, `authentication`, `file`, `registry`, `network`, `web`, `configuration`, `intrusion_detection`, ... |
| `event.action` | the artifact and what the time means (`lnk: Target modified`, `evtx: EventID 4624`), or the Hayabusa rule |
| `message` | the details |

Each row also has `artifact.name` and `artifact.description`: what the artifact is and what
it tells you, for example *"Prefetch: a program ran on this computer. Shows the program, how
many times it ran, its last run times (up to 8) and the files it loaded."* Windows event log
rows describe their EventID (*"EventID 4624: Successful logon. The logon type says how: ..."*).
Click a row in Discover to see them, or add `artifact.description` as a column.

The fields follow the [Elastic Common Schema](https://www.elastic.co/docs/reference/ecs)
(ECS 9.5) wherever the tools have the data, so they line up across tools:

| ECS fields | From |
| --- | --- |
| `host.name`, `@timestamp`, `message`, `event.*` (`dataset` as `tool.artifact`, `code` = EventID, `provider`, `kind`, `severity`) | every tool |
| `user.name`, `source.ip`/`port`, `destination.ip`/`port` | event logs (Dissect, Plaso), Hayabusa |
| `process.executable`, `process.command_line`, `process.parent.*` | event logs, Hayabusa, shell history |
| `file.path`, `file.hash.*`, `process.hash.*`, `dll.hash.*`, `*.pe.imphash` | UAC executable hashes, Sysmon, Plaso |
| `url.original`, `log.file.path`, `server.address` | browser history and the file a record came from (Dissect) |
| `rule.name`, `rule.id`, `rule.ruleset` | Hayabusa |

Not ECS, because ECS has no field for them: `artifact.name` and `artifact.description`,
`data_type` (the tool's own `tool:artifact`), `timestamp_desc` (what the time means) and
the tools' other fields, which keep their names.

In Kibana open **Discover**, click **Open** (top right) and pick **Super timeline**. Filter with
the search bar, for example:

- `event.category: process and host.name: PC01` — everything that ran on PC01
- `event.category: authentication` — logons on every computer
- `event.kind: alert` — only Hayabusa detections
- `event.dataset: dissect.prefetch` — one artifact
- `file.hash.sha1: f6449ae7f5e9bdd11fd3d19f7444be1c969015ec` — one file on every computer
- `user.name: admin and event.code: 4624` — where admin logged on
- `artifact.description: *persist*` — everything described as a persistence location

Elasticsearch fills these fields while it indexes (the `super-timeline` ingest pipeline in
`elk/super-timeline/`). Artifacts without a clear ECS category have no `event.category`;
`event.dataset` always says what they are. To add or change categories, edit
`elk/super-timeline/rules.json` (descriptions: `descriptions.json`), raise the `version` in
`rules.json`, and run `elk/configure.sh`: it updates the timelines you already have in the
background.

Timelines exported before `artifact.description` existed (UAC, iLEAPP, ALEAPP) have
`artifact` as plain text, which Elasticsearch can't change in place. `elk/configure.sh`
copies such an index to `<name>-st<version>`, deletes the old one once the copy has every
document, and keeps the old name as an alias, so exports to it keep working. Don't run an
export into that index while `configure.sh` copies it.

## 6. Stop, start, update

All commands run in the `openrelik-dfir-stack` folder.

| To | Run |
| --- | --- |
| Stop everything | `./stop.sh` |
| Start again | `./setup.sh` |
| Update the workers | `./setup.sh` (it pulls the newest versions) |

Your cases and timelines are kept when you stop and start.

## Problems

**`permission denied` when running Docker**
You were added to the `docker` group but have not logged out and in again. Do that,
or restart the computer.

**`port is already allocated` / something already uses port 8711, 8710, 9200 or 5601**
Another program (or an older OpenRelik) uses that port. Stop it, then run `./setup.sh` again.

**I lost the OpenRelik password**
Set a new one:
```bash
docker exec -it openrelik-server python admin.py change-password admin
```

**Kibana shows no data**
- Check that the time range (top right in Discover) covers the evidence: in the Super
  timeline that can be years, for example *Last 15 years*.
- Check that the Elasticsearch Export task finished in OpenRelik, and that *Parse input as
  JSON lines* was on.
- See which indexes exist: http://localhost:9200/_cat/indices?v

**A task fails with "the archive is truncated or damaged"**
The upload did not finish. Delete the file in OpenRelik and upload it again.

**Elasticsearch stops or the computer gets slow**
Elasticsearch uses 2 GB of memory. With more RAM, give it more: `ES_HEAP=4g ./setup.sh`.
With less RAM, use `ES_HEAP=1g ./setup.sh`.

**A large upload fails or stops near the end**
OpenRelik stores the upload in pieces and then joins them, so it needs **twice the file's
size** in free disk for a moment. A 22 GB file needs about 45 GB free. Check with `df -h`.
Upload only what you need: unpack a case package and upload the extraction inside it.

**The disk is full**
Deleting files in OpenRelik only marks them as deleted. Free the space with:
```bash
docker exec openrelik-server python admin.py purge-deleted-files
```

## What is in this folder

| File | What it does |
| --- | --- |
| `setup.sh` | installs and starts everything; safe to run again |
| `stop.sh` | stops everything |
| `docker-compose.override.yml` | adds the UAC, iLEAPP, ALEAPP, Dissect/Hayabusa, Takajo and Elasticsearch workers to OpenRelik |
| `elk/docker-compose.yml` | Elasticsearch and Kibana |
| `elk/configure.sh` | index templates, the Super timeline pipeline and Kibana views; `setup.sh` runs it |
| `elk/super-timeline/` | the pipeline (`pipeline.painless`), its categories (`rules.json`), artifact descriptions (`descriptions.json`) and a test (`test_pipeline.py`) |
| `openrelik/` | OpenRelik itself, created by `setup.sh` (your data is in `openrelik/data`) |

Using an OpenRelik you installed before? Run `./setup.sh /path/to/your/openrelik`.

## The parts

| Part | Source |
| --- | --- |
| UAC worker | https://github.com/Guzzy711/openrelik-worker-uac |
| iLEAPP worker | https://github.com/Guzzy711/openrelik-worker-ileapp |
| ALEAPP worker | https://github.com/Guzzy711/openrelik-worker-aleapp |
| Dissect and Hayabusa worker | https://github.com/Guzzy711/openrelik-worker-dissect |
| Takajo worker | https://github.com/Guzzy711/openrelik-worker-takajo |
| Elasticsearch worker | https://github.com/Guzzy711/openrelik-worker-elasticsearch |
| OpenRelik | https://openrelik.org |

Elasticsearch here runs without a password and only listens on your own computer
(`localhost`). Do not open its ports to a network.

## License

Apache 2.0, see [LICENSE](LICENSE).
