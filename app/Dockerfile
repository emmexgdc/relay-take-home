FROM node:22

WORKDIR /app

RUN apt-get update \
 && apt-get install -y --no-install-recommends tini \
 && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY . .

EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "sh", "./entrypoint.sh"]
