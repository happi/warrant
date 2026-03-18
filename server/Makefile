REGISTRY := 10.20.0.210:5000
IMAGE_NAME := backlog-server
TAG := $(shell git rev-parse --short HEAD)
IMAGE := $(REGISTRY)/$(IMAGE_NAME):$(TAG)
NUC := happi@10.20.0.210
INFRA_DIR := ../server-infrastructure
DEPLOY_YAML := $(INFRA_DIR)/k8s/apps/backlog-server/deployment.yaml

.PHONY: compile shell clean build push deploy

compile:
	rebar3 compile

shell:
	rebar3 shell --apps backlog_server --config config/sys.config

clean:
	rebar3 clean

build:
	rsync -avz --exclude='_build' --exclude='.git' --exclude='backlog-md' --exclude='backlog' . $(NUC):/tmp/build-backlog-server/
	ssh $(NUC) "cd /tmp/build-backlog-server && docker build -t $(IMAGE) ."

push: build
	ssh $(NUC) "docker push $(IMAGE)"

deploy: push
	@echo "Updating deployment manifest to $(IMAGE)..."
	sed -i 's|image: $(REGISTRY)/$(IMAGE_NAME):.*|image: $(IMAGE)|' $(DEPLOY_YAML)
	cd $(INFRA_DIR) && git add k8s/apps/backlog-server/deployment.yaml \
		&& git commit -m "backlog-server: update image to $(TAG)" \
		&& git push nas master && git push origin master
	@echo "Pushed to server-infrastructure — ArgoCD will sync the new image."
