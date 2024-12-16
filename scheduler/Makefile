# FIXME allow config

build:
	docker build -t vauban-scheduler .

shell: build
	@([[ ! -f ${HOME}/.config/vauban_client.json ]] && echo "You must initialize vauban-client first !" ) || docker run --rm --name scheduler -v ${HOME}/.config/vauban_client.json:/app/.config/vauban_client.json:ro -v $(shell dirname ${PWD})/config.yml:/srv/config.yml:ro --entrypoint bash --env-file .env -it vauban-scheduler

dev: build
	@([[ ! -f ${HOME}/.config/vauban_client.json ]] && echo "You must initialize vauban-client first !" ) || docker run --rm --name scheduler --env-file .env -v ${HOME}/.config/vauban_client.json:/app/.config/vauban_client.json:ro -v $(shell dirname ${PWD}):/mnt:ro vauban-scheduler /mnt/config.yml
