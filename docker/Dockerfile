FROM mcr.microsoft.com/azure-cli:latest
RUN tdnf check-update \
    && tdnf --refresh install -y \
         tar jq git \
    && tdnf clean all
RUN az extension add --name azure-devops
RUN /usr/sbin/useradd -m -s /bin/bash devops
USER devops
COPY --chown=devops --chmod=744 src/backup-devops.sh /home/devops
COPY --chown=devops --chmod=744 docker/starter.sh /home/devops
WORKDIR /home/devops
VOLUME ["/data"]
ENTRYPOINT ["/bin/bash", "./starter.sh"]
