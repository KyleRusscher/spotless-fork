#!/usr/bin/env bash
set -euo pipefail


# Usage:
#   enter passphrase: kms secret view urn:li:kmsSecret:9bee5c71-397e-495f-8be9-d9f527180553
#   KEY=... PASSPHRASE=... VERSION=8.0.0-SNAPSHOT PREV_VERSION=7.0.0 ./createZip.sh
# Defaults (override via env):
KEY=${KEY:-F1118FE9FE02929D2C79CF16AB9C5855AB7411DF}
PASSPHRASE=${PASSPHRASE:-''}
NAMESPACE_PATH=io/github/kylerusscher
UPLOAD_DIR=/Users/krussche/dev/mvn_upload
WORKDIR=$(cd "$(dirname "$0")" && pwd)

# Always build as a release
GRADLE_RELEASE_FLAG=-Prelease=true
if [[ -z "${VERSION:-}" ]]; then
  VERSION=$(cd "$WORKDIR" && ./gradlew --no-daemon $GRADLE_RELEASE_FLAG :plugin-gradle:properties | awk '/^version:/ {print $2; exit}')
fi
PREV_VERSION=${PREV_VERSION:-${VERSION}}

echo "Using VERSION=$VERSION PREV_VERSION=$PREV_VERSION"

# Ensure artifacts are assembled and POMs are generated (no publish/sign)
cd "$WORKDIR"
./gradlew --no-daemon $GRADLE_RELEASE_FLAG \
  :lib:assemble :lib:sourcesJar :lib:javadocJar :lib:generatePomFileForPluginMavenPublication \
  :lib-extra:assemble :lib-extra:sourcesJar :lib-extra:javadocJar :lib-extra:generatePomFileForPluginMavenPublication \
  :plugin-gradle:assemble :plugin-gradle:sourcesJar :plugin-gradle:javadocJar :plugin-gradle:generatePomFileForPluginMavenPublication \
  -x test

STAGE=/tmp/spotless-central-bundle-${VERSION}-lower
rm -rf "$STAGE"
# ArtifactIds (must match POM coordinates)
ART_LIB=spotless-lib-gagarin
ART_LIB_EXTRA=spotless-lib-extra-gagarin
ART_PLUGIN=spotless-plugin-gradle-gagarin

mkdir -p \
  "$STAGE/$NAMESPACE_PATH/$ART_LIB/$VERSION" \
  "$STAGE/$NAMESPACE_PATH/$ART_LIB_EXTRA/$VERSION" \
  "$STAGE/$NAMESPACE_PATH/$ART_PLUGIN/$VERSION"

copy_artifacts() {
  local artifact=$1
  local module_dir=$2
  local dest_dir=$3
  # Copy POM from build/publications and jars from build/libs, rename to artifactId-based names
  local pubs_dir="$WORKDIR/$module_dir/build/publications/pluginMaven"
  local libs_dir="$WORKDIR/$module_dir/build/libs"
  if [[ -f "$pubs_dir/pom-default.xml" ]]; then
    cp -f "$pubs_dir/pom-default.xml" "$dest_dir/$artifact-$VERSION.pom"
    # Update only the top-level project version without touching dependency versions
    python3 - "$dest_dir/$artifact-$VERSION.pom" "$VERSION" <<'PY'
import sys, xml.etree.ElementTree as ET
pom_path, new_version = sys.argv[1], sys.argv[2]
ET.register_namespace('', 'http://maven.apache.org/POM/4.0.0')
ns = {'m': 'http://maven.apache.org/POM/4.0.0'}
tree = ET.parse(pom_path)
root = tree.getroot()
ver = root.find('m:version', ns)
if ver is None:
    aid = root.find('m:artifactId', ns)
    elem = ET.Element('{http://maven.apache.org/POM/4.0.0}version')
    elem.text = new_version
    if aid is not None:
        idx = list(root).index(aid)
        root.insert(idx + 1, elem)
    else:
        root.insert(0, elem)
else:
    ver.text = new_version
tree.write(pom_path, encoding='utf-8', xml_declaration=True)
PY

    # If this is the Gradle plugin module, ensure the POM declares dependencies on our lib artifacts
    if [[ "$module_dir" == "plugin-gradle" ]]; then
      python3 - <<PY
import xml.etree.ElementTree as ET
from pathlib import Path

pom_path = Path("$dest_dir/$artifact-$VERSION.pom")
group_id = "io.github.kylerusscher"
libs = [
    (group_id, "spotless-lib-gagarin", "$VERSION"),
    (group_id, "spotless-lib-extra-gagarin", "$VERSION"),
]
ET.register_namespace('', 'http://maven.apache.org/POM/4.0.0')
ns = {'m': 'http://maven.apache.org/POM/4.0.0'}
tree = ET.parse(pom_path)
root = tree.getroot()

deps = root.find('m:dependencies', ns)
if deps is None:
    deps = ET.SubElement(root, '{http://maven.apache.org/POM/4.0.0}dependencies')

def ensure_dep_with_version(g, a, v):
    # Try to find existing dependency and update its version
    for d in deps.findall('m:dependency', ns):
        gid = d.find('m:groupId', ns)
        aid = d.find('m:artifactId', ns)
        if gid is not None and aid is not None and gid.text == g and aid.text == a:
            ver = d.find('m:version', ns)
            if ver is None:
                ver = ET.SubElement(d, '{http://maven.apache.org/POM/4.0.0}version')
            ver.text = v
            return
    # Otherwise add a new dependency entry
    d = ET.SubElement(deps, '{http://maven.apache.org/POM/4.0.0}dependency')
    gid = ET.SubElement(d, '{http://maven.apache.org/POM/4.0.0}groupId'); gid.text = g
    aid = ET.SubElement(d, '{http://maven.apache.org/POM/4.0.0}artifactId'); aid.text = a
    ver = ET.SubElement(d, '{http://maven.apache.org/POM/4.0.0}version'); ver.text = v
    scope = ET.SubElement(d, '{http://maven.apache.org/POM/4.0.0}scope'); scope.text = 'compile'

for g, a, v in libs:
    ensure_dep_with_version(g, a, v)

tree.write(pom_path, encoding='utf-8', xml_declaration=True)
PY
    fi

    # If this is the lib-extra module, ensure dependency on spotless-lib-gagarin uses the bundle version
    if [[ "$module_dir" == "lib-extra" ]]; then
      python3 - <<PY
import xml.etree.ElementTree as ET
from pathlib import Path

pom_path = Path("$dest_dir/$artifact-$VERSION.pom")
ET.register_namespace('', 'http://maven.apache.org/POM/4.0.0')
ns = {'m': 'http://maven.apache.org/POM/4.0.0'}
tree = ET.parse(pom_path)
root = tree.getroot()

deps = root.find('m:dependencies', ns)
if deps is not None:
    for d in deps.findall('m:dependency', ns):
        gid = d.find('m:groupId', ns)
        aid = d.find('m:artifactId', ns)
        if gid is not None and aid is not None and gid.text == 'io.github.kylerusscher' and aid.text == 'spotless-lib-gagarin':
            ver = d.find('m:version', ns)
            if ver is None:
                ver = ET.SubElement(d, '{http://maven.apache.org/POM/4.0.0}version')
            ver.text = '$VERSION'
            break

tree.write(pom_path, encoding='utf-8', xml_declaration=True)
PY
    fi
  fi
  # Main jar: if exact versioned jar not found, pick the first non-sources/non-javadoc jar and rename
  if [[ -f "$libs_dir/${module_dir##*/}-$VERSION.jar" ]]; then
    cp -f "$libs_dir/${module_dir##*/}-$VERSION.jar" "$dest_dir/$artifact-$VERSION.jar"
  else
    cand=$(ls -1 "$libs_dir"/*.jar 2>/dev/null | grep -v '\-sources\.jar$' | grep -v '\-javadoc\.jar$' | head -n 1 || true)
    if [[ -n "${cand:-}" && -f "$cand" ]]; then
      cp -f "$cand" "$dest_dir/$artifact-$VERSION.jar"
    fi
  fi
  if [[ -f "$libs_dir/${module_dir##*/}-$VERSION-sources.jar" ]]; then
    cp -f "$libs_dir/${module_dir##*/}-$VERSION-sources.jar" "$dest_dir/$artifact-$VERSION-sources.jar"
  else
    cand_src=$(ls -1 "$libs_dir"/*-sources.jar 2>/dev/null | head -n 1 || true)
    if [[ -n "${cand_src:-}" && -f "$cand_src" ]]; then
      cp -f "$cand_src" "$dest_dir/$artifact-$VERSION-sources.jar"
    fi
  fi
  if [[ -f "$libs_dir/${module_dir##*/}-$VERSION-javadoc.jar" ]]; then
    cp -f "$libs_dir/${module_dir##*/}-$VERSION-javadoc.jar" "$dest_dir/$artifact-$VERSION-javadoc.jar"
  else
    cand_jav=$(ls -1 "$libs_dir"/*-javadoc.jar 2>/dev/null | head -n 1 || true)
    if [[ -n "${cand_jav:-}" && -f "$cand_jav" ]]; then
      cp -f "$cand_jav" "$dest_dir/$artifact-$VERSION-javadoc.jar"
    fi
  fi
}

copy_artifacts "$ART_LIB" lib "$STAGE/$NAMESPACE_PATH/$ART_LIB/$VERSION"
copy_artifacts "$ART_LIB_EXTRA" lib-extra "$STAGE/$NAMESPACE_PATH/$ART_LIB_EXTRA/$VERSION"
copy_artifacts "$ART_PLUGIN" plugin-gradle "$STAGE/$NAMESPACE_PATH/$ART_PLUGIN/$VERSION"

sign_and_checksum() {
  local dir=$1
  for f in "$dir"/*.pom "$dir"/*.jar; do
    [[ -f "$f" ]] || continue
    gpg --batch --yes --pinentry-mode loopback --passphrase "$PASSPHRASE" --armor --detach-sign --local-user "$KEY" "$f"
    md5 -q "$f" > "$f.md5"; shasum -a 1 "$f" | awk '{print $1}' > "$f.sha1"
    md5 -q "$f.asc" > "$f.asc.md5"; shasum -a 1 "$f.asc" | awk '{print $1}' > "$f.asc.sha1"
  done
}

sign_and_checksum "$STAGE/$NAMESPACE_PATH/$ART_LIB/$VERSION"
sign_and_checksum "$STAGE/$NAMESPACE_PATH/$ART_LIB_EXTRA/$VERSION"
sign_and_checksum "$STAGE/$NAMESPACE_PATH/$ART_PLUGIN/$VERSION"

ZIP_OUT="/tmp/spotless-central-upload-${VERSION}-lower.zip"
( cd "$STAGE" && zip -r "$ZIP_OUT" io >/dev/null )
mkdir -p "$UPLOAD_DIR"
mv -f "$ZIP_OUT" "$UPLOAD_DIR/"
echo "Created: $UPLOAD_DIR/$(basename "$ZIP_OUT")"


