SHA1 := $(shell git rev-parse HEAD)

all:
	# FIXME make it configurable
	docker build -t zarakailloux/vauban --build-arg "VAUBAN_SHA1=${SHA1}" .
