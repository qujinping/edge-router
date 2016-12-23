#nginx with embedded lua script
FROM openresty/openresty:1.11.2.2-alpine

RUN apk update && apk add ruby
RUN apk add ruby-json

COPY nginx.conf /etc/nginx/nginx.conf
COPY ./logger.rb /nginx/logger.rb
ENTRYPOINT ["/usr/bin/ruby", "/nginx/logger.rb"]
