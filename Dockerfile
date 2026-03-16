FROM ruby:3.3

RUN apt-get update -y
RUN apt-get install -y wget curl zip unzip apt-transport-https ca-certificates gnupg lsb-release 

WORKDIR /scripts
COPY scripts/ .

RUN gem install redis pg
