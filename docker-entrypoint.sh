#!/bin/sh


if [ "$DEV_BUILD" = "true" ]; then
  sudo /usr/sbin/update-ca-certificates
fi

COMMAND=$@

if [ "x$COMMAND" = "x" ]; then
  exec /tini -g -- bin/startup
fi

exec "$@"
