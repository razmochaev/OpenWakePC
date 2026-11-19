FROM python:3.12-slim

WORKDIR /srv/wakepc

COPY pyproject.toml ./
COPY common ./common
COPY relay ./relay

RUN pip install --no-cache-dir .

ENV WAKEPC_RELAY_HOST=0.0.0.0
ENV WAKEPC_RELAY_PORT=8787

EXPOSE 8787

CMD ["python", "-m", "relay"]
