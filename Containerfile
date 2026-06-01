# Multi-stage Erlang build for hecate-mpong-bot.
# Pushed to ghcr.io/hecate-services/hecate-mpong-bot:latest + :semver.

#----------------------------------------------------------------------
# Stage 1 — builder: full Erlang + rebar3 + deps
#----------------------------------------------------------------------
FROM docker.io/erlang:27-alpine AS builder

RUN apk add --no-cache \
    git curl bash \
    build-base cmake \
    perl linux-headers

# Rust via rustup (hecate_om transitively pulls macula_quic, a Rust NIF;
# Alpine's rustc is too old for its deps). When reckon_db slices land
# this is needed for reckon_db 2.x NIFs too.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
# musl-targeted rustup defaults to crt-static; cdylib NIFs need it off.
ENV RUSTFLAGS="-C target-feature=-crt-static"

WORKDIR /build
COPY rebar.config rebar.lock ./
COPY src ./src
COPY apps ./apps
COPY config ./config

# Fetch deps + assemble a production release with embedded ERTS.
RUN rebar3 as prod tar

#----------------------------------------------------------------------
# Stage 2 — runtime: slim image, just the release tarball
#----------------------------------------------------------------------
FROM docker.io/alpine:3.22

RUN apk add --no-cache libstdc++ ncurses-libs openssl ca-certificates

WORKDIR /app
COPY --from=builder /build/_build/prod/rel/hecate_mpong_bot/*.tar.gz /tmp/release.tar.gz
RUN tar xf /tmp/release.tar.gz && rm /tmp/release.tar.gz

# Realm cert mounts here; station socket mounts under /run/macula.
VOLUME ["/etc/hecate/secrets", "/var/lib/hecate-mpong-bot"]

EXPOSE 8470

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --spider -q http://localhost:8470/health || exit 1

ENTRYPOINT ["/app/bin/hecate_mpong_bot"]
CMD ["foreground"]
