FROM python:3.13-alpine

WORKDIR /app

COPY Makefile client.sh install.sh .

RUN apk add --no-cache make bash jo curl jq git \
    && make

ENV CHECK_FOR_UPGRADE=off \
    VAUBAN_CLIENT_USER_AGENT="vauban-client (docker)"

ENTRYPOINT ["vauban-client"]
