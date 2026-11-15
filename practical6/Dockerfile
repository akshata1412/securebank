# Practical 6 - Ubuntu base image with Apache2 that starts automatically
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends apache2 \
    && rm -rf /var/lib/apt/lists/*
COPY index.html /var/www/html/index.html
EXPOSE 80
# Run Apache in the foreground so it is the container's main process (auto-starts with the container)
CMD ["apachectl", "-D", "FOREGROUND"]
