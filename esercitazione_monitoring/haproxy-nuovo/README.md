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
- [Passo 8 — Puntare l'agent ad HAProxy](#passo-8--puntare-lagent-adH-haproxy)
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
quindi la duplicazione viene fatta **fuori dall'agent**, attraverso un reverse come HAProxy.

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
## Passo 2 — La VM HAProxy

`Vagrantfile`: Box Ubuntu, IP privato fisso, e provisioning che installa HAProxy, genera il
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
### Punti chiave:
- **config** - E' l'oggetto su cui imposto tutto (box,hostname, rete privata con IP fisso `192.168.56.50` con cui raggiungiamo HAProxy dall'host;
- **config.vm.provider** - VirtualBox come provider dove decido le risorse (memoria Ram e CPU);
- Copia dei file di config (**provisioning file**) - Copio i tre file (haproxy.cfg, mirror.lua e http.lua) dalla cartella host dentro la VM, nella cartella dei file temporanei `/tmp`:
  - **source** = il file sul mio PC;
  - **destination** = dove finiscono nella VM;
  - Li metto in `/tmp` come "area di transito" e  poi lo script shell li sposterà al posto giusto;
- Script di installazione (**provisioning shell**) - Avvio un blocco di comandi shell eseguiti come root dentro la VM al primo avvio:
  - `set -e`- fa fermare lo script al primo avvio;
  - `apt-get update/install -y haproxy openssl` - Aggiorno l'elenco dei pacchetti e installo HAProxy e openssl(per il certificato);
- Generazione del certificato **TLS** - Creo la cartella dei certificati e genero un certificato self-signed (autofirmato) con openssl:
  - `-x509` : Certificato completo;
  - `-newkey rsa:2048` : Genero una chiave RSA da 2048 bit;
  - `-nodes` : No password sulla chiave (così HAProxy parte senza chiederla);
  - `-keyout/-out` : Dove viene salvato il certificato `/tmp/haproxy.key` e `/tmp/haproxy.crt`;
  - `-days 365` : Validità un anno;
  - `-subj "/CN=..."` : Il campo Common Name viene riempito senza domande interattive;
  > Serve perché il frontend Fleet (porta 8220) parla in TLS, quindi HAProxy ha bisogno di un certificato da presentare.
  > Inoltre uso il cat per concatenare i due file in un unico, `/etc/haproxy/certs/haproxy.pem` perchè HAProxy vuole certificato e chiave in un unico file `.pem`.
  > Permessi con `chmod 600` così che solo il proprietario può leggerlo.
  Con `cp /tmp/nome_file /etc/haproxy/nome_file` sposto i tre file dalla cartella di quelli temporanei nella loro posizione definitiva.
- Validazione + avvio: Script che ho usato anche con la procedura nginx, con haproxy -c -f valida la config prima del riavvio e se c'è un errore di sintassi il provisioning si ferma con un
  messaggio chiaro.
  
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
### Punti chiave:
- Prima cosa carico la libreria HTTP personalizzata dato che HAProxy 2.4 non ha un client HTTP nativo utilizzabile;
- Poi attraverso il comando `core.register_action("")` registro un'azione chiamata `mirror_to_b` agganciata alla fase `http-req` (ovvero quando arriva una richiesta http). La funzione riceve
  `txn`(transazione corrente - richiesta in corso):
  - **method()** -> verbo HTTP (GET,POST..);
  - **path()** -> percorso (es /_bulk);
  - **query()** -> la query string dopo il ? (es. ?refresh=true).
  > `txn.sf` sono le **fetch methods**, funzioni che estraggono pezzi della richiesta.
- Ci sono poi altre funzioni dichiarate:
  - `local full_path = path`... - Ricostruisce il percorso completo, se c'è una query la riattacca con ?;
  > .. in Lua è la concatenazione di stringhe e serve perché copiando la richiesta devo replicare anche i parametri.
  - `local body = ten.sf:req_body()` - Prende il corpo della richiesta (i dati);
  - `local content_type = txn.sf:req_hdr("content-type") or "application/json"` - Legge l'header Content-Type. Il or "application/json" è un valore di default, se l'header manca (ritorna
    nil), usa application/json;
    > In Lua A or B restituisce B quando A è nil/false.
  - `local content_encoding = txn.sf:req_hdr("content-encoding")` - Legge il Content-Encoding: l'Elastic Agent invia le bulk compresse in gzip. Se copio il body gzip ma non dico al cluster 2
    che è gzip, lui prova a leggerlo come testo e va in errore (Illegal character CTRL-CHAR). Quindi va catturato e ripassato;
- `core.register_task(function()` - Avvio un **task asincrono**, il codice girerà a parte senza bloccare la risposta all'agent.
  - `local res, err... if method...` - Se la richiesta è una GET, fa una GET verso il cluster 2(192.168.56.1:9201) sullo stesso path.Aggiunge l'header Authorization con le credenziali in
    Basic Auth (perché il cluster 2 richiede autenticazione e la copia deve autenticarsi da sola).
  - `else local req_headers = {...} if content_encoding then ... end` - Altrimenti(POST,PUT..), prepara gli header: autorizzazione + content-type. E solo se c'era il Content-Encoding (gzip)
    lo aggiunge. Questo if evita di mettere un header vuoto quando il body non è compresso.
  - `res, err = http.post {...} end` - Fa la POST verso il cluster 2, mandando il body (data = body) e gli header appena costruiti. È qui che la copia dei dati viene effettivamente spedita.
  - `if res then.. end end` - Logga l'esito: se c'è una risposta stampa lo status code (200 = ok), altrimenti stampa l'errore.
    > tostring() converte il numero in stringa per concatenarlo.
  - `<BASE64_elastic:password>` si genera con `printf "elastic:password" | base64` come ho fatto con Nginx. Il valore da mettere negli header e dato che contiene una credenziale va escluso da
    Git (ho versionato un `mirror.lua.example`).
    
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
### Punti chiave:
- Creo una tabella vuota che sarà il modulo che alla fine verrà restituito al `mirror.lua`;
  > In Lua i moduli sono tabelle con dentro delle funzioni.
- Creo la prima `funzione local function parse_url(url)` che va a spezzare un URL nei suoi pezzi, con `url:match(...)` che usa le regex di Lua:
  - `^http://`: deve iniziare così;
  - `([^:/]+)`: cattura l'host (tutto ciò che non sia `:` o `/`);
  - `:?(%d*)`: un `:` opzionale seguito da cifre (porta);
  - `(/?.*)$`: il resto (il path);
  - Una serie di `if port/path` ( se manca la porta usare la 80, se manca il path usare /). `tonumber(port)` coperte la porta da stringa a numero;
- Altra funzione `do_request` che estrae host/porta/path, poi crea un socket TCP con `core.tcp()` e imposta un timeout di 5 secondi (se il cluster 2 non risponde, non resta appeso);
- `local ok, err = sock:connect(host, port)` Apre la connessione TCP, e se fallisce ritorna nil e un messaggio d'errore;
- Corpo di `body e req` - Costruisce a mano la richiesta HTTP come testo riga per riga:
  - prima riga: `POST /_bulk HTTP/1.1`;
  - `Host:` - obbligatorio in HTTP/1.1;
  - `Content-Length: #body` : #body è la lunghezza del body in Lua, HTTP vuole sapere quanti byte arrivano;
  - `Connection: close`: chiude la connessione dopo la risposta (semplifica la lettura);
- `if headers then...` Aggiunge gli header passati (**Authorization, Content-Type, Content-Encoding**):
  - Il `for ... in pairs()` scorre la tabella;
  - La riga `local val = type(v) == "table" and v[1] or v` gestisce il fatto che gli header arrivano come tabella `{"valore"}` se `v` è una tabella prende `v[1]`, altrimenti prende `v`
    direttamente;
  - Il `req = req .. "\r\n" .. body` finale aggiunge una riga vuota `(\r\n)` che in HTTP separa gli header dal body, rendendo req una richiesta HTTP completa;
- `sock:send(req) ... sock:close()`: Manda la richiesta, legge tutta la risposta ("*a" = "all", leggi tutto fino alla chiusura), infine chiude il socket;
- `local status = ... end`: Estrae lo **status code** dalla prima riga della risposta `(HTTP/1.1 200 ... → cattura 200)`. Il `response and ...` evita l'errore se response è `nil`. Ritorna
  una tabella con status e contenuto, che è ciò che `mirror.lua` legge come `res.status_code`;
- Infine definisco 2 funzioni pubbliche `http.get` e `http.post` come scorciatoie su `do_request`, e restituisco il modulo. Sono esattamente quelle che mirror.lua chiama con `http.get{...}` e
  `http.post{...}`.
  
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


