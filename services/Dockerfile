# Tier 2: one SecureBank microservice. Build with --build-arg SERVICE=users|accounts|passbook
FROM python:3.11-slim
ARG SERVICE
WORKDIR /app
COPY services/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY services/common/ common/
COPY services/${SERVICE}/ ${SERVICE}/
WORKDIR /app/${SERVICE}
# Config at run time: DB_HOST, DB_USER, DB_PASSWORD, DB_NAME, INTERNAL_TOKEN, S3_BUCKET, SERVER_ID
EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
