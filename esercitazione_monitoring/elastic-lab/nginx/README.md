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

Creo la cartella per la configurazione:

```bash
mkdir -p nginx
```
Una volta creata la cartella ci inserisco il file di configurazione `nginx.conf`:
> Ho bisogno dell'autenticazione per effettuare il mirroring, per cui ho bisogno della password ed ho deciso di utilizzare quella di elastic per semplicità.
> Per l'L'HTTP Basic Authentication, va fatto in base64 quindi ho prima recuperato la password dall' `.env` e l'ho salvata nella variabile `PASS`, dopodiché ho costruito una nuova variabile
> `AUTH_B64` prendendo il valore precedentemente salvato iniettandolo poi esplicitamente sul ramo mirror del `nginx.conf`(anche se per semplicità nel file l'ho lasciato esplicito).

```bash
PASS=$(grep '^ELASTIC_PASSWORD=' .env | cut -d= -f2-)
AUTH_B64=$(printf "elastic:%s" "$PASS" | base64)
# Salvo il risultato ottenuto e lo inserisco sul ramo mirror  dell'autenticazione `Basic ${AUTH_B64}`.

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
            proxy_set_header Authorization "Basic ZWxXXXXXXXXXX";
            proxy_http_version 1.1;
        }
    }
}
```

### Punti chiave:

- Blocco **events** e **http**: Events è obbligatorio in NGINX (configura la gestione delle connessioni), ed ho inserito poi come limite del corpo delle richieste a 100MB dato che le bulk
  delle metriche possono essere grandi e lasciando il default a 1 MB verrebbero rifiutate;
- Blocco del **server**:
  - `listen:9200` dove ascolta NGINX da dentro il container;
  - `resolver 127.0.0.11` è il **DNS interno di Docker** che serve perché il `proxy_pass` usa i nomi dei servizi (elasticsearch, elasticsearch2) che devono essere risolti a runtime da
    NGINX - Se non ci fosse il ramo mirror fallirebbe con `could not be resolved`;
  - I tre timeout coprono le richieste in long-polling del Fleet Server (che aspettano fino a 4 minuti);
- Ramo primario **location /**:
  Qui arriva tutto il traffico dall'agent, fa due cose:
  - `mirror /mirror + mirror_request_body on ` - dice a NGINX "duplica questa richiesta, corpo incluso, verso la location interna /mirror";
  - `proxy_pass $primary (http://elasticsearch:9200)` - inoltra la richiesta "vera" al cluster 1, la cui risposta torna all'agent, una volta settanta la variabile
    `$primary`(http://elasticsearch:9200);

  - `proxy_set_header Host $host` passa l'header Host originale; `proxy_http_version 1.1` usa HTTP/1.1 (necessario per keep-alive e per come l'agent parla);
  > Dettaglio: qui il nome l'ho messo in una variabile (set $primary ...) invece che diretto.
  > Quando proxy_pass usa una variabile, NGINX risolve il nome a runtime tramite il resolver per questo il resolver è obbligatorio in questa versione.

- Ramo mirror **location = /mirror**:
  Questa è la copia verso il cluster 2:
  - `internal` significa che la location non è raggiungibile dall'esterno e solo NGINX la usa internamente per il mirror;
  - `proxy_pass $secondary$request_uri` inoltra a elasticsearch2 preservando l'URL originale, così da far arrivare le metriche identiche;
  - La riga chiave è `proxy_set_header Authorization "Basic ZWxXXXXXXXXXX"` che inietta l'autenticazione verso il cluster 2 , altrimenti il
    cluster 2 rifiuta tutto con `401` (silenziosamente, perché il mirror è muto).

#### In sintesi
Riceve una richiesta → la manda al cluster 1 (risposta all'agent) → e in copia, con auth iniettata, al cluster 2.
> Il ramo mirror è best-effort: NGINX non aspetta la risposta del cluster 2.


## Passo 4 — Avviare NGINX e verificare che parta pulito:

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
