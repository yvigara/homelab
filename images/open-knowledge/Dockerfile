# OpenKnowledge image for kubernetes/apps/ai/open-knowledge.
#
# inkeep publishes no image, so this installs their npm package on node:alpine
# with git (a hard boot requirement) and runs `ok init` on an empty volume
# before `ok start`. Published to ghcr.io/yvigara/open-knowledge by
# .github/workflows/open-knowledge-image.yaml, tagged with OK_VERSION.
FROM node:26-alpine

RUN apk add --no-cache \
  ca-certificates \
  git=~2.54

# renovate: datasource=npm depName=@inkeep/open-knowledge
ARG OK_VERSION=0.89.18

RUN npm install -g \
  "@inkeep/open-knowledge@${OK_VERSION}" \
  @slidev/cli@53.0 \
  @slidev/theme-default@0.25

ENV OK_VERSION=${OK_VERSION}

# OK_ALLOW_EXTERNAL is left to the operator; without it the server refuses to boot.
ENV PORT=8080
ENV OK_BIND=0.0.0.0
ENV OK_HOME=/opt/data

WORKDIR ${OK_HOME}
EXPOSE 8080

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD [ ]
