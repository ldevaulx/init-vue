# Documentation GNU Make :
# https://www.gnu.org/software/make/manual/make.html

# ===================
# Variables à définir
# ===================

NAMESPACE   := init-vue
HELM_NAME   := init-vue

HELM_DIR    := deploy
HELM_VALUES := values_dev.yaml
POD_SEARCH  := $(HELM_NAME)

BUILD_DIR   := build
DOCKERFILE  := nginx.dockerfile
REPOSITORY  := 444963888884.dkr.ecr.eu-west-3.amazonaws.com/prod/init-vue

DEPLOY_TAG_STAGING    := deploy_staging
DEPLOY_TAG_PRODUCTION := deploy_prod

GOOGLE_CHAT_WEBHOOK := https://chat.googleapis.com/v1/spaces/AAAAjSk7ZJ4/messages?key=AIzaSyDdI0hCZtE6vySjMm-WEfRq3CPzqKqqsHI&token=0FspEEhQOPGOhnrHvJJ3dGLL5jEVoqiYJVNYFu2lsLw%3D
LOGS_S3_BUCKET      := passman-firmwares
LOGS_S3_PATH        := codebuild-logs


# =============================================================================
# Variables pouvant être surchargées par des variables d'environnement externes
# =============================================================================

CI        ?= 0
BUILD_TAG ?=
CODEBUILD_BUILD_SUCCEEDING ?= 0
CODEBUILD_BUILD_URL        ?=
CODEBUILD_WEBHOOK_TRIGGER  ?=
CODEBUILD_SOURCE_REPO_URL  ?=
CODEBUILD_LOG_PATH         ?=

# ====================
# Traitement préalable
# ====================

# Definit la cible par défaut
# Sinon, la première cible trouvée est exécutée
.DEFAULT_GOAL := help

# Nom du fichier Makefile (normalement, "Makefile")
TARGETS := $(MAKEFILE_LIST)

# Test présence namespace et récupération pod si environnement dev (CI=0)
ifeq ($(CI),0)
	NAMESPACE_PRESENT := $(shell kubectl get namespace     $(NAMESPACE) -o name --ignore-not-found | wc -l)
	POD_NAME          := $(shell kubectl get pods       -n $(NAMESPACE) -o name | grep $(POD_SEARCH) | cut -d'/' -f2)
	DEPLOYMENT_NAME   := $(shell kubectl get deployment -n $(NAMESPACE) -o name | grep $(POD_SEARCH) | cut -d'/' -f2)
	EXEC_BUILD        := kubectl exec -n $(NAMESPACE) $(POD_NAME) -it --
else
	EXEC_BUILD :=
endif

# Message en fonction de l'état du build
ifeq ($(CI),0)
	GOOGLE_CHAT_MESSAGE :=
else
	# Formattage : https://developers.google.com/hangouts/chat/reference/message-formats/basic
	DETAILS_BUILD := \n<$(CODEBUILD_BUILD_URL)|Logs CodeBuild>\n<https://$(LOGS_S3_BUCKET).s3.eu-west-3.amazonaws.com/$(LOGS_S3_PATH)/$(CODEBUILD_LOG_PATH).gz|Logs S3>\nReference Git : $(CODEBUILD_WEBHOOK_TRIGGER)\nRepository Git : <$(CODEBUILD_SOURCE_REPO_URL)|$(CODEBUILD_SOURCE_REPO_URL)>
	ifeq ($(CODEBUILD_BUILD_SUCCEEDING),1)
		# Build OK
		GOOGLE_CHAT_MESSAGE := *Build OK* $(DETAILS_BUILD)
	else
		# Erreur build
		GOOGLE_CHAT_MESSAGE := *ERREUR Build* $(DETAILS_BUILD)
	endif
endif

# ======
# Help !
# ======

# Astuce d'auto-documentation
# https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.PHONY: help
help: ## DEV   : This help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(TARGETS) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

# ===========
# Gestion pod
# ===========

.PHONY: pod-infos
pod-infos: ## DEV: Pod namespace and name
	@echo "NAMESPACE         = $(NAMESPACE)"
	@echo "NAMESPACE_PRESENT = $(NAMESPACE_PRESENT)"
	@echo "POD_NAME          = $(POD_NAME)"
	@echo "DEPLOYMENT_NAME   = $(DEPLOYMENT_NAME)"

.PHONY: pod-shell
pod-shell: ## DEV: Launch shell in pod
	kubectl exec -n $(NAMESPACE) $(POD_NAME) -it -- /bin/bash

.PHONY: pod-logs
pod-logs: ## DEV: Tail logs of the pod
	kubectl logs -n $(NAMESPACE) $(POD_NAME) --follow

.PHONY: pod-describe
pod-describe: ## DEV: Describe the pod
	kubectl describe pod -n $(NAMESPACE) $(POD_NAME)

.PHONY: pod-restart
pod-restart: ## DEV: Restart the pod using scaling
	kubectl scale --replicas=0 -n $(NAMESPACE) deployment/$(DEPLOYMENT_NAME)
	kubectl scale --replicas=1 -n $(NAMESPACE) deployment/$(DEPLOYMENT_NAME)

# ============
# Gestion helm
# ============

.PHONY: helm-install
helm-install: ## DEV: Install/update the application with Helm
# Creation du namespace si inexistant
# Attente pour que registry-creds ait le temps d'ajouter les tokens au namespace
ifeq ($(NAMESPACE_PRESENT),0)
	kubectl create namespace $(NAMESPACE)
	while ! kubectl get -n $(NAMESPACE) secret/awsecr-cred ; do sleep 1 ; done
endif
# Installation
	helm upgrade -n $(NAMESPACE) --install $(HELM_NAME) -f $(HELM_DIR)/values_dev.yaml $(HELM_DIR)

.PHONY: helm-uninstall
helm-uninstall: ## DEV: Remove the application with Helm
# Desinstallation
	helm uninstall -n $(NAMESPACE) $(HELM_NAME)
# Information pour supprimer le namespace
	@echo "Delete namespace with: kubectl delete namespace $(NAMESPACE)"

.PHONY: helm-install-staging
helm-install-staging: ## DEV: Test the staging application locally (the dev version shouldn't be installed)
# Creation du namespace si inexistant
# Attente pour que registry-creds ait le temps d'ajouter les tokens au namespace
ifeq ($(NAMESPACE_PRESENT),0)
	kubectl create namespace $(NAMESPACE)
	while ! kubectl get -n $(NAMESPACE) secret/awsecr-cred ; do sleep 1 ; done
endif
# Installation
	helm upgrade -n $(NAMESPACE) --install $(HELM_NAME) -f $(HELM_DIR)/values_staging.yaml --set Ingress.Host=minikube $(HELM_DIR)

# ===========
# Application
# ===========

.PHONY: app-packages
app-packages: ## Check packages and install missing dependencies
	$(EXEC_BUILD) yarn install --check-files

.PHONY: app-test
app-test: ## Run linting and unit testing for the application
	$(EXEC_BUILD) yarn lint
	$(EXEC_BUILD) yarn format

.PHONY: app-build
app-build: ## Build the application for production
ifneq (,$(findstring staging,$(BUILD_TAG)))
	$(EXEC_BUILD) yarn build-staging
else
	$(EXEC_BUILD) yarn build
endif

.PHONY: app-serve
app-serve: ## DEV: Launch dev server
	$(EXEC_BUILD) yarn dev

.PHONY: link
link: ## Link for work with common component library in dev
	$(EXEC_BUILD)  /bin/bash -c "cd /common && yarn && npm link"
	$(EXEC_BUILD)  /bin/bash -c "cd /work  && npm link @passmanSA/wifi-v5-portail-composants"




# ===============
# Container image
# ===============

.PHONY: container-auth
container-auth: ## CI: Container registry authentication
ifneq ($(BUILD_TAG),)
	@echo "BUILD_TAG=$(BUILD_TAG)"
	$(EXEC_BUILD) `aws ecr get-login --no-include-email | sed -e 's/docker login/buildah login/g' | sed -e 's|https://||g'`
else
	@echo "Aucun BUILD_TAG !"
endif

.PHONY: container-build
container-build: ## CI: Build a container from the application
ifneq ($(BUILD_TAG),)
	@echo "BUILD_TAG=$(BUILD_TAG)"
	$(EXEC_BUILD) buildah build-using-dockerfile -f $(BUILD_DIR)/$(DOCKERFILE) -t $(REPOSITORY):$(BUILD_TAG) .
else
	@echo "Aucun BUILD_TAG !"
endif

.PHONY: container-push
container-push: ## CI: Push the container to the registry
ifneq ($(BUILD_TAG),)
	@echo "BUILD_TAG=$(BUILD_TAG)"
	$(EXEC_BUILD) buildah push $(REPOSITORY):$(BUILD_TAG)
else
	@echo "Aucun BUILD_TAG !"
endif


# =============================
# Send Google Chat notification
# =============================

.PHONY: send-notification
send-notification: ##     CI: Send a notification message
ifneq ($(GOOGLE_CHAT_WEBHOOK),)
ifneq ($(GOOGLE_CHAT_MESSAGE),)
	curl -sS -X POST -H 'Content-Type: application/json' '$(GOOGLE_CHAT_WEBHOOK)' -d '{"text": "$(GOOGLE_CHAT_MESSAGE)"}';
else
	@echo "Aucun message à envoyer !"
endif
else
	@echo "Webhook non configuré !"
endif

# =====================
# Build new application
# =====================


.PHONY: tag-build
tag-build: ## DEV   : Build a prod version with a timestamped tag
	@export TIMESTAMP=build_`date +"%G-%m-%d_%Hh%M"`; \
	echo TAG = $$TIMESTAMP; \
	git tag $$TIMESTAMP; \
	git push origin $$TIMESTAMP;

# ===============
# Deployment tags
# ===============

.PHONY: tag-deploy
tag-deploy: ## DEV   : Set tag to current HEAD to deploy in production
	@export TIMESTAMP=deploy_`date +"%G-%m-%d_%Hh%M"`; \
	echo TAG = $$TIMESTAMP; \
	git tag $$TIMESTAMP; \
	git push origin $$TIMESTAMP;
