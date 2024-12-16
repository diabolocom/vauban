VERSION := $(shell cat client.sh | grep VERSION= | grep -Eo '[0-9]+\..+')

install:
	./install.sh || sudo ./install.sh

docker:
	docker build -t vauban-client:latest -t vauban-client:${VERSION} .
