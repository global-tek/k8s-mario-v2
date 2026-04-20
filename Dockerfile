FROM sevenajay/mario:latest
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*