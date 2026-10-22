# AzuraCast for Pelican: the official image, flattened (drops its VOLUMEs) and started as
# whatever UID Wings uses. See NOTES.md for why each step is done this way.

ARG UPSTREAM=ghcr.io/azuracast/azuracast:stable

FROM ${UPSTREAM} AS upstream
# The upstream environment, read at start by the entrypoint (ENV can't be copied between
# images, and listing it here by hand would drift from upstream).
RUN export -p | grep -vE '^declare -x (HOME|HOSTNAME|OLDPWD|PWD|SHLVL|_)=' > /etc/upstream.env

FROM scratch
COPY --from=upstream / /
COPY rootfs/ /

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN bash /egg/build.sh && rm /egg/build.sh

# Lets `docker exec` sessions use the server's environment (see rootfs/egg/exec-env.sh).
ENV BASH_ENV=/egg/exec-env.sh

WORKDIR /var/azuracast/www
# The entrypoint starts as PID 1, drops root if it has it, then execs tini (see entrypoint.sh).
ENTRYPOINT ["/egg/entrypoint.sh"]
