# syntax=docker/dockerfile:1
# Stage 1: install production deps with pnpm on the dev image. Stage 2 copies
# the populated node_modules into the slim runtime variant — node:25-slim has
# only the node binary (no shell, no npm/pnpm).
FROM cgr.dev/smalls.xyz/node:25-dev AS build
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
# --frozen-lockfile fails the build if the lockfile is out of sync with package.json
RUN pnpm install --prod --frozen-lockfile

FROM cgr.dev/smalls.xyz/node:25-slim
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY package.json server.js ./
EXPOSE 8080
CMD ["server.js"]
