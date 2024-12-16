FROM docker:dind

WORKDIR /srv

COPY requirements.txt requirements.txt

RUN apk del busybox && \
    apk add --no-cache python3 py3-yaml bash squashfs-tools git ansible openssh-client coreutils binutils findutils jq grep file make gpg gpg-agent util-linux xxhash curl vim && \
    apk add --no-cache py3-pip py3-click py3-jmespath tar && \
    pip install --break-system-packages -r requirements.txt

COPY . .
