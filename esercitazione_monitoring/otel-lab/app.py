import os
from flask import Flask

from opentelemetry.sdk.resources import Resource
from opentelemetry import trace, metrics

# Tracce
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

# Metriche
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter

# Auto-instrumentation Flask
from opentelemetry.instrumentation.flask import FlaskInstrumentor

# Endpoint del Collector (sovrascrivibile da variabile d'ambiente)
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")

# Resource: "chi" emette la telemetria comune a metriche e tracce
resource = Resource.create({"service.name": "otel-lab-app"})

# Pipeline TRACCE: Provider -> Processor(batch) -> Exporter(OTLP)
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True))
)
trace.set_tracer_provider(tracer_provider)

# Pipeline METRICHE: Provider -> Reader(periodico) -> Exporter(OTLP)
metric_reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint=OTLP_ENDPOINT, insecure=True),
    export_interval_millis=5000,   # spedisce le metriche ogni 5s
)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)

# Metrica custom (instrumentation manuale)
meter = metrics.get_meter("otel-lab-app")
request_counter = meter.create_counter(
    "app_requests_total",
    unit="1",
    description="Numero totale di richieste ricevute",
)

# --- App Flask ---
app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)   # span automatici per ogni richiesta

@app.route("/")
def home():
    request_counter.add(1, {"endpoint": "/"})
    return "Ciao da otel-lab!\n"

@app.route("/health")
def health():
    request_counter.add(1, {"endpoint": "/health"})
    return {"status": "ok"}

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
