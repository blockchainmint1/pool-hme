# Builds texitcoind from source. Two-stage so the final image stays small.
# Override the git ref at build time:
#   docker build --build-arg GIT_REF=v0.21.x ./texitcoind

ARG GIT_REF=master

FROM debian:bookworm-slim AS build
ARG GIT_REF
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential autoconf automake libtool pkg-config bsdmainutils \
      python3 ca-certificates curl \
      libssl-dev libevent-dev libboost-all-dev libsqlite3-dev \
      libzmq3-dev libdb-dev libdb++-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "${GIT_REF}" https://github.com/texitcoin/texitcoin.git . \
 || git clone https://github.com/texitcoin/texitcoin.git . && git checkout "${GIT_REF}"

# Standard autotools build. Disable wallet+GUI; we only need the node + RPC.
RUN ./autogen.sh \
 && ./configure --disable-tests --disable-bench --disable-gui-tests \
                --without-gui --with-incompatible-bdb \
 && make -j"$(nproc)" \
 && strip src/texitcoind src/texitcoin-cli

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      libssl3 libevent-2.1-7 libevent-pthreads-2.1-7 \
      libboost-system1.74.0 libboost-filesystem1.74.0 libboost-thread1.74.0 \
      libsqlite3-0 libzmq5 libdb5.3++ ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /bin/bash txc

COPY --from=build /src/src/texitcoind /usr/local/bin/texitcoind
COPY --from=build /src/src/texitcoin-cli /usr/local/bin/texitcoin-cli

USER txc
WORKDIR /home/txc
EXPOSE 8332 8333

CMD ["texitcoind", "-printtoconsole", "-conf=/home/txc/.texitcoin/texitcoin.conf"]
