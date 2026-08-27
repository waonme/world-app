FROM nginx:1.31.4@sha256:b34848eff6db786b6b1282d3a9c3fd0b5563dfb6d261df4923378b419e0d24f0
ARG VERSION

COPY web/nginx.conf /etc/nginx/conf.d/default.conf
COPY web/dist /usr/share/nginx/html
RUN echo "{\"name\": \"github.com/concrnt/web-dashboard\", \"version\": \"${VERSION:-unknown}\"}" > /cc-info
