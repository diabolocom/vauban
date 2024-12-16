SHA1 := $(shell git rev-parse HEAD)

sha1:
	docker build -t "zarakailloux/vauban:${SHA1}" --build-arg "VAUBAN_SHA1=${SHA1}" .

latest:
	docker build -t "zarakailloux/vauban:latest" --build-arg "VAUBAN_SHA1=${SHA1}" .

all: sha1 latest
	# FIXME make it configurable
