# Ontotext Refine container — arm64-compatible wrapper around the
# platform-independent Java distribution.
#
# Background: ontotext/refine:1.2.x on Docker Hub is a single-platform
# amd64 image (manifest.v2, no manifest-list / OCI index). On AL2023
# Graviton (arm64) the pod CrashLoopBackOffs immediately with
# `exec /opt/ontorefine/dist/bin/ontorefine: exec format error`.
#
# Refine itself is a pure Java application -- 180 JARs in lib/, no
# native binaries. The vendor's platform-independent zip ships with a
# bash launcher that just `exec`s java with the right classpath. So
# the right move is "stop using the broken docker image, run the Java
# dist on a base that has an arm64 JRE."
#
# Java version: Refine 1.2.1's bin/setvars.in.sh declares
# SUPPORTED_JAVA_VERSIONS=(11 16) and trips a 5-second warning on
# anything else. ontorefine.in.sh uses `--illegal-access=warn` which
# was removed in Java 17. So 11 is the safe pick. eclipse-temurin:11-jre
# is multi-arch (linux/amd64, linux/arm64, linux/arm/v7) so this same
# Dockerfile produces a working image on either CPU family without
# `--platform` shenanigans.
#
# Distribution: refine/ontorefine-1.2.1/ is operator-supplied (gitignored,
# treated like a license file). scripts/build-refine-image.sh expects it
# to exist before running; cluster-bootstrap.sh skips the build cleanly
# if the directory is absent.

FROM eclipse-temurin:11-jre

ENV ONTOREFINE_DIST=/opt/ontorefine \
    ONTOREFINE_HEAP_SIZE=2g \
    JAVA_HOME=/opt/java/openjdk

# Copy the platform-independent distribution in. Path is relative to
# the build context (the repo root); scripts/build-refine-image.sh
# runs the build with the repo root as the context so this resolves
# to graphwise-stack-aws/refine/ontorefine-1.2.1/.
COPY refine/ontorefine-1.2.1/ ${ONTOREFINE_DIST}/

# Run as non-root. Refine writes project state under /opt/ontorefine/data
# (mounted from a PVC by the chart) -- ownership has to land on the
# runtime UID so the JVM can write.
RUN useradd --system --uid 1001 --gid 0 --home-dir ${ONTOREFINE_DIST} ontorefine \
 && mkdir -p ${ONTOREFINE_DIST}/data \
 && chown -R 1001:0 ${ONTOREFINE_DIST} \
 && chmod -R g=u ${ONTOREFINE_DIST} \
 && chmod +x ${ONTOREFINE_DIST}/bin/ontorefine

USER 1001
WORKDIR ${ONTOREFINE_DIST}
EXPOSE 7333

# The bash launcher exec's java with the right classpath. It honours
# ONTOREFINE_HEAP_SIZE / ONTOREFINE_MAX_MEM / ONTOREFINE_JAVA_OPTS
# so chart values can tune heap without rebuilding the image.
ENTRYPOINT ["/opt/ontorefine/bin/ontorefine"]
