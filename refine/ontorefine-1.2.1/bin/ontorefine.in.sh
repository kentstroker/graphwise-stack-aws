#!/bin/bash

# We use an array so spaces will be preserved and passed on correctly
JAVA_OPTS_ARRAY=()

JAVA_OPTS_ARRAY+=("${JAVA_VERSION_OPTS[@]}")

# Permit "illegal" access to support older libraries. This works in Java 11-16 but not 17+
if [ "$JAVA_VERSION" -lt 17 ]; then
  JAVA_OPTS_ARRAY+=("--illegal-access=warn")
fi

# If ONTOREFINE_HEAP_SIZE is provided it will override ONTOREFINE_MIN_MEM and ONTOREFINE_MAX_MEM
if [ "x$ONTOREFINE_HEAP_SIZE" != "x" ]; then
    ONTOREFINE_MIN_MEM=$ONTOREFINE_HEAP_SIZE
    ONTOREFINE_MAX_MEM=$ONTOREFINE_HEAP_SIZE
fi

# Use ONTOREFINE_MIN_MEM and ONTOREFINE_MAX_MEM to set -Xms and -Xmx if they have values
if [ "x$ONTOREFINE_MIN_MEM" != "x" ]; then
    JAVA_OPTS_ARRAY+=("-Xms${ONTOREFINE_MIN_MEM}")
else
    # an absolute default for minimum heap size, this helps with 32-bit "client" java
    JAVA_OPTS_ARRAY+=("-Xms1g")
fi
if [ "x$ONTOREFINE_MAX_MEM" != "x" ]; then
    JAVA_OPTS_ARRAY+=("-Xmx${ONTOREFINE_MAX_MEM}")
fi

# Use ONTOREFINE_HEAP_NEWSIZE for -Xmn if it has values
if [ "x$ONTOREFINE_HEAP_NEWSIZE" != "x" ]; then
    JAVA_OPTS_ARRAY+=("-Xmn${ONTOREFINE_HEAP_NEWSIZE}")
fi

# Set to headless, just in case
JAVA_OPTS_ARRAY+=("-Djava.awt.headless=true")

# Ensure UTF-8 encoding by default (e.g. filenames)
JAVA_OPTS_ARRAY+=("-Dfile.encoding=UTF-8")

# Set explicit garbage collector only on Java less than 9
if [ "$JAVA_VERSION" -lt 9 ]; then
    # Default garbage collector
    JAVA_OPTS_ARRAY+=("-XX:+UseParallelGC")

    # Alternative garbage collector (comment the above and uncomment this)
    #JAVA_OPTS_ARRAY+=("-XX:+UseConcMarkSweepGC")
fi

# Don't omit stack traces when the JVM recompiles on the fly and swaps with precompiled exceptions
JAVA_OPTS_ARRAY+=("-XX:-OmitStackTraceInFastThrow")

# Exit immediately on out of memory error (but a heap dump will still be done if configured)
JAVA_OPTS_ARRAY+=("-XX:OnOutOfMemoryError=kill -9 %p")

# Garbage collect logs, set ONTOREFINE_GC_LOG to true to enable
if [ "$ONTOREFINE_GC_LOG" = "true" ]; then
    if [ "x$ONTOREFINE_GC_LOG_FILE" = "x" ]; then
        ONTOREFINE_GC_LOG_FILE="$ONTOREFINE_DIST/gc-%p.log"
    fi

    # Print current heap distributions - before and after GC
    JAVA_OPTS_ARRAY+=("-XX:+PrintGCDetails")
    # Don't use timestamps but dates instead
    JAVA_OPTS_ARRAY+=("-XX:+PrintGCDateStamps")
    # Print Tunering distribution so we can spot resizing
    JAVA_OPTS_ARRAY+=("-XX:+PrintTenuringDistribution")
    # Logs rotation options
    JAVA_OPTS_ARRAY+=("-XX:+UseGCLogFileRotation")
    JAVA_OPTS_ARRAY+=("-XX:GCLogFileSize=2M")
    JAVA_OPTS_ARRAY+=("-XX:NumberOfGCLogFiles=5")
    JAVA_OPTS_ARRAY+=("-Xloggc:$ONTOREFINE_GC_LOG_FILE")
fi
