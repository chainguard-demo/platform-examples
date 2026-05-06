# syntax=docker/dockerfile:1
# Stage 1: install npm dependencies on the dev image, which ships npm.
# Stage 2 then copies the populated node_modules + app source into the
# shell-less runtime image (node:22), which has only the node binary.
FROM cgr.dev/smalls.xyz/node:22-dev AS build
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

FROM cgr.dev/smalls.xyz/node:22
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY package.json server.js ./
EXPOSE 8080
# The base image's ENTRYPOINT is already /usr/bin/node — pass the script as CMD.
CMD ["server.js"]
