# ---- build backend ----
FROM rust:1.88-slim-bookworm AS build
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY backend/Cargo.toml ./Cargo.toml
COPY backend/src ./src
RUN cargo build --release

# ---- runtime ----
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/target/release/ssh-web /app/ssh-web
COPY frontend /app/static
ENV BIND=0.0.0.0:8080
EXPOSE 8080
VOLUME ["/app/data"]
CMD ["/app/ssh-web"]
