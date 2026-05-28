#!/bin/bash

SCRIPT="$0"

# SCRIPT may be an arbitrarily deep series of symlinks. Loop until we have the concrete path.
while [ -h "$SCRIPT" ] ; do
  ls=`ls -ld "$SCRIPT"`
  # Drop everything prior to ->
  link=`expr "$ls" : '.*-> \(.*\)$'`
  if expr "$link" : '/.*' > /dev/null; then
    SCRIPT="$link"
  else
    SCRIPT=`dirname "$SCRIPT"`/"$link"
  fi
done

# OntoRefine dist directory. Note that if someone has moved the script manually, this would not work
ONTOREFINE_DIST=`dirname "$SCRIPT"`/..

# make ONTOREFINE_DIST absolute
ONTOREFINE_DIST=`cd "$ONTOREFINE_DIST"; pwd`

if [ -d "$ONTOREFINE_DIST/../runtime" ]; then
    # Our bundled JDK
    JAVA="$ONTOREFINE_DIST/../runtime/bin/java"

    # For MacOS we need to dig deeper then just 'runtime/'
    if [ ! -f "$JAVA" ]; then
        JAVA="$ONTOREFINE_DIST/../runtime/Contents/Home/bin/java"
    fi
elif [ ! -z "$JAVA_HOME" ]; then
    JAVA="$JAVA_HOME/bin/java"
else
    JAVA=`which java`
fi

if [ ! -f "$JAVA" ]; then
   echo "Could not find Java binary. Please install Java in your PATH or set JAVA_HOME"
   exit 1
fi

ONTOREFINE_CLASSPATH="$ONTOREFINE_DIST/lib/*"

# Supported Java versions
SUPPORTED_JAVA_VERSIONS=(11 16)

function get_supported_java_versions_human {
  local num_java_versions=${#SUPPORTED_JAVA_VERSIONS[@]}

  for ((i=0; i<$num_java_versions; i++)); do
    echo -n ${SUPPORTED_JAVA_VERSIONS[$i]}
    if [[ $i -lt $(($num_java_versions-2)) ]]; then
      echo -n ", "
    elif [[ $i -lt $(($num_java_versions-1)) ]]; then
        echo -n " or "
    fi
  done
  echo
}

set -o pipefail
JAVA_VERSION=$("$JAVA" -version 2>&1 | awk 'sub(/^[^"]+"|"[^"]+$/, "") && gsub(/^1\.|\..+|".+/, "")')
if [ $? -eq 126 ]; then
    echo "Found Java binary in $JAVA but it's not executable, check your Java installation"
    exit 1
fi
if [ ! $? -eq 0 -o -z "$JAVA_VERSION" ]; then
    echo "Unable to determine Java version, check that $JAVA is actually a Java binary"
    exit 1
fi
set +o pipefail

if [[ ! " ${SUPPORTED_JAVA_VERSIONS[*]} " =~ " $JAVA_VERSION " ]]; then
    echo "This Ontotext Refine distribution requires Java $(get_supported_java_versions_human) but you have Java $JAVA_VERSION"
    echo "Execution will continue in 5 seconds"
    sleep 5
fi

# Array of Java version-specific options to be used for both tools and GDB
JAVA_VERSION_OPTS=()

# Include Java exports for Java 9+
if [ "$JAVA_VERSION" -ge 9 ]; then
	JAVA_VERSION_OPTS+=(--add-exports jdk.management.agent/jdk.internal.agent=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED)
fi

# By default the -XX:MaxDirectMemorySize is limited to the heap size
if [ "$ONTOREFINE_JAVA_32BIT" != "true" ]; then
	JAVA_VERSION_OPTS+=("-XX:MaxDirectMemorySize=128G")
fi

source "`dirname "$0"`/ontorefine.in.sh"

call_java() {
    "$JAVA" "${JAVA_OPTS_ARRAY[@]}" $ONTOREFINE_JAVA_OPTS -Dontorefine.dist="$ONTOREFINE_DIST" -cp "$ONTOREFINE_CLASSPATH" "$@"
}


