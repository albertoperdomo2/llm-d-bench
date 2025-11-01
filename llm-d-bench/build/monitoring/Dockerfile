FROM python:3.12-slim

RUN groupadd -r metrics -g 1001 && \
    useradd -r -g metrics -u 1001 -m -s /bin/bash metrics

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && \
    rm /tmp/requirements.txt

COPY vllm_metrics_collector.py /usr/local/bin/vllm_metrics_collector.py
COPY plot_vllm_metrics.py /usr/local/bin/plot_vllm_metrics.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/vllm_metrics_collector.py \
             /usr/local/bin/plot_vllm_metrics.py \
             /usr/local/bin/entrypoint.sh

RUN mkdir -p /metrics /tmp/monitoring && \
    chown -R metrics:metrics /metrics /tmp/monitoring

USER metrics

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD [ -f /tmp/monitoring/.healthy ] || exit 1

WORKDIR /metrics

ENV PYTHONUNBUFFERED=1 \
    LOG_LEVEL=INFO

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
