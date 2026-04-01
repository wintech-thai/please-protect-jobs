FROM ruby:3.3

RUN apt-get update -y
RUN apt-get install -y wget curl zip unzip apt-transport-https ca-certificates gnupg lsb-release 

# Install kubectl
RUN curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
RUN chmod +x kubectl
RUN mv kubectl /usr/local/bin

WORKDIR /scripts
COPY scripts/ .

RUN gem install redis pg
