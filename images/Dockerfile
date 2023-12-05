FROM registry.access.redhat.com/ubi9/ubi

ARG PS_VERSION=7.4.0
ARG PACKAGE_VERSION=7.4.0
ARG PS_PACKAGE=powershell-${PACKAGE_VERSION}-1.rh.x86_64.rpm
ARG PS_PACKAGE_URL=https://github.com/PowerShell/PowerShell/releases/download/v${PS_VERSION}/${PS_PACKAGE}

RUN curl -sSL ${PS_PACKAGE_URL} -o /tmp/linux.rpm
RUN dnf install -y \
      less \
      ncurses \
      openssh-clients \
      openssl \
      glibc-locale-source \
      glibc-langpack-en \
      libicu && \
    dnf upgrade --refresh -y && \
    dnf localinstall -y /tmp/linux.rpm

ENV TERM=xterm
ENV HOME=/home/user

RUN mkdir /projects ${HOME} && \
    for f in "${HOME}" "/etc/passwd" "/projects"; do \
      echo "Changing permissions on ${f}" && chgrp -R 0 ${f} && \
      chmod -R g+rwX ${f}; \
    done

ADD scripts/* /projects/
ADD entrypoint.sh /

RUN export POWERSHELL_TELEMETRY_OPTOUT=1 && \
	pwsh -NoLogo -NoProfile -Command " \
          \$ErrorActionPreference = 'Stop' ; \
          \$ProgressPreference = 'SilentlyContinue' ; \
          Set-PSRepository -Name PSGallery -InstallationPolicy Trusted ; \
          Install-Module -Scope AllUsers VMware.PowerCLI ; \
          Set-PowerCLIConfiguration -Scope AllUsers -ParticipateInCeip:\$false -Confirm:\$false"

RUN for f in "${HOME}"; do \
      echo "Changing permissions on ${f}" && chgrp -R 0 ${f} && \
      chmod -R g+rwX ${f}; \
    done

WORKDIR /projects
ENTRYPOINT ["/entrypoint.sh"]
