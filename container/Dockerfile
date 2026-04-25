FROM node:20-alpine

# install PowerShell Core (pwsh) on Alpine
RUN apk add --no-cache wget ca-certificates libssl3 libstdc++ icu-libs git \
  && wget -q https://github.com/PowerShell/PowerShell/releases/download/v7.4.2/powershell-7.4.2-linux-musl-x64.tar.gz \
       -O /tmp/pwsh.tar.gz \
  && mkdir -p /opt/microsoft/powershell/7 \
  && tar zxf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell/7 \
  && chmod +x /opt/microsoft/powershell/7/pwsh \
  && ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh \
  && rm /tmp/pwsh.tar.gz

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./
COPY get-code.ps1 ./

# bake TokenTacticsV2 into the image so requests don't need to clone
RUN git clone https://github.com/f-bader/TokenTacticsV2.git /opt/ttv

# secure log directory — owner read/write/execute only
RUN mkdir -p /app/logs && chmod 700 /app/logs

EXPOSE 8080
CMD ["node", "server.js"]
