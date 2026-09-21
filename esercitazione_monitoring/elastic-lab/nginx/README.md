# Fan-out delle metriche su due cluster Elasticsearch con NGINX

Configurazione di **un solo Elastic Agent** che invia le stesse
metriche di sistema a **due cluster Elasticsearch indipendenti**, usando **NGINX** come
reverse-proxy con duplicazione (`mirror`).

Ambiente: **Elastic Stack 8.15.0** su Docker Compose, security abilitata, HTTP in chiaro.

---

## Obiettivo

Avere un secondo server di monitoraggio interno oltre a quello primario, in modo che le
stesse metriche siano visibili in due cluster separati. Vincolo: **un solo agent**, senza
**Logstash**(che la policy Fleet blocca) e senza un secondo output impossibile senza licenza Enterprise in produzione.

## Architettura

```
                          ┌──────────────► elasticsearch  (:9200)  [primario, risposta all'agent]
Elastic Agent ──► NGINX ──┤
   (system)      (:9200)  └ ─ ─ ─ ─ ─ ─ ─► elasticsearch2 (:9200)  [mirror, best-effort]

```

NGINX si presenta all'agent come se fosse un normale Elasticsearch. Ogni richiesta di scrittura (`_bulk`) viene inoltrata al **cluster primario** (la cui risposta torna all'agent) e **duplicata** verso il **cluster secondario** tramite la direttiva `mirror`.

### Perché NGINX e non Logstash??
Una policy che contiene il Fleet Server non può usare un output di tipo Logstash per le integrazioni. NGINX invece è visto come un output
**Elasticsearch**, che non ha questo vincolo → Possiamo restare con **un agent solo**.

## Possibile problema:
Il ramo mirror è **best-effort**: NGINX non attende né verifica la risposta del secondo cluster. Adatto a un backup di monitoraggio interno, non a scenari dove entrambi i cluster sono critici allo stesso modo.

---

## Prerequisiti

- Stack `elastic-lab` funzionante (elasticsearch, kibana, fleet-server, un Elastic Agent gestito da Fleet).
- Un **secondo Elasticsearch** (`elasticsearch2`) sulla stessa rete Docker.
> Valido con degli accorgimenti anche in un Cluster aziendale

> I due cluster condividono la stessa password `elastic` (semplificazione da lab).

---

## Passo 1 — Secondo Elasticsearch nel compose

Preso il `docker-compose.yml` che ho utilizzato per il lab precedente, ho aggiunto un secondo server (server di monitoraggio interno) **elasticsearch2**:

```yaml
  elasticsearch2:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.15.0
    container_name: elasticsearch2
    networks: [elastic-lab-net]
    ports:
      - "9201:9200"          # sull'host 9201, dentro Docker resta 9200
    environment:
      - discovery.type=single-node
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
      - xpack.security.enabled=true
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - xpack.security.http.ssl.enabled=false
    healthcheck:
      test: ["CMD-SHELL", "curl -s --fail -u elastic:${ELASTIC_PASSWORD} 'http://localhost:9200/_cluster/health?wait_for_status=yellow&timeout=5s' || exit 1"]
      interval: 10s
      timeout: 10s
      retries: 30
      start_period: 60s
```
### Punti chiave:
- Ho usato la stessa versione dell'immagine del primo per non avere disallineamenti e l'ho connesso alla stessa rete degli altri servizi
  `elastic-lab-net`;
- Ho mappato la porta 9200 con cui ES ascolta da dentro Docker, esponendolo sulla 9201 sull'host (essendo la 9200 occupato dal primo
  Elasticsearch);
- Ho aggiunto le `env` di configurazione:
  - `discovery.type=single-node`: Essa dice al nodo "sei un cluster da solo, non cercare altri nodi con cui federarti". Per farlo restare separato dal primo ES.
  - `ES_JAVA_OPTS=-Xms1g -Xmx1g`: Assegno 1 GB di heap Java.
  - `xpack.security.enabled=true`: Con esso attivo la sicurezza (password, autenticazione).
  - `ELASTIC_PASSWORD=${ELASTIC_PASSWORD}`: Imposto la password dell'utente elastic, presa dal file .env.
  - `xpack.security.http.ssl.enabled=false`: HTTP in chiaro sulla 9200 (niente TLS), coerente con quello fatto su.
    > Per comodità ho usato la stessa password in produzione ovviamente non sarà così e ci sarà un tipo di sicurezza diversa anche per l'HTTP in chiaro.
- Ho aggiunto infine il blocco `healthcheck`; Esso dice a Docker come capire se il nodo è sano:
  - Ogni 10 secondi (`interval`) esegue un `curl` all'endpoint di health del cluster (Se risponde entro i tempi è healthy);
  - `start_period:60s` gli dò un minuto di grazia all'avvio (ES lento a partire) prima di considerare i fallimenti.Serve perché altri servizi possono aspettare che sia healthy prima di
    avviarsi.
    
### Avviarlo e verificarne la salute:

```bash
docker compose up -d elasticsearch2
docker compose ps elasticsearch2   # atteso: Up (healthy)
```
---

## Passo 2 — Container NGINX nel compose
Ho aggiunto poi il servizio NGINX sempre nel compose, esso è il componente che riceve le scritture dell'agent e le manda ad entrambi i cluster:

```yaml
  nginx:
    image: nginx:1.27-alpine
    container_name: nginx
    networks: [elastic-lab-net]
    ports:
      - "9210:9200"          # host 9210 per test dal Mac; dentro Docker resta 9200
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      elasticsearch:
        condition: service_healthy
      elasticsearch2:
        condition: service_healthy
```
### Punti chiave:
- Ho usato una immagine NGINX leggera (variante Alpine piccola), gli ho dato un nome e l'ho collegato alla stessa rete docker degli altri servizi;
- Ho mappato la porta 9200 dentro Docker (così l'output di Fleet lo raggiunge come `nginx:9200` ), esponendolo sulla 9210 sull'host (essendo la 9200 e 9201 occupato dal primo e dal secondo
  Elasticsearch);
- Ho messo 2 `depends_on` con `condition: service_healty` su entrambi gli ES, in modo che NGINX si avvii solo dopo che i 2 cluster siano sani.
- Ho messo un volume `./nginx/nginx.conf:/etc/nginx/nginx.conf:ro` che monta il file di configurazione `nginx/nginx.conf` (spiegato successivamente) mettendo il :ro finale in modo che il
  container può solo leggerlo e non modificarlo.
> N.B: Non ho avviato NGINX finché non esiste `nginx/nginx.conf` (Passo 3), altrimenti non parte.

---

## Passo 3 — Configurazione NGINX (mirror)

Creare la cartella per la configurazione:

```bash
mkdir -p nginx
```
Creare `nginx/nginx.conf`. Il valore `AUTH_B64` è l'autenticazione Basic del cluster
secondario, iniettata esplicitamente sul ramo mirror (vedi nota più sotto).

```bash
PASS=$(grep '^ELASTIC_PASSWORD=' .env | cut -d= -f2-)
AUTH_B64=$(printf "elastic:%s" "$PASS" | base64)

cat > nginx/nginx.conf << EOF
events {
    worker_connections 1024;
}

http {
    client_max_body_size 100m;

    server {
        listen 9200;
        resolver 127.0.0.11 valid=10s;        # DNS interno di Docker

        proxy_read_timeout 300s;              # per le long-poll del Fleet Server
        proxy_send_timeout 300s;
        proxy_connect_timeout 75s;

        # Ramo primario: cluster 1 (la risposta torna all'agent)
        location / {
            mirror /mirror;
            mirror_request_body on;

            set \$primary "http://elasticsearch:9200";
            proxy_pass \$primary;
            proxy_set_header Host \$host;
            proxy_http_version 1.1;
        }

        # Ramo mirror: cluster 2 (copia best-effort, auth iniettata)
        location = /mirror {
            internal;
            set \$secondary "http://elasticsearch2:9200";
            proxy_pass \$secondary\$request_uri;
            proxy_set_header Host \$host;
            proxy_set_header Authorization "Basic ${AUTH_B64}";
            proxy_http_version 1.1;
        }
    }
}
EOF
```

Punti chiave della configurazione:

- **`resolver 127.0.0.11`**: quando `proxy_pass` usa una variabile, NGINX risolve il nome a
  runtime. Serve il DNS interno di Docker, altrimenti il ramo mirror fallisce con
  `could not be resolved`.
- **`mirror` + `mirror_request_body on`**: duplica la richiesta *e* il suo corpo verso la
  location interna `/mirror`.
- **`proxy_read_timeout 300s`**: il Fleet Server fa richieste in long-polling (fino a 4
  minuti). Senza timeout ampi, NGINX le interrompe con `504`.
- **`Authorization "Basic ..."` sul mirror**: l'autenticazione dell'agent non si propaga
  automaticamente alla subrequest del mirror. Va iniettata esplicitamente, altrimenti il
  cluster 2 rifiuta tutto con `401` (silenziosamente, perché il mirror è muto).

Avviare NGINX e verificare che parta pulito:

```bash
docker compose up -d nginx
docker compose logs nginx --tail 10   # atteso: "Configuration complete; ready for start up"
```

Test rapido del proxy (via porta host 9210):

```bash
export ELASTIC_PASSWORD=$(grep '^ELASTIC_PASSWORD=' .env | cut -d= -f2-)
curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9210/" | head
# atteso: JSON di benvenuto di Elasticsearch
```

<!-- IMMAGINE: log NGINX all'avvio -->

---

## Passo 4 — Provisioning del cluster secondario (template + pipeline)

Il cluster 2, non essendo gestito da Fleet, **non ha** i template e le ingest pipeline che
l'integrazione System installa automaticamente. Senza di essi, Elasticsearch non sa creare
i data stream `metrics-system.*` e rifiuta i documenti.

Vanno copiati dal cluster 1: **component template**, **index template** e **ingest
pipeline** (incluse le `.fleet_*`, in particolare `.fleet_final_pipeline-1`).

Script di copia (component + pipeline + index template):

```python
# copia_template.py
import requests, os, sys
PWD = os.environ.get("ELASTIC_PASSWORD")
if not PWD: sys.exit("ELASTIC_PASSWORD non trovata")
SRC="http://localhost:9200"; DST="http://localhost:9201"; AUTH=("elastic",PWD)
PATTERN="metrics-system"

EXTRA_COMPONENTS = [
    "metrics@tsdb-settings", "ecs@mappings",
    ".fleet_globals-1", ".fleet_agent_id_verification-1",
]

def get(u):
    r=requests.get(u,auth=AUTH); r.raise_for_status(); return r.json()
def put(u,b):
    r=requests.put(u,auth=AUTH,json=b,headers={"Content-Type":"application/json"})
    return r.status_code, r.text
def copy_component(name):
    try:
        d=get(f"{SRC}/_component_template/{name}")
        b=d["component_templates"][0]["component_template"]
        print("  [%s] %s" % put(f"{DST}/_component_template/{name}", b)[::-1])
    except Exception as e:
        print(f"  [ERR] {name}: {e}")

for n in EXTRA_COMPONENTS: copy_component(n)
for c in get(f"{SRC}/_component_template/{PATTERN}*").get("component_templates",[]):
    put(f"{DST}/_component_template/{c['name']}", c["component_template"])
for name, body in get(f"{SRC}/_ingest/pipeline/{PATTERN}*").items():
    put(f"{DST}/_ingest/pipeline/{name}", body)
for t in get(f"{SRC}/_index_template/{PATTERN}*").get("index_templates",[]):
    put(f"{DST}/_index_template/{t['name']}", t["index_template"])
print("Template copiati.")
```

Script separato per le pipeline `.fleet_*` (necessarie a ogni data stream Fleet):

```python
# copia_fleet_pipeline.py
import requests, os, sys
PWD = os.environ.get("ELASTIC_PASSWORD")
if not PWD: sys.exit("ELASTIC_PASSWORD non trovata")
SRC="http://localhost:9200"; DST="http://localhost:9201"; AUTH=("elastic",PWD)
def get(u):
    r=requests.get(u,auth=AUTH); r.raise_for_status(); return r.json()
def put(u,b):
    r=requests.put(u,auth=AUTH,json=b,headers={"Content-Type":"application/json"})
    return r.status_code
pipes = get(f"{SRC}/_ingest/pipeline/*fleet*")
for name, body in pipes.items():
    print(put(f"{DST}/_ingest/pipeline/{name}", body), name)
print("Pipeline .fleet* copiate.")
```

Esecuzione:

```bash
export ELASTIC_PASSWORD=$(grep '^ELASTIC_PASSWORD=' .env | cut -d= -f2-)
python3 copia_template.py
python3 copia_fleet_pipeline.py
```

> Nota: gli ES del lab non hanno volume dati persistente. Dopo un riavvio dello stack, il
> cluster 2 riparte pulito e i template vanno **ricopiati**.

---

## Passo 5 — Puntare l'output di Fleet a NGINX

In **Kibana → Fleet → Settings → Outputs**, modificare l'output `default` (tipo
Elasticsearch) e impostare come host:

```
http://nginx:9200
```

(nome del servizio Docker + porta interna 9200). Salvare con *Save and apply settings*.
Da questo momento l'agent scrive verso NGINX, che duplica sui due cluster.

<!-- IMMAGINE: Fleet → Settings → Outputs con host http://nginx:9200 -->

---

## Passo 6 — Verifica del fan-out

Attendere 1-2 minuti che l'agent invii qualche ciclo di metriche, poi confrontare i due
cluster:

```bash
export ELASTIC_PASSWORD=$(grep '^ELASTIC_PASSWORD=' .env | cut -d= -f2-)

echo "=== CLUSTER 1 ==="
curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9200/_cat/indices/metrics-system*?v&h=index,docs.count"

echo "=== CLUSTER 2 ==="
curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9201/_cat/indices/metrics-system*?v&h=index,docs.count"
```

Entrambi devono mostrare i data stream `metrics-system.*` con `docs.count` in crescita.

Verifica del ramo mirror nei log di NGINX (traffico dell'agent con esito 200):

```bash
docker compose logs nginx --tail 40 | grep "_bulk"
# atteso: POST /_bulk ... 200 ... Elastic-metricbeat / Elastic-filebeat
```

Lato Kibana (cluster 1), il monitoraggio è visibile in
**Observability → Infrastructure → Hosts / Inventory**.

<!-- IMMAGINE: Kibana → Observability → Hosts con l'host e i grafici CPU/Memoria/Rete -->
<!-- IMMAGINE: confronto _count sui due cluster / elenco metrics-system del cluster 2 -->
<!-- IMMAGINE: log NGINX con righe "_bulk ... 200" o "uri=/mirror | status=200" -->

---

## Note e limitazioni

- **Autenticazione sul mirror**: l'header `Authorization` va iniettato a mano perché non si
  propaga alla subrequest. Nel lab funziona con le stesse credenziali su entrambi i cluster;
  in produzione con password diverse si userebbero qui le credenziali del cluster 2.
- **Best-effort**: il ramo mirror non garantisce la consegna. Se il cluster 2 è lento o giù,
  le copie si perdono senza che l'agent se ne accorga. Accettabile per un backup interno.
- **Provisioning del cluster ricevente**: qualunque scrittura verso data stream Fleet richiede
  template e pipeline già presenti sul cluster di destinazione.
- **Segreti**: `nginx.conf` contiene l'auth in base64 → escluderlo da Git (`.gitignore`) e
  versionare una versione `nginx.conf.example` con placeholder.
- **Lab vs produzione**: qui NGINX è containerizzato per semplicità; in produzione starebbe
  su una VM/pod dedicato come componente di infrastruttura condiviso.

---

## Pulizia (opzionale)

Rimozione di eventuali indici di test creati durante le verifiche:

```bash
export ELASTIC_PASSWORD=$(grep '^ELASTIC_PASSWORD=' .env | cut -d= -f2-)
curl -s -u "elastic:${ELASTIC_PASSWORD}" -X DELETE "http://localhost:9200/test-*"
curl -s -u "elastic:${ELASTIC_PASSWORD}" -X DELETE "http://localhost:9201/test-*"
```
