FROM cgr.dev/chainguard/go:latest-dev AS build

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod edit -dropreplace=github.com/chainguard-dev/platform-examples || true
RUN go mod download

COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/image-copy-acr .

FROM cgr.dev/chainguard/static:latest-glibc

COPY --from=build /out/image-copy-acr /image-copy-acr

EXPOSE 8080
ENTRYPOINT ["/image-copy-acr"]
