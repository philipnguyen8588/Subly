FROM golang:1.23 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/subly-server .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/subly-server /subly-server
ENV DATA_DIR=/data LISTEN=:8080
VOLUME /data
EXPOSE 8080
ENTRYPOINT ["/subly-server"]
