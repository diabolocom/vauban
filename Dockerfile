FROM docker:dind

WORKDIR /srv

COPY requirements.txt requirements.txt

ENV VERSION=1.17.2

ADD https://releases.hashicorp.com/vault/${VERSION}/vault_${VERSION}_linux_amd64.zip /tmp/
ADD https://releases.hashicorp.com/vault/${VERSION}/vault_${VERSION}_SHA256SUMS      /tmp/
ADD https://releases.hashicorp.com/vault/${VERSION}/vault_${VERSION}_SHA256SUMS.sig  /tmp/

WORKDIR /tmp/

RUN apk --update add --virtual verify gpgme \
 && gpg --keyserver keyserver.ubuntu.com --recv-key 0x72D7468F \
 && gpg --verify /tmp/vault_${VERSION}_SHA256SUMS.sig \
 && apk del verify \
 && cat vault_${VERSION}_SHA256SUMS | grep linux_amd64 | sha256sum -c \
 && unzip vault_${VERSION}_linux_amd64.zip \
 && mv vault /usr/local/bin/ \
 && rm -rf /tmp/* \
 && rm -rf /var/cache/apk/*

WORKDIR /srv

RUN apk del busybox && \
    apk add --no-cache python3 py3-yaml bash squashfs-tools git ansible openssh-client coreutils binutils findutils jq grep file make gpg gpg-agent util-linux xxhash curl vim && \
    apk add --no-cache py3-pip py3-click py3-jmespath tar skopeo htop jo debootstrap rsync && \
    pip install --break-system-packages -r requirements.txt

ARG VAUBAN_SHA1

RUN [[ ${VAUBAN_SHA1:-null} != null ]]

ENV VAUBAN_SHA1=$VAUBAN_SHA1

COPY *.sh *.py *.conf config.yml ./
COPY modules.d ./modules.d
