# CRL monitor image. Non-root, dependencies installed only from hash-pinned requirements.txt.
# Pin the base image by digest in production, e.g.
#   --build-arg BASE_IMAGE=registry.access.redhat.com/ubi9/python-312@sha256:<digest>
ARG BASE_IMAGE=registry.access.redhat.com/ubi9/python-312:latest
FROM ${BASE_IMAGE}

WORKDIR /opt/app-root/src
COPY requirements.txt .
RUN pip install --no-cache-dir --require-hashes -r requirements.txt
COPY crl_monitor.py .

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 1001
ENTRYPOINT ["python", "/opt/app-root/src/crl_monitor.py"]
CMD ["--config", "/etc/crl-monitor/config.yaml"]
