FROM python:3.10-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY simulator.py payload.py fleet.py ./

ENV PYTHONUNBUFFERED=1

# Default entrypoint is the in-cluster fleet runner (Workload Identity +
# ConfigMap roster). The local one-device-per-process workflow still runs
# via `python simulator.py --device <id>`.
CMD ["python", "fleet.py"]
