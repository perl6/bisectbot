FROM jjmerelo/alpine-perl6:latest
LABEL version="1.0" maintainer="Perl6"

RUN mkdir /app
WORKDIR /app

ADD . /app
RUN git submodule update --init --recursive
RUN apk add --update --no-cache zstd libssl1.0 build-base
RUN ln -s /lib/libssl.so.1.0.0 /lib/libssl.so \
    && ln -s /usr/lib/libssl.so.1.0.0 /usr/lib/libssl.so

RUN zef install --force --deps-only . && rakudobrew rehash
    

FROM andyceo/lrzip as lrzip
COPY --from=lrzip /usr/local/bin/lrzip /usr/local/bin/lrzip
