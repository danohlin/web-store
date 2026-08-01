# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
FROM node:24-slim AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json tsconfig.app.json tsconfig.node.json vite.config.ts index.html ./
COPY src ./src
RUN npm run build

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
# nginx-unprivileged runs as a non-root user and listens on 8080, so the pod
# needs no capabilities and the container filesystem can stay read-only.
FROM nginxinc/nginx-unprivileged:1.27-alpine AS runtime

# Rendered by the image's entrypoint, which substitutes only variables that are
# actually set in the environment — so nginx's own $uri and $host survive.
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
# Not a template: it contains no variables, and it is included from several
# places to work around nginx's add_header inheritance rule.
COPY security-headers.conf /etc/nginx/security-headers.conf

COPY --from=build /app/dist /usr/share/nginx/html

# Always defined, so the template can never render an empty proxy_pass and
# fail nginx's config check at startup.
ENV BACKEND_ORIGIN=http://backend:4000

EXPOSE 8080

STOPSIGNAL SIGQUIT
