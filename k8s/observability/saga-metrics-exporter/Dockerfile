# Build context: platform-infra repo root ->
#   docker build -f k8s/observability/saga-metrics-exporter/Dockerfile .
FROM node:20-alpine

WORKDIR /app

COPY k8s/observability/saga-metrics-exporter/package*.json ./
RUN npm install --omit=dev --ignore-scripts

COPY k8s/observability/saga-metrics-exporter/index.js ./

RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 9308

HEALTHCHECK --interval=10s --timeout=5s --retries=3 \
  CMD wget -qO- http://localhost:9308/health || exit 1

CMD ["node", "index.js"]
