# OTel Lab — Osservabilità con OpenTelemetry, Prometheus e Grafana con strumentazione manuale delle metriche

Creazione di un'applicazione Python (Flask), instrumentata con OpenTelemetry che invia metriche automatiche ad un Collector, che
espone le metriche a Prometheus e Grafana le visualizza in dashboard.

Ho aggiunto una `metrica custom`: un contatore di richieste `app_requests_total`, etichettato con una label `name` che a ogni richiesta vale randomicamente Pippo, Paperino o Pluto.
Alla fine avremo tre linee distinte in Grafana, una per nome.

A differenza delle metriche "automatiche" della libreria Flask, questa è stata scritta da me nel codice: Per l'esercizio dovevo modificare l'esercizio precedente in modo che il collector esportasse non solo le metriche automatiche di Flask ma anche la mia metrica custom.

## Struttura del progetto

```
otel-lab/
├── Vagrantfile               # VM Ubuntu 24.04 + rete + provisioning
├── podman-compose.yml        # definizione dei 4 servizi
├── Dockerfile                # build dell'app Python
├── app.py                    # app Flask instrumentata OTel
├── requirements.txt          # dipendenze Python
├── prometheus.yml            # config scrape di Prometheus
└── grafana/
    ├── grafana.ini           # config server Grafana
    └── provisioning/
        └── datasources/      # datasource Prometheus pre-provisionato
```

## Architettura

```
  App Python (Flask)            OpenTelemetry            Prometheus            Grafana
  otel-lab-app         --OTLP-->  Collector    --scrape-->  (TSDB)   --query--> (dashboard)
  :5000                gRPC 4317   :9464                     :9090               :3000
```

L'app non parla direttamente con Prometheus: Manda le metriche al Collector via OTLP; il Collector le ri-espone in formato Prometheus su :9464; Prometheus le raccoglie e le archivia; Grafana le fa visualizzare in Dashboard.

## Passo 1 — Avviare la macchina virtuale e scrivere gli script del progetto

Tutto il lab gira dentro una VM Ubuntu gestita da Vagrant, provisionata in modo che dopo il primo `vagrant up` scarichi la VM e installi Podman.
- **Dockerfile**: Descrive come costruire l'immagine dei container dell' app
  In breve parte da un'immagine Python di base, copia `requirements.txt` installando le librerie necessarie, copia `app.py` dentro l'immagine e dice quale comando eseguire all'avvio(`python
  app.py`).
- **requirements.txt**: Elenco librerie che l'app usa (Flask e i pacchetti di OTel come l'SDK e l'exporter OTLP), durante la build il Dockerfile le installa.
- **app.py** — Applicazione Flask instrumentata con OpenTelemetry SDK, fa tre cose principali:
    - Configura la pipeline delle metriche OpenTelemetry, crea un `MeterProvider` con un `PeriodicExportingMetricReader` che, ogni 5 secondi, spedisce le metriche al Collector via OTLP
       (protocollo `gRPC`, porta `4317`).
    - Definisce la `metrica custom`: Un counter app_requests_total, creato a mano con `meter.create_counter(...)`.
    - Espone l'endpoint `/` definendo una funzione `home()` che ad ogni richiesta sceglie un nome a caso tra Pippo, Paperino, Pluto e incrementa il counter passando {"name": nome}.
       > Il valore della metrica è sempre un numero (il conteggio),il nome vive nella label e  mai nel valore.
- **podman-compose.yml**: Il file che orchestra i 4 container e li fa parlare tra loro, definendo un servizio per ciascuno.
  - `app-python` - costruito nel Dockerfile, espone la porta 5000
  - `otel-collector` — riceve la telemetria OTLP e la espone in formato
    Prometheus sulla porta `9464`.
  - prometheus` — scrapa il Collector (`otel-collector:9464`) e se stesso
    (`localhost:9090`) ogni 15s.
  - `grafana` — datasource Prometheus pre-provisionato, per la dashboard delle metriche.
  Il Compose crea anche una rete interna condivisa che è ciò che permette ai container di chiamarsi per nome (l'app manda a otel-collector:4317, Prometheus scrapa otel-collector:9464) invece
  che per indirizzo IP.
- **otel-collector-config.yaml**: E' qui che ho effettuato la configurazione del collector in modo che durante la struttura `receiver -> processor -> exporter` prendesse anche le metriche
  scritte da me e le esportasse per essere scarpate da Prometheus.
  - **receiver otlp**: Apre le porte 4317/4318 e riceve le metriche spinte dall'app.
  - **processor batch** Accorpa le metriche per efficienza prima di inoltrarle.
  - **exporter prometheus**: Espone le metriche su :9464/metrics in formato Prometheus. Attenzione: non spinge nulla, si limita a esporre; sarà Prometheus a venirle a prendere.

## Passo 2: Svolgimento

```bash
# 1. Crea e provisiona la VM (installa podman + podman-compose, attiva il linger)
vagrant up

# 2. Entra nella VM e avvia lo stack
vagrant ssh
cd /vagrant
podman-compose up -d --build # Con -d che fa girare il tutto in background e --build che ricostruisce l'immagine dall'app.py.


# 3. Verifica che i container siano attivi
podman ps

# 4. Dopodiché si può iniziare a generare traffico altrimenti il counter resterebbe a zero.
for i in $(seq 1 100); do curl -s localhost:5000/ > /dev/null; sleep 0.2; done
# fa 100 richieste http in 20 secondi, silenziando le risposte con lo sleep che distribuisce le richieste nel tempo in modo da avere un grafico su grafana più sensato, senza avere picchi.

# 5. Verifica che la metrica sia arrivata al Collector ed esposta in Prometheus
curl -s localhost:9464/metrics | grep app_requests_total

# 6. Output di esempio
app_requests_total{...,name="Pippo",...}    42
app_requests_total{...,name="Paperino",...} 35
app_requests_total{...,name="Pluto",...}    43

```
## 3. Controllare Prometheus e costruire il pannello su Grafana
Da computer http://localhost:9090, si aprirà la URI di Prometheus scrivendo la query app_request_total nella scheda Table compaiono le tre serie con i loro valori:

![seconda_parte](metriche_custom/Screenshot%202026-08-27%20alle%2010.37.27.png)

Per Grafana invece una volta aperta sul browser http://localhost:3000 e fatto l'accesso bisogna costruire il pannello per la visualizzazione delle metriche.
Prima si crea una nuova dashboard con `Create dashboard` e poi `Add visualization`, scegliendo Prometheus come data source.

Si aprirà una schermata dove nella zona query, passato dalla modalità `Builder` a `Code, incollo `sum by (name) (rate(app_requests_total[1m]))`(per vedere le richieste al secondo separate per endpoint), poi premo `Run queries`. 
A questo punto si vedranno tre linee, una per Pippo, una per Paperino e una per Pluto.
![seconda_parte](metriche_custom/Screenshot%202026-08-27%20alle%2010.37.27.png)


