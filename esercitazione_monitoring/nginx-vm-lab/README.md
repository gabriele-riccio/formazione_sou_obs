# Fan-out delle metriche su due cluster Elasticsearch con NGINX (su VM)

Reverse proxy **NGINX** su VM dedicata che, tramite la direttiva nativa **`mirror`**,
duplica il traffico di un **singolo Elastic Agent** verso **due cluster Elasticsearch
indipendenti**.

Ambiente: **Elastic Stack 8.15.0** (in Docker) + **NGINX 1.18** (su VM Vagrant/Ubuntu 22.04).

---

## Indice

- [Obiettivo](#obiettivo)
- [Architettura](#architettura)
- [Perché NGINX (e perché su VM)](#perché-nginx-e-perché-su-vm)
- [Prerequisiti](#prerequisiti)
- [Struttura dei file](#struttura-dei-file)
- [Passo 1 — Stack Docker (due cluster)](#passo-1--stack-docker-due-cluster)
- [Passo 2 — La configurazione NGINX](#passo-2--la-configurazione-nginx)
- [Passo 3 — Il Vagrantfile](#passo-3--il-vagrantfile)
- [Passo 4 — Avvio della VM](#passo-4--avvio-della-vm)
- [Passo 5 — Test del mirror (documento di prova)](#passo-5--test-del-mirror-documento-di-prova)
- [Passo 6 — Provisioning del cluster ricevente](#passo-6--provisioning-del-cluster-ricevente)
- [Passo 7 — Puntare l'agent a NGINX e verifica fan-out](#passo-7--puntare-lagent-a-nginx-e-verifica-fan-out)
- [Note e limitazioni](#note-e-limitazioni)
- [Confronto con le altre varianti](#confronto-con-le-altre-varianti)

---

## Obiettivo

Realizzare un **server di monitoraggio interno** oltre a quello del cliente: le stesse
metriche di sistema, raccolte da **un solo Elastic Agent**, devono arrivare in **due cluster
Elasticsearch** indipendenti (principale + interno).

La regola è "**un agent, due output**". Le vie native hanno vincoli (licenza Enterprise per
gli output-per-integrazione; il Fleet Server non accetta un output Logstash), quindi la
duplicazione viene fatta **fuori dall'agent**, da NGINX che si presenta come un normale
Elasticsearch.

## Architettura

```
                              ┌──────────────► 192.168.56.1:9200  (cluster 1, risposta all'agent)
Elastic Agent ──► NGINX ──────┤
   (metriche)   (VM :9210)    └ ─ (mirror) ─ ► 192.168.56.1:9201  (cluster 2, best-effort)
```

- NGINX ascolta sulla porta **9210** della VM (`192.168.56.51`).
- Il `location /` inoltra al **cluster 1** con `proxy_pass` (la cui risposta torna all'agent)
  e, con la direttiva **`mirror`**, invia una **copia** a una location interna che punta al
  **cluster 2**.
- I due cluster girano in Docker sull'host, esposti su `192.168.56.1:9200` e `:9201`; dalla
  VM l'host si vede come `192.168.56.1`.

## Perché NGINX (e perché su VM)

- **NGINX ha `mirror` nativo** → la duplicazione è una direttiva pronta: niente script, niente
  logica custom. (Con HAProxy 2.4 serviva invece uno script Lua e una libreria HTTP scritta a
  mano su `core.tcp`.)
- **Su VM**, NGINX raggiunge i cluster tramite **IP letterali** dell'host (`192.168.56.1`):
  usando IP diretti nel `proxy_pass` **non serve alcun `resolver`** (che invece era necessario
  quando NGINX girava come container e usava i nomi dei servizi Docker).
- Il **gzip** non dà problemi: nel ramo `mirror` NGINX inoltra automaticamente gli header
  originali, incluso `Content-Encoding: gzip`.

## Prerequisiti

- Stack `elastic-lab` funzionante (Elasticsearch, Kibana, Fleet Server, un Elastic Agent).
- Un **secondo Elasticsearch** (`elasticsearch2`), esposto sull'host (porta 9201).
- **Vagrant + VirtualBox**.
- Connettività dalla VM verso l'host (`192.168.56.1`) sulle porte 9200 / 9201.
- I due cluster condividono la stessa password `elastic` (semplificazione da lab).

## Struttura dei file

```
nginx-vm-lab/
├── Vagrantfile          # definisce e provisiona la VM NGINX
├── nginx.conf           # configurazione NGINX (server + mirror)  [ESCLUSO da Git: contiene l'auth]
├── nginx.conf.example   # versione con placeholder al posto del base64
└── .gitignore           # esclude nginx.conf e .vagrant/
```

---

## Passo 1 — Stack Docker (due cluster)

Nel `docker-compose.yml` dello stack Elastic vanno esposte sull'host le porte che la VM
raggiungerà: `9200` (cluster 1) e `9201` (cluster 2). Il secondo cluster è un nodo
`single-node` isolato dal primo:

```yaml
  elasticsearch2:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.15.0
    container_name: elasticsearch2
    networks: [elastic-lab-net]
    ports:
      - "9201:9200"
    environment:
      - discovery.type=single-node
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
      - xpack.security.enabled=true
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - xpack.security.http.ssl.enabled=false
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
    
Avvio lo stack (non serve per far partire la VM, ma serve per i test):

```bash
cd elastic-lab
docker compose up -d
docker compose ps      # elasticsearch ed elasticsearch2 devono essere (healthy)
```

## Passo 2 — La configurazione NGINX

Ho bisogno dell'autenticazione per effettuare il mirroring, per cui ho bisogno della password ed ho deciso di utilizzare quella di elastic per semplicità.Per l'HTTP Basic Authentication, va fatto in base64 quindi ho prima recuperato la password dall' `.env` e l'ho salvata nella variabile `PASS`, dopodiché ho costruito una nuova variabile `AUTH_B64` prendendo il valore precedentemente salvato, iniettandolo poi esplicitamente sul ramo `mirror` del `nginx.conf` (anche se per semplicità nel file l'ho lasciato esplicito):

```bash
PASS=$(grep '^ELASTIC_PASSWORD=' .env | cut -d= -f2-)
AUTH_B64=$(printf "elastic:%s" "$PASS" | base64)
# Salvo il risultato ottenuto e lo inserisco sul ramo mirror  dell'autenticazione `Basic ${AUTH_B64}`.
```
Vediamo il file:

```nginx
events {
    worker_connections 1024;
}

http {
    client_max_body_size 100m;          # le bulk delle metriche possono essere grandi

    server {
        listen 9210;

        proxy_read_timeout 300s;        # per le long-poll del Fleet Server
        proxy_send_timeout 300s;
        proxy_connect_timeout 75s;

        # Ramo primario: cluster 1 (la risposta torna all'agent)
        location / {
            mirror /mirror;
            mirror_request_body on;     # duplica anche il corpo della richiesta (_bulk)

            proxy_pass http://192.168.56.1:9200;
            proxy_set_header Host $host;
            proxy_http_version 1.1;
        }

        # Ramo mirror: cluster 2 (copia best-effort, auth iniettata)
        location = /mirror {
            internal;
            proxy_pass http://192.168.56.1:9201$request_uri;
            proxy_set_header Host $host;
            proxy_set_header Authorization "Basic ${AUTH_B64}"; # nel file ho lasciato "Basic ZWxXXXXXXXXXX"
            proxy_http_version 1.1;
        }
    }
}
```

### Punti chiave:

- Blocco **events** e **http**: Events è obbligatorio in NGINX (configura la gestione delle connessioni), ed ho inserito poi come limite del corpo delle richieste a 100MB dato che le bulk
  delle metriche possono essere grandi e lasciando il default a 1 MB verrebbero rifiutate;
- Blocco del **server**:
  - **listen 9210** è la porta su cui ascolta NGINX sulla VM (a differenza della versione in container, qui NGINX è un servizio nativo della VM e ascolta direttamente su questa porta, senza
    mappature Docker);
  - **Nessun resolver**: in questa versione non serve. NGINX raggiunge i due cluster tramite gli IP letterali dell'host (192.168.56.1), non tramite i nomi dei servizi Docker, quindi non c'è
    alcun nome da risolvere a runtime;
  - I tre timeout coprono le richieste in **long-polling** del Fleet Server (che aspettano fino a 4 minuti);
- Ramo primario **location /**:
  Qui arriva tutto il traffico dall'agent, fa due cose:
  - **mirror /mirror + mirror_request_body on**: Dice a NGINX "duplica questa richiesta, corpo incluso, verso la location interna **/mirror**";
  - **proxy_pass http://192.168.56.1:9200**: Inoltra la richiesta "vera" al cluster 1, la cui risposta torna all'agent - con IP letterale (niente `upstream`, e niente `resolver`);
  - **proxy_set_header Host $host** passa l'header Host originale, mentre **proxy_http_version 1.1** usa HTTP/1.1 (necessario per keep-alive e per come l'agent parla);
    > Dettaglio: qui uso l'IP dell'host direttamente nel `proxy_pass`, senza variabili. È la semplificazione rispetto alla versione in container, dove i nomi dei servizi Docker in una
    > variabile obbligavano ad avere il resolver. Con l'IP letterale, resolver e variabili non servono.
- Ramo mirror **location = /mirror**:
  Questa è la copia verso il secondo cluster:
  - **internal** significa che la location non è raggiungibile dall'esterno e solo **NGINX** la usa internamente per il **mirror**;
  - **proxy_pass http://192.168.56.1:9201$request_uri** inoltra a elasticsearch2 (sull'host, porta 9201) preservando l'URL originale, così da far arrivare le metriche identiche;
  - La riga chiave è **proxy_set_header Authorization "Basic ZWxXXXXXXXXXX"** che inietta l'autenticazione verso il cluster 2, altrimenti il cluster 2 rifiuta tutto con 401 (silenziosamente,
    perché il mirror è muto).

## Passo 3 — Il Vagrantfile

Box Ubuntu, IP privato fisso, provisioning che installa nginx, copia la config e la valida
con `nginx -t` prima di riavviare.

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.hostname = "nginx-fanout-proxy"
  config.vm.network "private_network", ip: "192.168.56.51"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = "512"  #inserisco soltanto 512 MB vanno più che bene
    vb.cpus = 1
  end

  config.vm.provision "file", source: "nginx.conf", destination: "/tmp/nginx.conf"  # Prendo il file di config per il provisioning e lo metto in un file temporaneo.

  config.vm.provision "shell", inline: <<-SHELL
    set -e     #solito blocco per errori di sintassi
    apt-get update
    apt-get install -y nginx   #Installo nginx

    cp /tmp/nginx.conf /etc/nginx/nginx.conf  # Copio nella cartella dei file di configurazione

# Scriptino per validare la config prima del riavvio altrimenti il provisioning si ferma.

    if nginx -t; then
      systemctl restart nginx
      systemctl enable nginx
      echo "== Nginx avviato correttamente =="
    else
      echo "!! ERRORE nella config NGINX: NON riavviato !!"
      exit 1
    fi
  SHELL
end
```

> IP `192.168.56.51` diverso da eventuali altre VM (es. HAProxy su `.50`) per non collidere.
> `nginx -t` valida la config prima del riavvio: se c'è un errore di sintassi il provisioning si ferma con un messaggio chiaro.

## Passo 4 — Avvio della VM

Con `nginx.conf` (col base64 vero) e `Vagrantfile` presenti nella cartella:

```bash
vagrant up            # prima volta (scarica il box, installa nginx, valida, avvia)
# oppure, se la VM esiste e hai cambiato la config:
vagrant provision
```

Esito atteso in fondo: `nginx: configuration file ... test is successful` +
`== Nginx avviato correttamente ==`.

## Passo 5 — Test del mirror (documento di prova)

Prima di collegare l'agent, si verifica il meccanismo con un documento scritto **via NGINX**
(porta 9210 della VM), controllando che arrivi in entrambi i cluster:

```bash
export ELASTIC_PASSWORD=password
curl -s -u "elastic:${ELASTIC_PASSWORD}" -X POST \
  "http://192.168.56.51:9210/test-nginx-vm/_doc" \
  -H "Content-Type: application/json" -d '{"prova":"nginx-vm"}'
echo ""
sleep 3
echo "--- CLUSTER 1 ---"
curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9200/test-nginx-vm/_count"   # cluster 1
echo ""
echo "--- CLUSTER 2 ---"
curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9201/test-nginx-vm/_count"   # cluster 2
```

Entrambi devono dare `"count":1` → il mirror duplica correttamente.

![seconda_parte](nginx/Screenshot%202026-09-21%20alle%2011.44.41.png)

## Passo 6 — Provisioning del cluster ricevente

Il cluster 2, non essendo gestito da Fleet, ha bisogno dei **template** e delle **ingest pipeline** che l'integrazione System installa automaticamente. Senza di essi, Elasticsearch non sa creare i data stream `metrics-system.*` e rifiuta i documenti.

Vanno copiati dal cluster 1: **component template**, **index template** e **ingest pipeline** (incluse le `.fleet_*`, in particolare `.fleet_final_pipeline-1`).
Nel vecchio lab ho scritto uno script python che li ha copiati in automatico:

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
### Punti chiave:
- Questi script prendono quegli oggetti dal cluster 1 (**localhost:9200**) e li ricreano identici sul cluster 2 (**localhost:9201**), via API REST;
- **La testa dello script** `copia_template.py` legge la **password** dall'ambiente (esce se manca), definisce la **sorgente** (SRC, cluster 1), la **destinazione** (DST, cluster 2),
  l'**autenticazione**, e il **pattern degli oggetti** da copiare (metrics-system). Le due funzioni base:
  - ```python
    def get(u): ...   # fa una GET verso un URL e ritorna il JSON
    def put(u,b): ... # fa una PUT (crea/aggiorna un oggetto) e ritorna status + testo
    ```
    - **get** legge un oggetto dal cluster 1, **put** lo scrive sul cluster 2;
  - ```python
    EXTRA_COMPONENTS = ["metrics@tsdb-settings", "ecs@mappings",
                    ".fleet_globals-1", ".fleet_agent_id_verification-1"]
    def copy_component(name):
      try:
          d=get(f"{SRC}/_component_template/{name}")
          b=d["component_templates"][0]["component_template"]
          print("  [%s] %s" % put(f"{DST}/_component_template/{name}", b)[::-1])
      except Exception as e:
          print(f"  [ERR] {name}: {e}")
    ```
    - Questi sono i component template "di base" mattoncini condivisi (**settings TSDB, mapping ECS, globali Fleet**) che gli index template **metrics-system** referenziano ma che non
      matchano il pattern **metrics-system***. Se non li copio per primi, gli index template falliscono con "missing component template";
    - La funzione **copy_component** li legge dal cluster 1 e li scrive sul 2, gestendo con **try/except** il caso in cui uno non esista (stampa [ERR] senza fermare tutto).
- **Il corpo dello script** regola l'ordine:
  - ```python
    for n in EXTRA_COMPONENTS: copy_component(n)                     # 1. component base condivisi
    for c in get(...component_template/metrics-system*...): put(...) # 2. component template metrics-system
    for name, body in get(...ingest/pipeline/metrics-system*...): put(...)  # 3. ingest pipeline
    for t in get(...index_template/metrics-system*...): put(...)    # 4. index template
    ```
  - L'ordine va dal basso verso l'alto: prima i mattoni (component template), poi le pipeline, e per ultimi gli index template, dato che questi ultimi referenziano tutto il resto e vanno
    creati quando le loro dipendenze esistono già. Se li mettessi per primi, fallirebbero.
- Il **copia_fleet_pipeline.py** è più semplice, copia tutte le ingest pipeline il cui nome contiene **fleet (*fleet*)**. Serve perché ogni data stream Fleet passa attraverso una pipeline
  "finale" chiamata **.fleet_final_pipeline-1** che ho scoperto mancante, senza la quale il cluster 2 rifiutava tutto con l'errore sulla pipeline inesistente. Il pattern *fleet* prende quella
  e le altre **.fleet_*** correlate in un colpo.
  > 2 script separati perchè coprono due "famiglie" di oggetti diversi.

#### Verifico se ci sono:

```bash
curl -s -u "elastic:password" \
  "http://localhost:9201/_index_template/metrics-system.cpu?filter_path=index_templates.name"
```

Se la risposta è vuota, copiali dal cluster 1 (script già usati negli altri lab):

```bash
cd ../elastic-lab
export ELASTIC_PASSWORD=password
python3 copia_template.py
python3 copia_fleet_pipeline.py
```
![seconda_parte](nginx/Screenshot%202026-09-22%20alle%2012.30.22.png)

## Passo 7 — Puntare l'agent a NGINX e verifica fan-out

Verifica che il container dell'agent raggiunga la VM:

```bash
docker exec fleet-server curl -s -u "elastic:password" \
  "http://192.168.56.51:9210/" -o /dev/null -w "%{http_code}\n"   # atteso: 200
```

Poi in **Kibana → Fleet → Settings → Outputs**, modifico l'output `default` (tipo
Elasticsearch) e imposto come host `http://192.168.56.51:9210`. Salva.

> Un solo proxy alla volta deve ricevere l'output dell'agent: se c'era un'altra VM proxy
> (es. HAProxy), il traffico ora va a NGINX.
![seconda_parte](nginx/Screenshot%202026-09-21%20alle%2011.55.23.png)

Verifica fan-out:
```bash
export ELASTIC_PASSWORD=password
curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9201/metrics-system.cpu-default/_count"
sleep 120
curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9201/metrics-system.cpu-default/_count"
```
![seconda_parte](nginx/Screenshot%202026-09-21%20alle%2012.00.25.png)

Il secondo conteggio deve essere **più alto** del primo → le metriche `system` arrivano al
cluster 2 attraverso NGINX.

Prova anche dai log NGINX (sulla VM) che passino le bulk vere:

```bash
vagrant ssh -c "sudo tail -20 /var/log/nginx/access.log | grep _bulk | tail -5"
```
Atteso: righe `POST /_bulk...` con codice **200** e user-agent `Elastic-metricbeat` /
`Elastic-filebeat` / `Elastic-Fleet-Server`.

![seconda_parte](nginx/Screenshot%202026-09-21%20alle%2012.01.51.png)

In **Kibana → Observability → Infrastructure → Inventory/Hosts**:

![seconda_parte](nginx/Screenshot%202026-09-21%20alle%2012.32.38.png)
![seconda_parte](nginx/Screenshot%202026-09-21%20alle%2012.33.13.png)
![seconda_parte](nginx/Screenshot%202026-09-21%20alle%2012.33.27.%20png)
![seconda_parte](nginx/Screenshot%202026-09-21%20alle%2012.33.35.%20png)
![seconda_parte](nginx/Screenshot%202026-09-21%20alle%2012.33.41.png)

---

## Note e limitazioni

- **Best-effort**: il ramo `mirror` è fire-and-forget; NGINX non attende la risposta del
  cluster 2. Se il cluster 2 è lento o giù, alcune copie si perdono senza che l'agent se ne
  accorga. Accettabile per un backup di monitoraggio interno.
- **Provisioning del ricevente**: qualunque scrittura verso data stream Fleet richiede
  template e pipeline già presenti sul cluster di destinazione.
- **Segreti**: `nginx.conf` contiene il base64 dell'auth → escluso da Git, versionato
  `nginx.conf.example` con placeholder.
- **Lab vs produzione**: qui i due cluster condividono la stessa password; in produzione
  l'auth iniettata userebbe le credenziali del cluster 2. In produzione NGINX starebbe su una
  VM/pod dedicato come componente di infrastruttura condiviso.

## Confronto con le altre varianti

Stesso obiettivo (un agent, due cluster) realizzato in tre modi:

| Variante | Duplicazione | Complessità | Note |
|---|---|---|---|
| **NGINX (container)** | `mirror` nativo | media | serve `resolver` (DNS Docker) per i nomi dei servizi |
| **HAProxy (VM)** | script **Lua** | alta | 2.4 senza `core.httpclient` → libreria HTTP su `core.tcp`; gestione gzip e auth a mano |
| **NGINX (VM)** — *questo lab* | `mirror` nativo | bassa | IP host letterali → niente resolver; gzip automatico |

Conclusione: per il fan-out puro, **NGINX con `mirror` nativo** è la via più semplice;
HAProxy resta valido ma richiede più lavoro (Lua) per ottenere lo stesso risultato.

---
