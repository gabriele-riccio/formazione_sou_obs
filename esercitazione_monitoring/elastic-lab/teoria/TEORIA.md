# Elastic per le metriche dei tuoi sistemi — Teoria

Trattazione teorica in dieci capitoli sull'uso dell'**Elastic Stack** per raccogliere, conservare, analizzare e visualizzare le **metriche** dei propri sistemi (host, container, Kubernetes).

> **Contesto:** Sourcesense DevOps Academy — Track Observability
> **Parte pratica:** vedi [`README.md`](./README.md) per il laboratorio passo-passo (stack completo con Fleet su Docker).

> **Nota sulle fonti.** Alcuni dettagli tecnici (versioni GA, nomi esatti come EDOT, stato di deprecazione di TSVB, percentuali di risparmio storage del TSDS) sono ricostruiti da conoscenza affidabile, non da lettura in tempo reale della documentazione ufficiale. I concetti architetturali sono solidi; per i dettagli fini conviene riscontrare su [elastic.co/docs](https://www.elastic.co/docs) la versione in uso. I punti da verificare sono segnalati con ⚠️.

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

**Da dove nasce.** Alla base c'è **Apache Lucene**, libreria Java per la ricerca full-text che implementa l'**indice invertito**. **Elasticsearch** la trasforma in un datastore distribuito con API REST, cluster multi-nodo, replica e scalabilità orizzontale. Attorno: **Logstash** (pipeline di ingestione) e **Kibana** (interfaccia). Le iniziali E-L-K formano lo **stack ELK**, oggi chiamato più inclusivamente **Elastic Stack**.

**Perché si afferma sui log.** Un log è un evento testuale semi-strutturato: *testo da cercare*. L'indice invertito va "dalla parola ai documenti", rendendo la ricerca quasi istantanea anche su volumi enormi — esattamente ciò che serve per l'analisi dei log.

**Observability unificata — i tre segnali:**
- **Log** — eventi discreti ("cosa è successo, in questo caso specifico");
- **Metriche** — misurazioni numeriche campionate ("come si comporta nel tempo, in aggregato");
- **Tracce** — il percorso di una richiesta tra i servizi ("dove si è perso tempo").

Il valore è la **correlazione**: da un picco di metrica salti ai log di quel momento e alla traccia della richiesta, senza cambiare strumento. Il collante tecnico è l'**ECS** (cap. 5).

**Posizionamento vs Prometheus.** Prometheus è **specializzato** (solo metriche, modello pull, PromQL, molto efficiente). Elastic è **generalista e unificante** (tutti i segnali in un posto, retention lunga, ricerca full-text, ML). Compromesso di fondo: **specializzazione vs unificazione**. Non sono alternativi: spesso **coesistono** (cap. 9).

---

## Cap. 2 — Anatomia dello stack (i "collaboratori")

**Il flusso:** `sorgente → agent → (Logstash) → Elasticsearch → Kibana`. I dati vanno in una direzione; la *configurazione* viaggia in senso opposto (da Fleet verso gli agent).

- **Elasticsearch** — il cuore: memorizza (documenti JSON in data stream), indicizza, analizza (aggregazioni). Distribuito su cluster con shard e repliche.
- **Kibana** — front-end unico: visualizzazione, app Observability, Fleet, Machine Learning, Alerting, gestione stack.
- **Beats** — agent leggeri single-purpose: **Metricbeat** (metriche), Filebeat (log), Packetbeat, Heartbeat… Organizzati in **moduli → metricset**.
- **Elastic Agent** — agente unico che raccoglie log+metriche+tracce via **integrations**; gestito da Fleet. Sotto il cofano esegue Beats.
- **Fleet** — console in Kibana per gestire la flotta di agent tramite **agent policy** (config centralizzata, propagazione automatica, enrollment, upgrade, health).
- **Logstash** — pipeline ETL (input→filter→output); per le sole metriche spesso non serve.
- **Elastic APM** — tracce distribuite e metriche applicative (il terzo segnale).

**Beats vs Elastic Agent:** i Beats vengono prima (un binario per segnale, config per host, no gestione centralizzata); l'**Elastic Agent + Fleet** unifica e centralizza. **Oggi consigliato: Elastic Agent + Fleet.** Orizzonte strategico: **OpenTelemetry/EDOT** (cap. 10).

---

## Cap. 3 — Il modello push in profondità

**Push vs pull — chi apre la connessione?**
- **Push (Elastic):** l'**agent** raccoglie e *spinge* i dati verso Elasticsearch.
- **Pull (Prometheus):** il **server** fa *scrape* degli endpoint `/metrics` dei target.

**Il ciclo (a ogni `period`):** `collect` (legge la sorgente) → `enrich` (aggiunge campi ECS e metadati **alla fonte**: host, cloud, pod) → `send` (via API `_bulk`, molti documenti in una richiesta).

- **`period`** — ogni quanto si raccoglie (`10s` per system, molto più alto per API cloud). Analogo allo `scrape_interval` di Prometheus.
- **`_bulk`** — invii batch e compressi, efficienti.

**Conseguenze pratiche:**
- ✅ **NAT/firewall:** l'agent apre connessioni in *uscita* → attraversa facilmente.
- ✅ **Ambienti effimeri:** l'entità spinge finché esiste, senza dover essere "scoperta".
- ⚠️ **Rilevamento "down" indiretto:** nel push non c'è un `up=0` come in Prometheus. Si usano gli **alert sui dati mancanti** ("se non ricevo dati da N minuti, allarme").
- **Flotta di agent da gestire** → risolta da **Fleet**.

**Ponte con Prometheus** (modulo Prometheus):
- `collector` — Elastic fa scrape di un exporter `/metrics` e poi pusha (sblocca tutti gli exporter);
- `query` — Elastic esegue PromQL contro un Prometheus esistente;
- `remote_write` — Prometheus spinge i suoi campioni dentro Elastic.

---

## Cap. 4 — Che metriche espone e raccoglie

**Modulo** = tecnologia/sorgente; **metricset** = gruppo di metriche prese insieme in una chiamata. In Elastic Agent: **integration → data stream** (stesso concetto).

- **`system`** (l'host): `cpu`, `core`, `load`, `memory`, `network`, `process`, `process_summary`, `diskio`, `filesystem`, `fsstat`, `socket`, `uptime`, `users`…
- **`docker`** (per container): `container`, `cpu`, `memory`, `network`, `diskio`, `healthcheck`, `info`, `image`, `event`.
- **`kubernetes`** — due famiglie:
  - **utilizzo** (dal kubelet): `node`, `pod`, `container`, `volume`, `apiserver`, `scheduler`…
  - **stato** (da kube-state-metrics): `state_pod`, `state_deployment`, `state_node`, `state_replicaset`, `state_daemonset`, `state_job`… → *KSM va installato nel cluster.*
  - Distinzione chiave: `pod` = **quanto consuma**; `state_pod` = **in che stato è** (Running, Pending, CrashLoopBackOff).
- **Database:** `mysql`, `postgresql`, `redis`, `mongodb`, `mssql`, `oracle` (metricset `status`, `performance`, `replication`…).
- **Cloud (via API del provider):** AWS (CloudWatch: EC2, S3, RDS, Lambda…), GCP (Cloud Monitoring), Azure (Azure Monitor).

**Dimensioni/label** (`host.name`, `container.id`, `kubernetes.pod.name`…) identificano la serie e permettono filtro e raggruppamento. In TSDS formano il `_tsid`.

---

## Cap. 5 — Il modello dati delle metriche

**Una metrica = un documento JSON** con `@timestamp` (il *quando*), i valori (il *quanto*), le dimensioni (il *di chi*). È il punto storicamente debole (occupa più di un TSDB puro); il resto del capitolo è la risposta.

- **ECS (Elastic Common Schema)** — dizionario comune di nomi di campo (`host.name`, `cloud.provider`…) che abilita la **correlazione** tra segnali. Donato a OpenTelemetry; ⚠️ convergenza con le **OTel Semantic Conventions** in corso.
- **Data stream** — astrazione su una sequenza di indici con **rollover** automatico (per età/dimensione/doc). Naming: **`metrics-{dataset}-{namespace}`** → es. `metrics-system.cpu-default`.
- **TSDS (Time Series Data Streams)** — `index.mode: time_series`. Le dimensioni (`time_series_dimension: true`) formano il **`_tsid`**; routing per serie+tempo → compressione migliore. Campi metrica tipizzati:
  - **`gauge`** — sale e scende (CPU, memoria) → media/max;
  - **`counter`** — solo cresce, si azzera (byte totali) → **rate**.
- **Efficienza storage:** **downsampling** (aggrega i dati vecchi a granularità più grossa) + **synthetic `_source`** (ricostruisce il JSON al volo invece di salvarlo). ⚠️ *Cifre e licenza da verificare per versione.*

---

## Cap. 6 — Configurazione e ciclo di vita

- **Agent policy in Fleet:** aggiungi un'integration a una policy, configuri metricset/`period`/filtri/credenziali, Fleet la propaga a tutti gli agent iscritti. Modello **dichiarativo e centralizzato**. Policy diverse per ruoli diversi.
- **Output:** Elasticsearch (normale) o Logstash. Sicurezza con **API key** + **TLS**. Su Serverless anche il **Managed OTLP endpoint**.
- **ILM (Index Lifecycle Management):** fasi **hot → warm → cold → frozen → delete** (rollover, force-merge, searchable snapshot). Per cluster **self-managed** a tier. Retention e controllo costi.
- **DSL (Data Stream Lifecycle):** più semplice (retention + rollover + downsampling), nativo su **Serverless**.
- **ILM vs DSL:** complesso con tier → ILM; semplice/Serverless → DSL.
- **Gestione agent nel tempo:** enrollment (token), upgrade rolling, health (complementare agli alert sui dati mancanti).

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

*Versione sintetica per lettura su GitHub. La trattazione distesa completa è nel PDF (non incluso nel repo).*
