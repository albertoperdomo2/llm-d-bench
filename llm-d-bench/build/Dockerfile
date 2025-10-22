FROM python:3.12-slim

RUN useradd -m -u 1001 guidellm

RUN apt-get update && \
    apt-get install -y curl vim git screen && \
    rm -rf /var/lib/apt/lists/*

RUN pip install guidellm

RUN mkdir -p /workspace

WORKDIR /workspace

CMD ["/bin/bash"]
