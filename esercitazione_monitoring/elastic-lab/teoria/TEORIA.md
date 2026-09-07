# Elastic Stack - Teoria di Elastic per raccogliere, conservare, analizzare e visualizzare le **metriche** dei sistemi (host, container, Kubernetes).

**Contesto:** Sourcesense DevOps Academy — Track Observability.

---

## Indice

1. [Introduzione e posizionamento](#cap-1--introduzione-e-posizionamento)
2. [Anatomia dello stack (i "collaboratori")](#cap-2--anatomia-dello-stack-i-collaboratori)
3. [Il modello push in profondità](#cap-3--il-modello-push-in-profondità)
4. [Che metriche espone e raccoglie](#cap-4--che-metriche-espone-e-raccoglie)
5. [Il modello dati delle metriche](#cap-5--il-modello-dati-delle-metriche)
6. [Configurazione e ciclo di vita](#cap-6--configurazione-e-ciclo-di-vita)
7. [Query e visualizzazione in Kibana](#cap-7--query-e-visualizzazione-in-kibana)
8. [Alerting](#cap-8--alerting)
9. [Elastic vs Prometheus](#cap-9--elastic-vs-prometheus)
10. [Elastic e OpenTelemetry](#cap-10--elastic-e-opentelemetry)

---

## Cap. 1 — Introduzione e posizionamento

**Da dove nasce**:
Alla base c'è **Apache Lucene**, libreria Java per la ricerca full-text che implementa l'**indice invertito**.
Lucene però è solo una libreria(non è un server e non ha API di rete), per questo **Elasticsearch** la trasforma in un datastore distribuito con API REST, capacità di girare in un cluster multi-nodo, replica, scalabilità orizzontale e linguaggio di query via JSON.

Attorno ad esso ci sono due strumenti **Logstash** (pipeline di ingestione, che raccoglie i dati da sorgenti, li trasforma e li scrive dentro Elasticsearch) e **Kibana** (interfaccia web per cercare, visualizzare e costruire dashboard sui dati).
Le iniziali E-L-K formano lo **stack ELK**, oggi chiamato più inclusivamente **Elastic Stack**.

## Perché si afferma sui log??
Un log è un evento testuale semi-strutturato: *testo da cercare*.
Il motivo per cui Elatic è lo standard per i logging sta tutto per come è fatto Elasticsearch, cioè nell'indice invertito ereditato da Lucene.

Esso costruisce in anticipo un gigantesco indice analitico (come quello a fine libro), in cui per ogni parola è già scritto l'elenco esatto dei documenti che la contengono. Così, quando si cerca una parola , Elasticsearch non scorre nulla -  va direttamente alla voce e trova già pronta la lista.
Grazie ad esso possiamo andare "dalla parola ai documenti" e non viceversava, rendendo la ricerca quasi istantanea anche su volumi enormi esattamente ciò che serve per l'analisi dei log.

## Observability unificata — i tre segnali

Esso però non si ferma soltanto ai log, ha un motore capace di indicizzare ed interrogare enormi quantità di eventi con timestamp per cui sarebbe stato fallimentare fermarsi ai log dato che possiamo fare la stessa cosa anche con le misurazioni di CPU oppure con le richieste HTTP tracciate da microservizi essendo tutti *eventi nel tempo* come i log.
Attraverso Elastic possiamo monitorare tutti e 3 i segnali del monitoring e dell'observability:
- **Log** — eventi discreti ("cosa è successo, in questo caso specifico"); **COSA**;
- **Metriche** — misurazioni numeriche campionate ("come si comporta nel tempo, in aggregato"); **QUANTO**;
- **Tracce** — il percorso di una richiesta tra i servizi ("dove si è perso tempo"). **DOVE**.

La **Observability unificata** è l'idea che questi tre segnali vivano nello stesso posto e siano correlabili tra loro.
Il valore pratico ha un nome preciso: **correlazione**.
> Immaginiamo un'indagine su un problema in produzione - Vediamo in dashboard un picco anomalo in una metrica — la latenza di un servizio schizza in alto alle 14:32.
> In un mondo frammentato dovresti cambiare applicazione, ri-cercare l'orario, ri-filtrare l'host, perdendo tempo e contesto a ogni salto.
> In un mondo unificato invece, dalla metrica salti direttamente ai log di quel preciso host nella stessa UI in quel preciso minuto, e da lì alla traccia della richiesta            > problematica senza dovercambiare strumento.
Il collante tecnico che rende possibile questa correlazione è l'ECS (spiego dopo).

## Posizionamento vs Prometheus.
Prometheus è **specializzato** (solo metriche, modello pull, PromQL, molto efficiente) sa fare una cosa e la fa in un modo estremamente efficiente.
Elastic rappresenta una filosofia **generalista e unificante** (tutti i segnali in un posto, retention lunga, ricerca full-text, ML).
Compromesso di fondo: **specializzazione vs unificazione**. Non sono alternativi: spesso **coesistono** (cap. 9).

---

## Cap. 2 — Anatomia dello stack (i "collaboratori")
L'Elastic Stack non è un prodotto singolo ma un insieme di componenti che si passano i dati lungo una **catena**:

I dati vanno in una direzione; la *configurazione* viaggia in senso opposto (da Fleet verso gli agent).
La metrica nasce su una sorgente (host, container, database, servizio cloud); un agent la raccoglie e, dopo averla arricchita, la spedisce;arrivano a Elasticsearch, che li memorizza e indicizza; infine Kibana li legge per visualizzarli, interrogarli e generare alert. 
I dati vanno in una direzione; la *configurazione* viaggia in senso opposto (da Fleet verso gli agent).

- **Elasticsearch**: E' il cuore dello stack, esso memorizza (documenti JSON in data stream), indicizza documenti in ingresso ed analizza rispondendo a query e soprattutto
  aggregazioni(medie, percentili, raggruppamenti). E' distribuito su un cluster anche di più nodi che spartiscono dati in shard e li replicano.
- **Kibana**: E' il front-end unico dello stack, è un ombrello che raccoglie visualizzazione, app Observability, Fleet(gestione Elastic Agent), Machine Learning, Alerting(regole e
  connettori e gestione dello stack.
- **Beats**: Agent leggeri single-purpose come **Metricbeat** (metriche), **Filebeat** (log), **Packetbeat**, **Heartbeat** (un Beat per ogni tipo di dato).
  Metricbeat ad esempio è organizzato in due livelli:
  - **moduli**: Tecnologia o sorgente come system, docker, k8s etc.
  - **metricset**: Un gruppo di metriche correlate che il modulo recupera insieme, in una sola richiesta.
> La gerarchia come `modulo → metricset` ritorna anche in Elastic Agent (con etichetta diversa,`integration → data stream`).
- **Elastic Agent**: Nasce per risolvere il limite dei Beats ovvero `installare più agent separati su ogni host`, agente unico che raccoglie log+metriche+tracce via **integration**;
  (pacchetti preconfezionati che portano configurazione, dashboard pronte, mapping dei campi e regole). E' gestito da Fleet.
- **Fleet**: E' l'app dentro Kibana per gestire la flotta di agent tramite **agent policy**, ovvero una configurazione che si decide di assegnare a un gruppo di agent(quali
  integration attivare e con quali parametri).
  In poche parole - Modifico la policy in un solo posto e Fleet la distribuisce automaticamente, gestendo anche enrollment (aggancio via token), health/status e upgrade coordinati.
- **Logstash**: E' la pipeline di ingestione ETL a tre stadi:
  - **input** (da dove arrivano i dati),
  - **filter** (le trasformazioni),
  - **output** (dove vanno).
  Serve per trasformazioni complesse o come livello di buffering e per le sole metriche spesso non serve: gli agent le scrivono già arricchite direttamente in Elasticsearch.
  Regola pratica: trasformazioni leggere → ingest pipeline; ETL complesso o buffering → Logstash.
- **Elastic APM**: Raccoglie tracce distribuite e metriche applicative dall'interno delle applicazioni(quanto dura una transazione, dove si spende tempo, quali errori).
  Degli APM agent inviano i dati a un APM Server, che li scrive in Elasticsearch, rappresenta il pezzo che porta il terzo segnale (le tracce) nella observability unificata.

> **Beats vs Elastic Agent:** i Beats vengono prima (un binario per segnale, config per host, no gestione centralizzata); l'**Elastic Agent + Fleet** unifica e centralizza.
> **Oggi consigliato: Elastic Agent + integration+ Fleet.**
---

## Cap. 3 — Il modello push in profondità

## Push vs pull — Chi apre la connessione? Agente o Server
Vediamo i due modelli:
- **Push (Elastic)**: l'**agent** gira sulla sorgente, raccoglie i dati e li *spinge*  verso Elasticsearch.
- **Pull (Prometheus)**: il **server**(prometheus) fa *scrape* dei dati interrogando degli endpoint `/metrics` ad intervalli regolari.

## Il ciclo della raccolta
Il ciclo dell'agent Elastic ha tre fasi (ad ogni `period`):
- Raccolta `collect`: l'agent interroga la sorgente locale (legge `/proc` , chiama l'API Docker, interroga il kubelet) e ottiene i valori grezzi.
- Arricchimento `enrich` (aggiunge campi ECS e metadati che conosce **alla fonte**(host, cloud, pod).
- Invio `send`: Impacchetta i documenti e li spinge (**push**) via API `_bulk`.

## Parametro perid
Il period controlla ogni quanto l'agent esegue il ciclo per un dato metricset.
Valori tipici: 10s per metriche di sistema veloci; molto più alti (un minuto o più) per API cloud lente e costose.
È un compromesso: 
- più basso = meno risoluzione ma più dati e carico.
- più alto = meno dati e carico, ma più risoluzione.
> Corrisponde concettualmente allo scrape_interval di Prometheus, cambia solo chi lo esegue.

# L'API `_bulk` 
L'agent non invia un documento per volta ma usa l'API _bulk di Elasticsearch, che permette di inviare molti documenti in una sola richiesta HTTP. 
Questo rappresenta il pattern standard di Elasticsearch per scritture ad alto volume.

# Gestire una flotta di Agent con Fleet
Il push distribuisce il lavoro di raccolta sugli agent, e mi ritroverei quindi con una flotta di agent da gestire.
È il problema che Fleet risolve, ricentralizzando il controllo ottenendo il meglio dei due mondi:
- La raccolta arricchita alla fonte del push, senza il caos di configurare mille macchine a mano
  ontrasto con Prometheus: lì il controllo è già centralizzato, ma il problema si sposta sulla service discovery.


## Ponte con Prometheus (modulo Prometheus):
**Contrasto con Prometheus**: Lì il controllo è già centralizzato, ma il problema si sposta sulla service discovery.
Inoltre Elastic si integra con Prometheus tramite il modulo/integration Prometheus, con tre modalità:
- `collector`: Elastic fa lo scrape di un endpoint `/metrics` Prometheus e poi pusha su Elasticsearch, sbloccando tutti gli exporter Prometheus (per questo è il più usato);
- `query`: Elastic esegue query PromQL contro un Prometheus esistente salvandone i risultati;
- `remote_write`: Elastic espone un ricevitore remote_write ed è Prometheus a spinge i suoi campioni dentro Elastic.

---

## Cap. 4 — Che metriche espone e raccoglie Elastic??

Abbiamo visto le definizioni di **Modulo** = tecnologia o sorgente da cui raccogliere e **metricset** = gruppo di metriche correlate che il modulo prende insieme in una chiamata.
In Elastic Agent: **integration → data stream** rappresentano lo stesso concetto, il risultato è sempre lo stesso tipo di oggetto:
"Documenti JSON con @timestamp , campi numerici e dimensioni/label, normalizzati secondo ECS".
Ci sono vari tipi di moduli, che poi vanno a raccogliere tipi di metriche diverse:
- **`system`**: (Raccoglie metriche dell'host): `cpu`, `core`, `load`, `memory`, `network`, `process`, `process_summary`, `diskio`, `filesystem`, `fsstat`, `socket`, `uptime`.
- **`docker`**: (Raccoglie metriche dai container, interrogando l'API di docker): `container`, `cpu`, `memory`, `network`, `diskio`, `healthcheck`, `info`, `image`, `event`.
  Idea chiave: le stesse categorie dell'host sono declinate per container, così vediamo quanto consuma ciascun container.
- **`kubernetes`**: E' il più ricco, infatti le metriche arrivano da fonti diverse:
  - `kubelet` (utilizzo reale delle risorse: CPU, memoria);
  - `kube-state-metrics (KSM)` (lo stato degli oggetti Kubernetes: repliche desiderate vs disponibili, fase di un pod);
  - l'`API server` e altri componenti del control plane.
  Inoltre le metriche si dividono in due tipologie di famiglie:
  - metricset di **utilizzo** (dal kubelet): `node`, `pod`, `container`, `volume`, `apiserver`, `scheduler`…
  - metricset di **stato** (da kube-state-metrics): `state_pod`, `state_deployment`, `state_node`, `state_replicaset`, `state_daemonset`, `state_job`.
    > *KSM va installato nel cluster.*
  Distinzione chiave: `pod` ti dice **quanto consuma** un pod (kubectkl); `state_pod` ti dice **in che stato è** (Running, Pending, CrashLoopBackOff; KSM).
- **Database:** `mysql`, `postgresql`, `redis`, `mongodb`, `mssql`, `oracle` (metricset `status`, `performance`, `replication`…).
- **Cloud (via API del provider):** AWS (CloudWatch: EC2, S3, RDS, Lambda…), GCP (Cloud Monitoring), Azure (Azure Monitor).

**Dimensioni/label** (`host.name`, `container.id`, `kubernetes.pod.name`…) identificano la serie e permettono filtro e raggruppamento. In TSDS formano il `_tsid`.

---

## Cap. 5 — Il modello dati delle metriche

**Una metrica = un documento JSON** con `@timestamp` (il *quando*), i valori (il *quanto*, i campi numerici, es. system.cpu.total.pct = 0.73), le dimensioni (il *di chi* es. host.name = web.01). È il punto storicamente debole (occupa più di un TSDB puro); il resto del capitolo è la risposta.
> Il fatto che una metrica sia "solo" un documento JSON permette a Elasticsearch di trattare metriche, log e tracce con lo stesso motore ma è anche il punto storicamente debole:
> un documento JSON generico occupa più spazio di come lo stesso dato verrebbe salvato in un TSDB specializzato.
> Vediamo come Elastic risponde a questa debolezza.

## ECS (Elastic Common Schema) e la convergenza con OTEL
Esso è un dizionario comune di nomi e tipi di campo: (es `host.name`, `cloud.provider`, ID del container `container.id`) che abilita la **correlazione** tra segnali(se log, metrica e traccia usano tutti host.name , possono essere correlati).
E' stato donato a OpenTelemetry ed Elastic sta lavorando alla convergenza tra **ECS e OTel Semantic Conventions**.

## Data stream, rollover, naming data stream, TSDS, efficenza di Storage
Storicamente Elasticsearch memorizza in indici, ma essendo i dati `time-series` append-only essi crescono all'infinito e per questo motivo un unico indice diventerebbe ingestibile.
Soluzione:
- **Data stream**: Un' astrazione su una sequenza di indici sottostanti --> Leggi e scrivi con un solo nome, mentre dietro le quinte Elasticsearch crea nuovi indici col meccanismo
  di  **rollover** automatico (per età/dimensione/doc).

La convenzione del naming dei data stream è formata da 3 ha parti **`metrics-{dataset}-{namespace}`** → es. Un data stream tipico è `metrics-system.cpu-default`, inoltre la convenzione è auto-descrittiva e permette routing e permessi per pattern di nome e il namespace dà flessibilità (prod/staging) senza duplicare configutazioni.

- **TSDS (Time Series Data Streams)** — E' un data stream speciale, utilizzato per serie temporali e viene attivato con `index.mode: time_series`.
Cosa Cambia:
 - **_tsid** — I campi dimensione ( time_series_dimension: true ) vengono combinati in un identificatore che rappresenta univocamente una serie. Elasticsearch sa che tutti i
   documenti con lo stesso _tsid sono la stessa serie e differiscono solo per @timestamp.
- **Routing e ordinamento per serie+tempo** — I valori successivi della stessa serie finiscono vicini sul disco, infatti dati simili e contigui si comprimono molto meglio.
- **Campi metrica tipizzati** (`time_series_metric`)
  - **Campi dimensione** (il di chi/di cosa) che identificano la serie, formano il **_tsid** , sono ciò su cui si filtra e si raggruppa.
  - **Campi metrica** (il quanto):
    - **`gauge`** — sale e scende (CPU, memoria) → media/max;
    - **`counter`** — solo cresce,  e si può azzerare(byte totali).

- **Efficienza storage:**
  - `Downsampling`- Con il tempo la risoluzione fine dei dati vecchi serve sempre meno, ad esempio mi interessa la CPU secondo per secondo di oggi, ma di sei mesi fa basta la media
    oraria. Il downsampling aggrega i dati vecchi a granularità più grossa (es. da 10s a 1h, con min/max/media/somma/conteggio), riducendo molto lo spazio mantenendo l'informazione
    sui trend.
  - `Synthetic _source` - Normalmente Elasticsearch conserva una copia del JSON originale nel `campo _source` (comodo ma costoso). Il synthetic _source non memorizza quella copia
    grezza, ma la ricostruisce al volo dai dati indicizzati. Ulteriore risparmio, al piccolo prezzo di un costo computazionale nella ricostruzione.
---

## Cap. 6 — Configurazione e ciclo di vita
# Flusso:
In Fleet/Integrations aggiungo un'integration a una policy, configuro le opzioni(data stream/metricset/`period`/filtri/credenziali) e Fleet la propaga a tutti gli agent iscritti. Il modello è **dichiarativo e centralizzato**(Dichiaro cosa voglio in un posto e Fleet lo fa combaciare con la realtà) e inoltre ne discende un'organizzazione per policy diverse per ruoli diversi(web server, database server, nodi Kubernetes).

# Output:
Definisce dove gli agent spediscono i dati (Elasticsearch (normale) o Logstash se serve una trasformazione).
Sicurezza con **API key** per l'autenticazione gestita da Fleet nell'enrollment + **TLS** per la cifratura.

## ILM (Index Lifecycle Management)
Gestisce il ciclo vita degli indici in fasi:
- **hot**: dati recenti e attivi, hard‐ ware veloce, qui avviene il rollover;
- **warm**: non più scritti ma ancora interrogati force-merge, shrink;
- **cold**: vecchi, interrogati di rado, searchable snapshot;
- **frozen**: archivio, massimo risparmio;
- **delete** Cancellazione.
Per cluster **self-managed** a tier(fasi)-->Retention e controllo costi.

- **DSL (Data Stream Lifecycle):** Meccanismo più semplice e recente che copre l'essenziale (retention + rollover + downsampling) ed è nativo su **Serverless**.
- **ILM vs DSL:** complesso con tier → ILM; semplice/Serverless → DSL.
- **Gestione agent nel tempo:** Fleet copre tre attività ricorrenti:
  - `enrollment` (nuovi agent si agganciano tramite enrollment token, che li asso‐ cia a una policy);
  -  `upgrade`(aggiornamenti coordinati rolling sull'intera flotta);
  -  `health/status` (monitoraggio dello stato di ogni agent).
---

## Cap. 7 — Query e visualizzazione in Kibana

- **Lens** — editor **drag-and-drop** raccomandato, sopra le **data view** (`metrics-*`). Trascini metriche e dimensioni.
- **TSVB** — storico per serie temporali, **deprecato** in favore di Lens. ⚠️ *Verificare se rimosso in 9.x.*
- **ES|QL** — linguaggio **a pipe** (`|`), analogo a SQL/PromQL. Esempio:
  ```
  FROM metrics-system.cpu-*
  | WHERE @timestamp > NOW() - 1 hour
  | STATS avg_cpu = AVG(system.cpu.total.pct) BY host.name
  | SORT avg_cpu DESC
  ```
  ⚠️ *Versione GA (~8.14) e comandi time-series da verificare.*
- **App Observability:** **Inventory** (topologia di host/container/pod), **Hosts** (analisi host-centrica), Metrics Explorer (legacy).
- **Dashboard + drill-down:** pannelli Lens/ES|QL in una vista persistente; dal pannello salti a Inventory/Hosts o ai log (root-cause analysis).

---

## Cap. 8 — Alerting

Motore a **due tempi**: una **regola** valuta una condizione a intervalli; quando scatta, esegue **azioni** via **connettori**.

- **Custom threshold** — soglia su metrica (metrica + aggregazione + soglia + durata). Sostituisce la legacy *Metric threshold*.
- **Inventory** — soglie entità-centriche su host/pod/container (anche quelli futuri).
- **Anomaly detection (ML)** — impara il comportamento normale (inclusi i cicli) e alerta sullo score di anomalia. Meno rumore, cattura anomalie contestuali.
- **SLO + burn-rate** — SLI (misura) → SLO (obiettivo) → error budget (margine) → burn-rate (velocità di consumo). Alerta sull'**impatto verso il servizio**, non sui sintomi. Ottica SRE.
- **Connettori:** Email, Webhook (jolly), Slack, Teams, PagerDuty, Opsgenie, ServiceNow, Jira, SNS…
- **Chiude il "down" del push:** regola sui **dati mancanti**, tra le prime da impostare, + health di Fleet.

---

## Cap. 9 — Elastic vs Prometheus

| | **Elastic** | **Prometheus** |
|---|---|---|
| **Raccolta** | push (agent → cluster) | pull (server fa scrape) |
| **Storage** | cluster distribuito a tier, retention lunga | TSDB locale; scala con Thanos/Cortex/Mimir |
| **Modello dati** | documenti JSON + ECS + TSDS (ricco, correlabile) | campione `metrica{label}` (minimale, efficiente) |
| **Query** | ES\|QL / Lens (ampio, in crescita) | PromQL (maturo, specializzato) |
| **Forza** | unificazione multi-segnale, retention, ricerca, ML | metriche cloud-native, PromQL, leggerezza |

**Coesistenza (non è un vero "vs"):** scrape degli exporter (`collector`), `remote_write` da Prometheus, `query` PromQL, backend OTel. Pattern tipico: **Prometheus per l'alerting real-time su Kubernetes**, **Elastic come store a lungo termine** per correlazione e analisi multi-segnale.

---

## Cap. 10 — Elastic e OpenTelemetry

- **OpenTelemetry (OTel)** — standard aperto CNCF per metriche/log/tracce, vendor-neutral. Trasporto: **OTLP** (gRPC/HTTP).
- **Ingestione OTLP nativa** — l'APM Server / integration APM riceve OTLP: puoi puntare qualsiasi Collector/SDK OTel verso Elastic.
- **EDOT (Elastic Distribution of OpenTelemetry)** — distribuzione Elastic dei componenti OTel: **EDOT Collector** + **EDOT SDK** (Java, Node.js, Python, .NET, PHP, mobile). Percorso "pronto e supportato". ⚠️ *Stato GA da verificare.*
- **Managed OTLP endpoint** (Serverless) — ingresso OTLP gestito, senza APM Server/collector propri.
- **Elastic come backend OTel** — adotti OTel per la raccolta e usi Elasticsearch/Kibana per storage, correlazione, visualizzazione e alerting. Collante: convergenza **ECS ↔ Semantic Conventions**.
- **Collegamento con Flanders** — *Mastering OpenTelemetry and Observability* (Steve Flanders, Wiley 2024) copre OTel dal lato **standard** (produzione e trasporto); questo capitolo copre il lato **backend** (dove i dati atterrano e cosa ci fai).

---

