# Fan-out delle metriche su due cluster Elasticsearch con HAProxy

Reverse proxy **HAProxy** su VM dedicata che, tramite uno script **Lua**, duplica il
traffico di un **singolo Elastic Agent** verso **due cluster Elasticsearch indipendenti**.

Ambiente: **Elastic Stack 8.15.0** (in Docker) + **HAProxy 2.4** (su VM Vagrant/Ubuntu).

---

## Indice

- [Obiettivo](#obiettivo)
- [Architettura](#architettura)
- [Perché HAProxy e non un output nativo](#perché-haproxy-e-non-un-output-nativo)
- [Prerequisiti](#prerequisiti)
- [Struttura dei file](#struttura-dei-file)
- [Passo 1 — Stack Docker (due cluster)](#passo-1--stack-docker-due-cluster)
- [Passo 2 — La VM HAProxy](#passo-2--la-vm-haproxy)
- [Passo 3 — Lo script Lua di mirroring](#passo-3--lo-script-lua-di-mirroring)
- [Passo 4 — La libreria HTTP](#passo-4--la-libreria-http)
- [Passo 5 — La configurazione HAProxy](#passo-5--la-configurazione-haproxy)
- [Passo 6 — Provisioning della VM](#passo-6--provisioning-della-vm)
- [Passo 7 — Provisioning del cluster ricevente](#passo-7--provisioning-del-cluster-ricevente)
- [Passo 8 — Puntare l'agent a HAProxy](#passo-8--puntare-lagent-a-haproxy)
- [Passo 9 — Verifica del fan-out](#passo-9--verifica-del-fan-out)
- [Problemi incontrati e soluzioni](#problemi-incontrati-e-soluzioni)
- [Note e limitazioni](#note-e-limitazioni)
- [Differenze lab / produzione](#differenze-lab--produzione)

---

## Obiettivo

Realizzare un **server di monitoraggio interno** oltre a quello del cliente: le stesse
metriche di sistema, raccolte da **un solo Elastic Agent**, devono arrivare in **due
cluster Elasticsearch** indipendenti (principale + interno), così da averne una copia
sotto il proprio controllo.

La regola è "**un agent, due output**". Le vie native hanno dei vincoli (vedi sotto),
quindi la duplicazione viene fatta **fuori dall'agent**, da HAProxy.

## Architettura

```
                              ┌───────────────► elasticsearch  (:9200)  [primario, risposta all'agent]
Elastic Agent ──► HAProxy ────┤
   (metriche)   (VM :9210)    └ ─ ─ ─ (Lua) ─ ► elasticsearch2 (:9201)  [copia best-effort]
```

- HAProxy si presenta all'agent come se fosse un normale Elasticsearch.
- Il **frontend dati** (porta 9210) riceve le scritture dell'agent, le inoltra al cluster
  primario (backend) e — tramite lo script Lua — ne invia **una copia** al cluster 2.
- Il **frontend Fleet Server** (porta 8220, TLS) inoltra il canale di management verso il
  Fleet Server reale; anch'esso passa dal Lua.

## Perché HAProxy e non un output nativo

Prima di arrivare a HAProxy sono state escluse due strade native:

1. **Due output diretti sull'agent** — la funzione *integration-level outputs* (assegnare un
   output diverso a ciascuna integrazione) richiede **licenza Enterprise**. Su Basic/Platinum
   non è disponibile.
2. **Logstash come intermediario** — una policy che contiene il **Fleet Server** non può usare
   un output di tipo **Logstash** per le integrazioni (*"logstash output for agent integration
   is not supported for Fleet Server"*).

HAProxy, presentandosi come un **output Elasticsearch**, aggira entrambi i vincoli e permette
di restare con **un solo agent** su licenza Basic/Platinum.

## Prerequisiti

- Stack `elastic-lab` funzionante (Elasticsearch, Kibana, Fleet Server, un Elastic Agent).
- Un **secondo Elasticsearch** (`elasticsearch2`), esposto sull'host (porta 9201).
- **Vagrant + VirtualBox** per la VM HAProxy.
- Connettività dalla VM verso l'host Mac (`192.168.56.1`) sulle porte 9200 / 9201 / 8220.
- I due cluster condividono la stessa password `elastic` (semplificazione da lab).

## Struttura dei file

```
haproxy-nuovo/
├── Vagrantfile      # definisce e provisiona la VM HAProxy
├── haproxy.cfg      # configurazione HAProxy (2 frontend + backend)
├── mirror.lua       # azione Lua che duplica la richiesta verso il cluster 2
└── http.lua         # libreria HTTP minimale (client su core.tcp)
```

---

## Passo 1 — Stack Docker (due cluster)

Nel `docker-compose.yml` dello stack Elastic devono essere esposte sull'host le porte che la
VM dovrà raggiungere: `9200` (cluster 1), `9201` (cluster 2), `8220` (Fleet Server).
Il secondo cluster è un nodo `single-node` isolato dal primo:

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

## Passo 2 — La VM HAProxy

`Vagrantfile` — box Ubuntu, IP privato fisso, e provisioning che installa HAProxy, genera il
certificato per il frontend Fleet e copia i file di config:

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.hostname = "haproxy-fleet-proxy"
  config.vm.network "private_network", ip: "192.168.56.50"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = "1024"
    vb.cpus = 1
  end

  config.vm.provision "file", source: "haproxy.cfg", destination: "/tmp/haproxy.cfg"
  config.vm.provision "file", source: "mirror.lua",  destination: "/tmp/mirror.lua"
  config.vm.provision "file", source: "http.lua",    destination: "/tmp/http.lua"

  config.vm.provision "shell", inline: <<-SHELL
    set -e
    apt-get update
    apt-get install -y haproxy openssl

    mkdir -p /etc/haproxy/certs
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout /tmp/haproxy.key -out /tmp/haproxy.crt \
      -days 365 -subj "/CN=haproxy-fleet-proxy"
    cat /tmp/haproxy.crt /tmp/haproxy.key > /etc/haproxy/certs/haproxy.pem
    chmod 600 /etc/haproxy/certs/haproxy.pem

    cp /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg
    cp /tmp/mirror.lua  /etc/haproxy/mirror.lua
    cp /tmp/http.lua    /etc/haproxy/http.lua

    if haproxy -c -f /etc/haproxy/haproxy.cfg; then
      systemctl restart haproxy
      systemctl enable haproxy
      echo "=== HAProxy avviato correttamente ==="
    else
      echo "!!! ERRORE nella config HAProxy: NON riavviato !!!"
      exit 1
    fi
  SHELL
end
```

> `haproxy -c` valida la config **prima** del riavvio: se c'è un errore di sintassi il
> provisioning si ferma con un messaggio chiaro invece di lasciare HAProxy in stato incerto.

## Passo 3 — Lo script Lua di mirroring

`mirror.lua` registra un'azione (`mirror_to_b`) che scatta su ogni richiesta HTTP. Legge
metodo, path, query, body e header; poi, in un **task asincrono** (`core.register_task`),
spedisce una **copia** al cluster 2. L'asincronia rende il mirror *best-effort*: HAProxy non
attende la risposta del cluster 2 per rispondere all'agent.

```lua
local http = require('http')

core.register_action("mirror_to_b", {"http-req"}, function(txn)
    local method = txn.sf:method()
    local path = txn.sf:path()
    local query = txn.sf:query()
    local full_path = path
    if query and query ~= "" then
        full_path = path .. "?" .. query
    end
    local body = txn.sf:req_body()
    local content_type = txn.sf:req_hdr("content-type") or "application/json"
    local content_encoding = txn.sf:req_hdr("content-encoding")   -- IMPORTANTE (gzip)

    core.register_task(function()
        local res, err
        if method == "GET" then
            res, err = http.get{
                url = "http://192.168.56.1:9201" .. full_path,
                headers = { ["Authorization"] = {"Basic <BASE64_elastic:password>"} }
            }
        else
            local req_headers = {
                ["Authorization"] = {"Basic <BASE64_elastic:password>"},
                ["Content-Type"] = {content_type}
            }
            if content_encoding then
                req_headers["Content-Encoding"] = {content_encoding}
            end
            res, err = http.post{
                url = "http://192.168.56.1:9201" .. full_path,
                data = body,
                headers = req_headers
            }
        end
        if res then
            core.Info("mirror-to-b [" .. full_path .. "]: status " .. tostring(res.status_code))
        else
            core.Info("mirror-to-b [" .. full_path .. "]: errore - " .. tostring(err))
        end
    end)
end)
```

> `<BASE64_elastic:password>` si genera con `printf "elastic:password" | base64`.
> Contiene una credenziale: va escluso da Git (versionare un `mirror.lua.example`).

## Passo 4 — La libreria HTTP

HAProxy 2.4 **non ha** `core.httpclient` (introdotto dalla 2.5), e `require('http')` di
`lua-http` (apt) espone un'API diversa. Si usa quindi una **libreria minimale** costruita sul
socket nativo `core.tcp`, che monta a mano una richiesta HTTP e legge la risposta.

```lua
local http = {}

local function parse_url(url)
    local host, port, path = url:match("^http://([^:/]+):?(%d*)(/?.*)$")
    if port == "" then port = "80" end
    if path == "" then path = "/" end
    return host, tonumber(port), path
end

local function do_request(method, url, body, headers)
    local host, port, path = parse_url(url)
    local sock = core.tcp()
    sock:settimeout(5)
    local ok, err = sock:connect(host, port)
    if not ok then return nil, "connect failed: " .. tostring(err) end

    body = body or ""
    local req = method .. " " .. path .. " HTTP/1.1\r\n"
    req = req .. "Host: " .. host .. "\r\n"
    req = req .. "Content-Length: " .. #body .. "\r\n"
    req = req .. "Connection: close\r\n"
    if headers then
        for k, v in pairs(headers) do
            local val = type(v) == "table" and v[1] or v
            req = req .. k .. ": " .. val .. "\r\n"
        end
    end
    req = req .. "\r\n" .. body

    sock:send(req)
    local response = sock:receive("*a")
    sock:close()

    local status = response and tonumber(response:match("^HTTP/%d%.%d (%d+)"))
    return { status_code = status, content = response }
end

function http.get(t)  return do_request("GET",  t.url, nil,    t.headers) end
function http.post(t) return do_request("POST", t.url, t.data, t.headers) end

return http
```

## Passo 5 — La configurazione HAProxy

`haproxy.cfg` con i due frontend. Punti chiave: `lua-load` dello script, `tune.bufsize`
alzato (le bulk delle metriche superano il buffer di default da 16 KB), `wait-for-body` per
avere il body completo prima del Lua, e il richiamo `http-request lua.mirror_to_b`.

```
global
        log /dev/log    local0
        log /dev/log    local1 notice
        chroot /var/lib/haproxy
        stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
        stats timeout 30s
        user haproxy
        group haproxy
        daemon
        tune.bufsize 1000000
        lua-prepend-path /etc/haproxy/?.lua
        lua-load /etc/haproxy/mirror.lua
        ca-base /etc/ssl/certs
        crt-base /etc/ssl/private

defaults
        log     global
        mode    http
        option  httplog
        option  dontlognull
        timeout connect 5000
        timeout client  310000
        timeout server  310000

# ===== Canale FLEET SERVER (management, TLS) =====
frontend fleet_proxy_in
    bind *:8220 ssl crt /etc/haproxy/certs/haproxy.pem
    option httplog
    option http-buffer-request
    http-request wait-for-body time 1s
    http-request lua.mirror_to_b
    default_backend fleet_server_real

backend fleet_server_real
    mode http
    server fleet1 192.168.56.1:8220 ssl verify none

# ===== Canale DATI / METRICHE (Elasticsearch) =====
frontend es_data_in
    bind *:9210
    mode http
    option httplog
    option http-buffer-request
    http-request wait-for-body time 1s
    http-request lua.mirror_to_b
    default_backend elasticsearch_a_real

backend elasticsearch_a_real
    mode http
    server es1 192.168.56.1:9200
```

> Il file deve terminare con un **newline finale**, altrimenti HAProxy dà
> `Missing LF on last line`.

## Passo 6 — Provisioning della VM

```bash
cd haproxy-nuovo
vagrant up            # prima volta
# oppure, se la VM esiste già e hai cambiato i file:
vagrant provision
```

Esito atteso: `Configuration file is valid` + `=== HAProxy avviato correttamente ===`.

## Passo 7 — Provisioning del cluster ricevente

Il cluster 2, non gestito da Fleet, **non ha** i template e le ingest pipeline delle
integrazioni: senza di essi rifiuta i data stream `metrics-system.*`. Vanno copiati dal
cluster 1: **component template**, **index template**, **ingest pipeline** — incluse le
`.fleet_*` (in particolare **`.fleet_final_pipeline-1`**, richiesta da ogni data stream Fleet).

(Nel lab la copia è stata fatta con due script Python via API — `copia_template.py` e
`copia_fleet_pipeline.py`.)

## Passo 8 — Puntare l'agent a HAProxy

Prima verifica che il container dell'agent raggiunga la VM:

```bash
docker exec fleet-server curl -s -u "elastic:password" \
  "http://192.168.56.50:9210/" -o /dev/null -w "%{http_code}\n"   # atteso: 200
```

Poi in **Kibana → Fleet → Settings → Outputs**, modifica l'output `default` (tipo
Elasticsearch) e imposta come host `http://192.168.56.50:9210`. Salva.

> Se il Fleet Server resta bloccato su un vecchio output non più raggiungibile, ricrearlo:
> `docker compose up -d --force-recreate fleet-server`.

## Passo 9 — Verifica del fan-out

```bash
# Il cluster 2 deve mostrare i metrics-system.* con docs.count in crescita
curl -s -u "elastic:password" \
  "http://localhost:9201/_cat/indices/metrics-system*?v&h=index,docs.count"

# Nei log HAProxy le bulk delle metriche devono dare status 200
vagrant ssh -c "sudo journalctl -u haproxy --since '1 minute ago' --no-pager | grep filter_path | tail"
```

Fan-out riuscito = gli stessi data stream `metrics-system.*` crescono su **entrambi** i
cluster, e il log del mirror riporta `status 200`.

---

## Problemi incontrati e soluzioni

| Problema | Sintomo | Soluzione |
|---|---|---|
| Modulo Lua HTTP | `module 'http' not found` | `lua-http` di apt ha un'API diversa; scritta una libreria minimale (`http.lua`) su `core.tcp` |
| API non disponibile | `attempt to call a nil value (field 'httpclient')` | `core.httpclient` non esiste in HAProxy 2.4 (dalla 2.5); usato `core.tcp` |
| Newline finale | `Missing LF on last line` | aggiungere una riga vuota in fondo a `haproxy.cfg` |
| Body troncato | bulk grandi non passavano | `tune.bufsize 1000000` nel blocco `global` |
| Stallo Fleet Server | log ripetuti `lookup <host> no such host` | l'output puntava a un proxy non più esistente; `--force-recreate` del Fleet Server |
| **Bulk rifiutate (gzip)** | mirror `status 400`, *Illegal character (CTRL-CHAR, code 31)* | le metriche viaggiano **gzip**: inoltrare l'header **`Content-Encoding`** nella copia |
| Autenticazione | mirror `status 401` | iniettare esplicitamente `Authorization: Basic <base64>` verso il cluster 2 |
| Template mancanti | *specifies a missing component template* / data stream non creati | copiare component/index template + ingest pipeline (incluse `.fleet_*`) sul cluster 2 |

Il carattere `code 31` (`\x1F`) nell'errore 400 è la firma del **gzip**: il cluster 2 riceveva
byte compressi senza sapere che lo fossero, e li leggeva come JSON non valido. Inoltrando
`Content-Encoding: gzip` il problema si risolve.

## Note e limitazioni

- **Best-effort**: il ramo di copia è asincrono e non garantisce la consegna. Se il cluster 2
  è lento o giù, alcune copie si perdono senza che l'agent se ne accorga. Accettabile per un
  backup di monitoraggio interno.
- **Provisioning del ricevente**: qualunque scrittura verso data stream Fleet richiede template
  e pipeline già presenti sul cluster di destinazione.
- **Segreti**: `mirror.lua` contiene il base64 dell'auth → escluderlo da Git, versionare un
  `mirror.lua.example` con placeholder. Il certificato `haproxy.pem` è generato nella VM.
- **HAProxy non nasce per duplicare**: il load-balancing manda a *uno* dei backend; la
  duplicazione qui è ottenuta via Lua. Per un fan-out "industriale" di scritture esistono
  strumenti nati per questo (Logstash, Vector).

## Differenze lab / produzione

- Nel lab i due cluster condividono la **stessa password**; in produzione l'auth iniettata nel
  mirror userebbe le credenziali del cluster 2.
- In produzione HAProxy starebbe su una **VM/pod dedicato**, non containerizzato al volo, come
  componente di infrastruttura condiviso.
- La licenza cambia le opzioni: con **Enterprise** il fan-out "un agent, due output" è nativo
  in Fleet e non servirebbe alcun proxy; su **Basic/Platinum** servono NGINX/HAProxy oppure
  Logstash (con policy separata dal Fleet Server).

---


