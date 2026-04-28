# Azure ACA only supports amd64, so we need to specify the platform for both stages of the build.
FROM --platform=linux/amd64 cgr.dev/chainguard/go:latest-dev AS build

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod edit -dropreplace=github.com/chainguard-dev/platform-examples || true
RUN go mod download

COPY main.go ./

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/image-copy-acr .

FROM --platform=linux/amd64 cgr.dev/chainguard/static:latest-glibc

COPY --from=build /out/image-copy-acr /image-copy-acr

EXPOSE 8080
ENTRYPOINT ["/image-copy-acr"]
