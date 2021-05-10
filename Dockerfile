FROM ubuntu:18.04

# Install prerequisites
RUN apt-get update && apt-get install -y \
curl openssl npm nodejs gcc iputils-ping iputils-ping net-tools jq curl iproute2

RUN curl -sL https://deb.nodesource.com/setup_10.x  | bash -
RUN apt-get -y install nodejs

RUN mkdir -p /usr/src/node-red
RUN mkdir /data
RUN mkdir /ieam

WORKDIR /usr/src/node-red

RUN adduser -u 1000 --gecos "" --disabled-password --home /usr/src/node-red node-red \
    && chown -R node-red:node-red /data \
    && chown -R node-red:node-red /usr/src/node-red

# package.json contains Node-RED NPM module and node dependencies
COPY package.json /usr/src/node-red

#RUN npm install -g --unsafe-perm node-red
#RUN snap install node-red
RUN npm install -g --unsafe-perm node-red
RUN npm install -g node-red-contrib-opcua@0.2.x
#RUN npm install -g --unsafe-perm node-red-contrib-opcua@0.2.x

# User configuration directory volume
VOLUME ["/data"]
EXPOSE 1880

# Environment variable holding file path for flows configuration
ENV FLOWS=flows.json

COPY my_wrapper.sh /usr/src/node-red

COPY dev.sh /ieam
COPY node-cred.js /ieam
COPY trigger.sh /ieam
COPY deploy.tar /ieam

#USER node-red

#CMD ["npm", "start", "--", "--userDir", "/data"]
#CMD ["node-red", "--userDir", "/data", "flows.json"]
CMD ./my_wrapper.sh
