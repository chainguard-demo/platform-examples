FROM cgr.dev/chainguard/go:latest@sha256:8df9dd7beb988f8f912df54c036ea44e4b11455da5d33e2a4eb2d19de75820c8 AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY main.go main.go
COPY internal internal
COPY cmd cmd

RUN CGO_ENABLED=0 go build -o image-mapper .

FROM cgr.dev/chainguard/static:latest@sha256:9cef3c6a78264cb7e25923bf1bf7f39476dccbcc993af9f4ffeb191b77a7951e

COPY --from=builder /app/image-mapper /usr/local/bin/image-mapper

ENTRYPOINT ["/usr/local/bin/image-mapper"]
