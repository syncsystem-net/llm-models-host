# LLM Models Host image
# Ollama (inference) + nginx (token auth, dashboard) + cloudflared (optional static hostname).
# Provider-agnostic: anything that can run a GPU container with these env vars can host it.

ARG OLLAMA_VERSION=0.40.14
FROM ollama/ollama:${OLLAMA_VERSION}

ARG CLOUDFLARED_VERSION=2026.10.7

RUN apt-get update \
 && apt-get install -y --no-install-recommends nginx curl ca-certificates jq gettext-base tini \
 && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled /etc/nginx/conf.d/* \
 && curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64" \
 && chmod +x /usr/local/bin/cloudflared \
 && cloudflared --version

COPY nginx.conf.template /etc/llmhost/nginx.conf.template
COPY www/ /srv/www/
COPY entrypoint.sh /usr/local/bin/llmhost-entrypoint
RUN chmod +x /usr/local/bin/llmhost-entrypoint \
 && sed -i 's/\r$//' /usr/local/bin/llmhost-entrypoint /etc/llmhost/nginx.conf.template

# Models live here unless OLLAMA_MODELS points at a persistent/network volume.
ENV OLLAMA_MODELS=/root/.ollama/models

EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/llmhost-entrypoint"]
