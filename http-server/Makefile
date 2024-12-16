SHA1 := $(shell git rev-parse HEAD)
.DEFAULT_GOAL := build

build:
	docker build -t vauban-http-server .
	docker tag vauban-http-server vauban-http-server:${SHA1}

push:
	docker push vauban-http-server:latest
	docker push vauban-http-server:${SHA1}

dev:
	docker compose up

all: push
