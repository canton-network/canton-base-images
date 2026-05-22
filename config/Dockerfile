FROM scratch

# Build arguments for labels
ARG BUILD_DATE
ARG VERSION
ARG VCS_REF
ARG VCS_URL
ARG VARIANT
ARG TARGETARCH

# Standard OCI labels (https://github.com/opencontainers/image-spec/blob/main/annotations.md)
LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.authors="Digital Asset LLC" \
      org.opencontainers.image.url="${VCS_URL}" \
      org.opencontainers.image.documentation="${VCS_URL}/blob/main/README" \
      org.opencontainers.image.source="${VCS_URL}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.vendor="Digital Asset LLC" \
      org.opencontainers.image.title="DA Base Image" \
      org.opencontainers.image.description="Digital Asset Base Image" \
      org.opencontainers.image.base.name="scratch"

# Custom labels for variant info (always applicable)
LABEL io.digitalasset.image.variant="${VARIANT}" \
      io.digitalasset.image.architecture="${TARGETARCH}"

ENV PATH=/usr/bin:/bin:/usr/java/bin
ENV JAVA_HOME=/usr/java
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# To use a specific variant, change the COPY line below to:
# COPY --chown=root:root rootfs_minimal_$TARGETARCH /
# COPY --chown=root:root rootfs_base_$TARGETARCH /
# COPY --chown=root:root rootfs_jdk_$TARGETARCH /
# COPY --chown=root:root rootfs_full_$TARGETARCH /
# See config/variants.md for details on each variant
COPY --chown=root:root rootfs_jdk_$TARGETARCH /
COPY --chown=1001:1001 config/profile /home/nonroot
COPY --chown=1001:1001 empty /app
WORKDIR /home/nonroot
USER nonroot:nonroot
CMD [ "/bin/bash" ]
