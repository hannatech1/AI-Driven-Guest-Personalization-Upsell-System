FROM node:22-bookworm-slim


RUN apt-get update && apt-get install -y \
    curl \
    git \
    unzip \
    bash 

RUN npm install -g opencode-ai @salesforce/cli

USER node