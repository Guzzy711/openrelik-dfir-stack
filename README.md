# OpenRelik DFIR stack

[OpenRelik](https://openrelik.org) with workers for Unix and iOS triage, and a local
Elasticsearch + Kibana for the timelines, set up with one script.

| Part | What it adds |
| --- | --- |
| [openrelik-worker-uac](https://github.com/Guzzy711/openrelik-worker-uac) | UAC collections: report, artifact extraction, timelines |
| [openrelik-worker-ileapp](https://github.com/Guzzy711/openrelik-worker-ileapp) | iLEAPP on iOS full file system extractions and iTunes backups |
| [openrelik-worker-elasticsearch](https://github.com/Guzzy711/openrelik-worker-elasticsearch) | exports worker output to Elasticsearch with the bulk API |
| `elk/` | Elasticsearch 8 and Kibana, localhost only, security off |

## Install

Needs Linux (or macOS) with Docker, the Docker Compose plugin, curl, and about 8 GB of RAM.

```bash
git clone https://github.com/Guzzy711/openrelik-dfir-stack.git
cd openrelik-dfir-stack
./setup.sh
```

`setup.sh`:

1. Runs the official OpenRelik installer when `./openrelik` doesn't exist yet. It asks
   which version to install and prints the `admin` password once: write it down.
   For an existing install, pass its folder: `./setup.sh /path/to/openrelik`.
2. Copies `docker-compose.override.yml` into the OpenRelik folder (an existing override
   is saved as `.bak.<time>`), pulls the worker images from GHCR and starts everything.
3. Starts Elasticsearch and Kibana on OpenRelik's Docker network, so the Elasticsearch
   worker reaches them at `http://elasticsearch:9200`.
4. Creates index templates without replicas for `uac-*`, `ileapp-*` and `openrelik-*`, and
   Kibana data views for them on `@timestamp`.

Run it again at any time; it skips what is done and pulls newer worker images.

| Service | URL |
| --- | --- |
| OpenRelik | http://localhost:8711 (user `admin`) |
| Kibana | http://localhost:5601 |
| Elasticsearch | http://localhost:9200 |

Elasticsearch uses 2 GB of heap; set `ES_HEAP=4g` before `./setup.sh` for more.

## Using it

A workflow for a UAC collection: upload the `uac-*.tar.gz`, add *UAC: Timeline*, and
chain *Elasticsearch Export* with index name `uac-<host>` and *Parse input as JSON lines*
on. The timeline shows in Kibana under *UAC timelines*.

For an iPhone: upload a full file system extraction (`.zip`, `.tar`) or a zipped iTunes
backup, add *iLEAPP: iOS artifacts* (with the backup password for an encrypted backup),
and chain *Elasticsearch Export* with index name `ileapp-<device>`.

## Stop, update, remove

```bash
(cd openrelik && docker compose down)          # stop OpenRelik
docker compose -f elk/docker-compose.yml down  # stop Elasticsearch and Kibana
./setup.sh                                     # update worker images and start again
```

`docker compose -f elk/docker-compose.yml down -v` also deletes the Elasticsearch data.

## License

Apache 2.0, see [LICENSE](LICENSE).
