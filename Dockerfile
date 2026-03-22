# ---- Build stage ----
FROM python:3.12-slim AS builder

WORKDIR /build

# Install build deps for psycopg2 (only in builder stage)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc libpq-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --prefix=/install --no-cache-dir -r requirements.txt


# ---- Runtime stage ----
FROM python:3.12-slim

# Runtime PostgreSQL client library
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 curl \
    && rm -rf /var/lib/apt/lists/*

# Copy installed packages from builder
COPY --from=builder /install /usr/local

WORKDIR /app
COPY app.py .

# Run as non-root user
RUN useradd -r -u 1001 appuser && chown appuser /app
USER appuser

EXPOSE 5000

# Gunicorn: 2 workers, bind to all interfaces on port 5000
CMD ["gunicorn", "--workers", "2", "--bind", "0.0.0.0:5000", \
     "--timeout", "30", "--access-logfile", "-", "--error-logfile", "-", \
     "app:app"]
