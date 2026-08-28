FROM index.docker.io/rustfs/rc:v0.1.31 AS rc

FROM index.docker.io/rustfs/rustfs:1.0.0-rc.2

COPY --from=rc /usr/bin/rc /usr/bin/rc
