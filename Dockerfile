# Сборка: Web-приложение и сервер в одном образе.
FROM debian:bookworm-slim AS build
ARG FLUTTER_VERSION=3.47.7
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git xz-utils unzip clang \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz \
    | tar -xJ -C /opt && git config --global --add safe.directory /opt/flutter
ENV PATH=/opt/flutter/bin:$PATH

WORKDIR /src
COPY app/pubspec.* app/
RUN cd app && flutter pub get
COPY server/pubspec.* server/
RUN cd server && dart pub get
COPY app app
COPY server server
# CanvasKit из сборки, без запросов к CDN Google.
RUN cd app && flutter build web --release --no-web-resources-cdn
RUN cd server && dart build cli -o /out

FROM debian:bookworm-slim
# Корневые сертификаты: сервер сам ходит по HTTPS (push через Firebase).
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/bundle /aura
COPY --from=build /src/app/build/web /aura/web
RUN mkdir /data && chown 1000:1000 /data
ENV AURA_DB=/data/aura.db AURA_WEB=/aura/web PORT=8080
VOLUME /data
EXPOSE 8080
USER 1000:1000
CMD ["/aura/bin/main"]
