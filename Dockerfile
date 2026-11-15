FROM python:3.11-slim

WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

# Config comes from environment variables at run time:
# DB_HOST, DB_USER, DB_PASSWORD, DB_NAME, S3_BUCKET, SECRET_KEY, SERVER_ID
EXPOSE 80

CMD ["gunicorn", "--bind", "0.0.0.0:80", "--workers", "2", "app:app"]
