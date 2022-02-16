FROM mcr.microsoft.com/powershell:centos-7

RUN dnf upgrade --refresh -y

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
