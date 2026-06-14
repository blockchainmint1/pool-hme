# Multi-stage build: compile TS, then ship a slim runtime image.
FROM node:20-bookworm-slim AS build
WORKDIR /app
COPY package.json tsconfig.json ./
RUN npm install --no-audit --no-fund
COPY src ./src
RUN npm run build

FROM node:20-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production
# better-sqlite3 ships prebuilt binaries for glibc node images.
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund \
  && apt-get update && apt-get install -y --no-install-recommends curl \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/dist ./dist
RUN mkdir -p /data
ENV DB_PATH=/data/indexer.sqlite
ENV HTTP_PORT=3001
EXPOSE 3001
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=5 \
  CMD curl -fsS http://localhost:3001/health || exit 1
CMD ["node", "dist/index.js"]
