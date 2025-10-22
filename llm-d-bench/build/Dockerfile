FROM python:3.11-slim

RUN useradd -m -u 1001 guidellm

RUN apt-get update && \
    apt-get install -y curl vim git screen && \
    rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    install -o guidellm -g guidellm -m 0755 kubectl /usr/local/bin/kubectl && \
    rm kubectl

# copy requirements and install Python dependencies
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# create app directory and copy scripts
RUN mkdir -p /workspace && chown guidellm:guidellm /workspace
COPY --chown=guidellm:guidellm monitor.py /workspace/
COPY --chown=guidellm:guidellm kubeconfig /workspace/
COPY --chown=guidellm:guidellm install_telegram_notify.sh /workspace/
RUN chmod +x /workspace/install_telegram_notify.sh

# install guidellm
RUN git clone --branch experimental/additional-rate-types https://github.com/albertoperdomo2/guidellm.git /workspace/guidellm && \
    pip install -e /workspace/guidellm

# run telegram notify installation as guidellm user
USER 1001
RUN bash /workspace/install_telegram_notify.sh || true

WORKDIR /workspace

CMD ["/bin/bash"]
