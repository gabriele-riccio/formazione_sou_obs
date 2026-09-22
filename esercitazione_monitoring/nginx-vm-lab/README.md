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
- [Passo 7 — Puntare l'agent a NGINX](#passo-7--puntare-lagent-a-nginx)
- [Passo 8 — Verifica del fan-out](#passo-8--verifica-del-fan-out)
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

Avvia lo stack (non serve per far partire la VM, ma serve per i test):

```bash
cd elastic-lab
docker compose up -d
docker compose ps      # elasticsearch ed elasticsearch2 devono essere (healthy)
```

## Passo 2 — La configurazione NGINX

`nginx.conf`. Il base64 dell'auth si genera con `printf "elastic:password" | base64` e va
messo nel ramo `mirror` (senza, il cluster 2 risponde 401).

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
            proxy_set_header Authorization "Basic <BASE64_DI_elastic:PASSWORD>";
            proxy_http_version 1.1;
        }
    }
}
```

Punti chiave:

- **`mirror` + `mirror_request_body on`**: duplica la richiesta *e* il body verso `/mirror`.
- **`proxy_pass http://192.168.56.1:9200`** con IP letterale: niente `upstream`, niente
  `resolver`.
- **`Authorization` nel ramo mirror**: l'auth dell'agent non si propaga alla subrequest, va
  iniettata (altrimenti 401).
- **`client_max_body_size`** e i **timeout** ampi coprono bulk grandi e long-poll del Fleet
  Server.

## Passo 3 — Il Vagrantfile

Box Ubuntu, IP privato fisso, provisioning che installa nginx, copia la config e la valida
con `nginx -t` prima di riavviare.

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.hostname = "nginx-fanout-proxy"
  config.vm.network "private_network", ip: "192.168.56.51"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = "512"
    vb.cpus = 1
  end

  config.vm.provision "file", source: "nginx.conf", destination: "/tmp/nginx.conf"

  config.vm.provision "shell", inline: <<-SHELL
    set -e
    apt-get update
    apt-get install -y nginx

    cp /tmp/nginx.conf /etc/nginx/nginx.conf

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
> `nginx -t` valida la config prima del riavvio: se c'è un errore di sintassi il provisioning
> si ferma con un messaggio chiaro.

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

sleep 3
curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9200/test-nginx-vm/_count"   # cluster 1
curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9201/test-nginx-vm/_count"   # cluster 2
```

Entrambi devono dare `"count":1` → il mirror duplica correttamente.

![seconda_parte](haproxy/Screenshot%202026-09-01%20alle%2012.36.37.png)

## Passo 6 — Provisioning del cluster ricevente

Il cluster 2, non gestito da Fleet, ha bisogno dei **template** e delle **ingest pipeline**
delle integrazioni (index/component template + le `.fleet_*`, in particolare
`.fleet_final_pipeline-1`), altrimenti rifiuta i data stream `metrics-system.*`.

Verifica se ci sono:

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

> Gli ES del lab non hanno volume dati persistente: dopo un `compose down` il cluster 2
> riparte pulito e i template vanno ricopiati.
<immagine>

## Passo 7 — Puntare l'agent a NGINX

Verifica che il container dell'agent raggiunga la VM:

```bash
docker exec fleet-server curl -s -u "elastic:password" \
  "http://192.168.56.51:9210/" -o /dev/null -w "%{http_code}\n"   # atteso: 200
```
<immagine>
Poi in **Kibana → Fleet → Settings → Outputs**, modifica l'output `default` (tipo
Elasticsearch) e imposta come host `http://192.168.56.51:9210`. Salva.

> Un solo proxy alla volta deve ricevere l'output dell'agent: se c'era un'altra VM proxy
> (es. HAProxy), il traffico ora va a NGINX.
<immagine>
## Passo 8 — Verifica del fan-out

```bash
export ELASTIC_PASSWORD=password
curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9201/metrics-system.cpu-default/_count"
sleep 120
curl -s -u "elastic:${ELASTIC_PASSWORD}" "http://localhost:9201/metrics-system.cpu-default/_count"
```
<immagine>
Il secondo conteggio deve essere **più alto** del primo → le metriche `system` arrivano al
cluster 2 attraverso NGINX.

Prova anche dai log NGINX (sulla VM) che passino le bulk vere:

```bash
vagrant ssh -c "sudo tail -20 /var/log/nginx/access.log | grep _bulk | tail -5"
```

Atteso: righe `POST /_bulk...` con codice **200** e user-agent `Elastic-metricbeat` /
`Elastic-filebeat` / `Elastic-Fleet-Server`.

<immagine>
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
