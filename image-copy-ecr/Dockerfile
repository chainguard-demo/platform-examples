FROM golang:1.23.4-alpine3.20 AS builder

WORKDIR /app

COPY main.go .
COPY go.mod .
COPY go.sum .

RUN go build -tags lambda.norpc -o app main.go


FROM public.ecr.aws/lambda/provided:al2

# Copy function code
COPY --from=builder /app/app ./app

# Set the CMD to your handler (could also be done as a parameter override outside of the Dockerfile)
ENTRYPOINT [ "./app" ]