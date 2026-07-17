// moja-trace-bridge: consumes Mojaloop Event-SDK trace events from Kafka
// (topic-event-trace) and forwards them to an OTLP/HTTP endpoint (Tempo).
//
// The Event SDK propagates trace context through Kafka messages and FSPIOP
// callbacks, so these spans form continuous end-to-end traces across the
// whole transfer pipeline — something OTel auto-instrumentation cannot do
// for node-rdkafka based services. This bridge is the missing converter
// (the legacy event-stream-processor targeted Elastic APM, not OTLP).
//
// Env: KAFKA_BROKERS, TRACE_TOPIC, OTLP_URL, FLUSH_MS, BATCH_MAX, TLS_SKIP

const { Kafka, logLevel, CompressionTypes, CompressionCodecs } = require('kafkajs');
const lz4 = require('lz4js');
const https = require('https');
const http = require('http');

// Event-SDK producers use compression.type: lz4; kafkajs has no built-in codec
CompressionCodecs[CompressionTypes.LZ4] = () => ({
  compress: (encoder) => Buffer.from(lz4.compress(encoder.buffer)),
  decompress: (buffer) => Buffer.from(lz4.decompress(buffer)),
});

const BROKERS = (process.env.KAFKA_BROKERS || 'localhost:9092').split(',');
const TOPIC = process.env.TRACE_TOPIC || 'topic-event-trace';
const OTLP_URL = process.env.OTLP_URL || 'http://tempo:4318/v1/traces';
const FLUSH_MS = Number(process.env.FLUSH_MS || 2000);
const BATCH_MAX = Number(process.env.BATCH_MAX || 200);
const TLS_SKIP = process.env.TLS_SKIP === 'true';

const agent = OTLP_URL.startsWith('https')
  ? new https.Agent({ keepAlive: true, rejectUnauthorized: !TLS_SKIP })
  : new http.Agent({ keepAlive: true });

let queue = [];
let dropped = 0;
let sent = 0;

function isoToNano(ts) {
  const ms = new Date(ts).getTime();
  return Number.isFinite(ms) ? String(ms) + '000000' : undefined;
}

function attr(key, value) {
  return { key, value: { stringValue: String(value) } };
}

// Event-SDK message → OTLP span (grouped per service into resourceSpans at flush)
function toSpan(msg) {
  const trace = msg?.metadata?.trace;
  if (!trace?.traceId || !trace?.spanId || !trace.startTimestamp || !trace.finishTimestamp) return null;

  const event = msg?.metadata?.event || {};
  const tags = trace.tags || {};
  const attributes = Object.entries(tags).map(([k, v]) => attr(k, v));
  if (event.type) attributes.push(attr('event.type', event.type));
  if (event.action) attributes.push(attr('event.action', event.action));

  const status =
    event.state?.status === 'failed' || tags.transactionAction === 'error'
      ? { code: 2, message: event.state?.description || '' }
      : { code: 0 };

  return {
    service: trace.service || 'unknown',
    span: {
      traceId: trace.traceId,
      spanId: trace.spanId,
      parentSpanId: trace.parentSpanId || undefined,
      name: trace.service || `${event.type || 'span'}:${event.action || ''}`,
      kind: 1, // SPAN_KIND_INTERNAL
      startTimeUnixNano: isoToNano(trace.startTimestamp),
      endTimeUnixNano: isoToNano(trace.finishTimestamp),
      attributes,
      status,
    },
  };
}

function flush() {
  if (queue.length === 0) return;
  const batch = queue;
  queue = [];

  const byService = new Map();
  for (const item of batch) {
    if (!byService.has(item.service)) byService.set(item.service, []);
    byService.get(item.service).push(item.span);
  }

  const body = JSON.stringify({
    resourceSpans: [...byService.entries()].map(([service, spans]) => ({
      resource: { attributes: [attr('service.name', service)] },
      scopeSpans: [{ scope: { name: 'moja-trace-bridge' }, spans }],
    })),
  });

  const req = (OTLP_URL.startsWith('https') ? https : http).request(
    OTLP_URL,
    { method: 'POST', headers: { 'content-type': 'application/json' }, agent, timeout: 10000 },
    (res) => {
      res.resume();
      if (res.statusCode >= 300) {
        dropped += batch.length;
        console.error(`otlp push failed: HTTP ${res.statusCode} (${batch.length} spans dropped)`);
      } else {
        sent += batch.length;
      }
    }
  );
  req.on('error', (e) => {
    dropped += batch.length;
    console.error(`otlp push error: ${e.message} (${batch.length} spans dropped)`);
  });
  req.end(body);
}

setInterval(flush, FLUSH_MS).unref();
setInterval(() => console.log(`stats: sent=${sent} dropped=${dropped} queued=${queue.length}`), 30000).unref();

async function main() {
  const kafka = new Kafka({ clientId: 'moja-trace-bridge', brokers: BROKERS, logLevel: logLevel.WARN });
  const consumer = kafka.consumer({ groupId: 'moja-trace-bridge' });
  await consumer.connect();
  await consumer.subscribe({ topic: TOPIC, fromBeginning: false });
  console.log(`consuming ${TOPIC} from ${BROKERS.join(',')} -> ${OTLP_URL}`);

  await consumer.run({
    eachMessage: async ({ message }) => {
      try {
        const parsed = JSON.parse(message.value.toString());
        // Event-SDK wraps the EventMessage under .value when produced via
        // the central-services stream producer
        const span = toSpan(parsed) || toSpan(parsed?.value);
        if (span) {
          queue.push(span);
          if (queue.length >= BATCH_MAX) flush();
        }
      } catch (e) {
        // non-JSON or unexpected shape: skip
      }
    },
  });
}

const shutdown = () => { flush(); setTimeout(() => process.exit(0), 500); };
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

main().catch((e) => { console.error(e); process.exit(1); });
