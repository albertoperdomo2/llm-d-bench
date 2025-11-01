FROM python:3.12-slim

RUN useradd -m -u 1001 guidellm

# Install system dependencies including network monitoring tools
RUN apt-get update && \
    apt-get install -y curl vim git screen procps net-tools iproute2 sysstat && \
    rm -rf /var/lib/apt/lists/*

# Install Python packages for benchmarking and monitoring
RUN pip install --no-cache-dir \
    guidellm \
    requests \
    pandas \
    plotly \
    psutil \
    prometheus-client

# Copy monitoring scripts
COPY monitoring/vllm_metrics_collector.py /usr/local/bin/vllm_metrics_collector.py
COPY monitoring/plot_vllm_metrics.py /usr/local/bin/plot_vllm_metrics.py
RUN chmod +x /usr/local/bin/vllm_metrics_collector.py /usr/local/bin/plot_vllm_metrics.py

RUN mkdir -p /workspace

WORKDIR /workspace

CMD ["/bin/bash"]
