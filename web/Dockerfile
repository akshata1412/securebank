# Tier 1: SecureBank web app. No database driver, no database credentials.
FROM python:3.11-slim
WORKDIR /app
COPY web/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY web/ .
# Config at run time: API_URL (internal load balancer), SECRET_KEY, SERVER_ID, INTERNAL_TOKEN
EXPOSE 80
CMD ["gunicorn", "--bind", "0.0.0.0:80", "--workers", "2", "--threads", "4", "app:app"]
