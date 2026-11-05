# WA Classic bridge, see docker-compose.yml
# cross compiles on the build machine (amd64 + arm64)
FROM --platform=$BUILDPLATFORM golang:1.27-trixie AS build
ARG TARGETOS TARGETARCH
ARG BRIDGE_VERSION=dev
RUN apt-get update && apt-get install -y --no-install-recommends patch && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN ./patches/prepare.sh && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags "-s -w -X main.version=${BRIDGE_VERSION#v}" -o /wa4s-bridge .

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates tzdata \
	&& rm -rf /var/lib/apt/lists/* \
	&& useradd -u 1000 -m wa4s && mkdir /data && chown wa4s:wa4s /data && chmod 700 /data
COPY --from=build /wa4s-bridge /usr/local/bin/wa4s-bridge
# app debs for the cydia source (bridge/debs/)
COPY debs/ /usr/share/wa-classic/debs/
USER wa4s
VOLUME /data
ENV WA4S_DATA=/data WA4S_LISTEN=:8097 WA4S_TLS_LISTEN=:25567 WA4S_DEBS=/usr/share/wa-classic/debs
EXPOSE 8097 25567
ENTRYPOINT ["wa4s-bridge"]
