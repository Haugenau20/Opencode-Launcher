FROM docker.io/library/python:3.12-alpine
RUN apk add --no-cache socat su-exec
COPY entrypoint.sh app.py proxy.py origin.py /fixture/
RUN chmod +x /fixture/entrypoint.sh
USER root
ENTRYPOINT ["/fixture/entrypoint.sh"]
