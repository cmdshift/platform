FROM docker.io/library/busybox:1.37.0

COPY --chown=65534:65534 www /var/www
COPY --chmod=755 --chown=65534:65534 entrypoint.sh /usr/local/bin/

USER 65534

EXPOSE 3000

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
