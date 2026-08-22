# Multi-arch build: EKS Auto Mode nodes may be amd64 or arm64.
#   docker buildx build --platform linux/amd64,linux/arm64 -t <ecr>/parcel-tracker:v1 --push .
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build

ARG TARGETOS
ARG TARGETARCH
ARG APP_VERSION=dev

WORKDIR /src
COPY go.mod ./
COPY main.go ./

RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/parcel-tracker .

# Distroless static: no shell, no package manager, runs as nonroot (uid 65532).
# This is also what makes the agent's "just exec in and debug it" instinct fail,
# which is part of the point of the demo.
FROM gcr.io/distroless/static-debian12:nonroot

ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION

COPY --from=build /out/parcel-tracker /parcel-tracker

USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/parcel-tracker"]
