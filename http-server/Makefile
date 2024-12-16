SHA1 := $(shell git rev-parse HEAD)

all:
	# FIXME
	docker build -t vauban-http-server .
	docker tag vauban-http-server vauban-http-server:"${SHA1}"
