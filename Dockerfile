FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y -qq ca-certificates curl git openssh-server python3 procps util-linux coreutils xz-utils tar gzip jq \
 && rm -rf /var/lib/apt/lists/*

# r10 必须在真正的 CloudStudio 运行态执行，才能接入平台 PID 1 supervisord。
# Git 导入后的 workspace.yml lifecycle.init 会执行 install.sh。
WORKDIR /workspace
COPY install.sh cloudstudio-r10.sh /opt/cloudstudio-template/
RUN chmod 0755 /opt/cloudstudio-template/install.sh && chmod 0700 /opt/cloudstudio-template/cloudstudio-r10.sh
