#!/usr/bin/env bash

#  Copyright (c) 2014-present, Facebook, Inc.
#  All rights reserved.
#
#  This source code is licensed under both the Apache 2.0 license (found in the
#  LICENSE file in the root directory of this source tree) and the GPLv2 (found
#  in the COPYING file in the root directory of this source tree).
#  You may select, at your option, one of the above-listed licenses.

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SOURCE_DIR="$SCRIPT_DIR/../.."
BUILD_DIR="$SOURCE_DIR/build/"
if [[ ! -z "$DEBUG" ]]; then
  BUILD_DIR="${BUILD_DIR}debug_"
fi

if [[ "$BUILD_VERSION" == "10.11" ]]; then
  BUILD_DIR="${BUILD_DIR}darwin"
else
  BUILD_DIR="${BUILD_DIR}darwin$BUILD_VERSION"
fi

OSQUERY_DEPS="${OSQUERY_DEPS:-/usr/local/osquery}"

source "$SOURCE_DIR/tools/lib.sh"
distro "darwin" BUILD_VERSION

# Binary identifiers
VERSION=`(cd $SOURCE_DIR; git describe --tags HEAD) || echo 'unknown-version'`
APP_VERSION=${OSQUERY_BUILD_VERSION:="$VERSION"}
APP_IDENTIFIER="com.facebook.osquery"
KERNEL_APP_IDENTIFIER="com.facebook.osquery.kernel"
LD_IDENTIFIER="com.facebook.osqueryd"
LD_IDENTIFIER_UPLOADER="com.centerdevice.osqueryupload"
LD_INSTALL="/Library/LaunchDaemons/$LD_IDENTIFIER.plist"
LD_INSTALL_UPLOADER="/Library/LaunchDaemons/$LD_IDENTIFIER_UPLOADER.plist"
OUTPUT_PKG_PATH="$BUILD_DIR/osquery-$APP_VERSION.pkg"
OUTPUT_DEBUG_PKG_PATH="$BUILD_DIR/osquery-debug-$APP_VERSION.pkg"
KERNEL_OUTPUT_PKG_PATH="$BUILD_DIR/osquery-kernel-${APP_VERSION}.pkg"
SIGNING_IDENTITY="Developer ID Application: CenterDevice GmbH (F253NVK8A9)"
INSTALLER_SIGNING_IDENTITY="Developer ID Installer: CenterDevice GmbH (F253NVK8A9)"
KEYCHAIN_IDENTITY=""
KEYCHAIN_IDENTITY_COMMAND=""
AUTOSTART=false
CLEAN=false

# Config files
LAUNCHD_SRC="$SCRIPT_DIR/$LD_IDENTIFIER.plist"
LAUNCHD_DST="/private/var/osquery/$LD_IDENTIFIER.plist"
LAUNCHD_SRC_UPLOADER="$SCRIPT_DIR/$LD_IDENTIFIER_UPLOADER.plist"
LAUNCHD_DST_UPLOADER="/private/var/osquery/$LD_IDENTIFIER_UPLOADER.plist"
NEWSYSLOG_SRC="$SCRIPT_DIR/$LD_IDENTIFIER.conf"
NEWSYSLOG_DST="/private/var/osquery/$LD_IDENTIFIER.conf"
PACKS_SRC="$SOURCE_DIR/packs"
PACKS_DST="/private/var/osquery/packs/"
LENSES_LICENSE="${OSQUERY_DEPS}/Cellar/augeas/*/COPYING"
LENSES_SRC="${OSQUERY_DEPS}/share/augeas/lenses/dist"
LENSES_DST="/private/var/osquery/lenses/"
OSQUERY_EXAMPLE_CONFIG_SRC="$SCRIPT_DIR/osquery.example.conf"
OSQUERY_EXAMPLE_CONFIG_DST="/private/var/osquery/osquery.example.conf"
OSQUERY_CONFIG_SRC=""
OSQUERY_CONFIG_DST="/private/var/osquery/osquery.conf"
OSQUERY_DB_LOCATION="/private/var/osquery/osquery.db/"
OSQUERY_LOG_DIR="/private/var/log/osquery/"
OSQUERY_TLS_CERT_CHAIN_BUILTIN_SRC="${OSQUERY_DEPS}/etc/openssl/cert.pem"
OSQUERY_TLS_CERT_CHAIN_BUILTIN_DST="/private/var/osquery/certs/certs.pem"
TLS_CERT_CHAIN_DST="/private/var/osquery/tls-server-certs.pem"
FLAGFILE_DST="/private/var/osquery/osquery.flags"
OSQUERY_PKG_INCLUDE_DIRS=()

WORKING_DIR=/tmp/osquery_packaging
INSTALL_PREFIX="$WORKING_DIR/prefix"
DEBUG_PREFIX="$WORKING_DIR/debug"
SCRIPT_ROOT="$WORKING_DIR/scripts"
PREINSTALL="$SCRIPT_ROOT/preinstall"
POSTINSTALL="$SCRIPT_ROOT/postinstall"
OSQUERYCTL_PATH="$SCRIPT_DIR/osqueryctl"

# Kernel extension identifiers and config files
KERNEL_INLINE=false
KERNEL_UNLOAD_SCRIPT="$SOURCE_DIR/kernel/tools/unload_with_retry.sh"
KERNEL_EXTENSION_IDENTIFIER="com.facebook.security.osquery"
KERNEL_EXTENSION_SRC="$BUILD_DIR/kernel/osquery.kext"
KERNEL_EXTENSION_DST="/Library/Extensions/osquery.kext"

KERNEL_WORKING_DIR=/tmp/osquery_kernel_packaging
KERNEL_INSTALL_PREFIX="$KERNEL_WORKING_DIR/prefix"
KERNEL_SCRIPT_ROOT="$KERNEL_WORKING_DIR/scripts"
KERNEL_PREINSTALL="$KERNEL_SCRIPT_ROOT/preinstall"
KERNEL_POSTINSTALL="$KERNEL_SCRIPT_ROOT/postinstall"

SCRIPT_PREFIX_TEXT="#!/usr/bin/env bash

set -e
"

POSTINSTALL_UNLOAD_TEXT="
if launchctl list | grep -qcm1 $LD_IDENTIFIER; then
  launchctl unload $LD_INSTALL
fi
if launchctl list | grep -qcm1 $LD_IDENTIFIER_UPLOADER; then
  launchctl unload $LD_INSTALL_UPLOADER
fi
"

POSTINSTALL_AUTOSTART_TEXT="
cp $LAUNCHD_DST $LD_INSTALL
touch $FLAGFILE_DST
echo "'--pack_delimiter=/'" > $FLAGFILE_DST
cp $LAUNCHD_DST_UPLOADER $LD_INSTALL_UPLOADER
launchctl load $LD_INSTALL
launchctl load $LD_INSTALL_UPLOADER
"

POSTINSTALL_LOGROTATE_TEXT="
cp $NEWSYSLOG_DST /etc/newsyslog.d
"

KERNEL_POSTINSTALL_UNLOAD_TEXT="
./unload_with_retry.sh
"

KERNEL_POSTINSTALL_AUTOSTART_TEXT="
kextload $KERNEL_EXTENSION_DST
"

POSTINSTALL_CLEAN_TEXT="
rm -rf $OSQUERY_DB_LOCATION
"

function usage() {
  fatal "Usage: $0 [-c path/to/your/osquery.conf] [-l path/to/osqueryd.plist]
    -c | --config PATH     embed an osqueryd config.
    -n | --name NAME       friendly name for use in the installer filename, e. g. staging or prod.
    -l | --launchd PATH    override the default launchd plist.
    -t | --cert-chain PATH embed a certificate chain file for TLS server validation.
    -o | --output PATH     override the output path.
    -a | --autostart       start the daemon when the package is installed.
    -x | --clean           force the daemon to start fresh, removing any results previously stored in the database
    -s | --sign            create signed binaries and installer. Needs \"$SIGNING_IDENTITY\"
                           and \"$INSTALLER_SIGNING_IDENTITY\" in the keychain, including their private keys.
    -i | --include-dir     PATH to additional files to be installed.
    --aws-key KEY          Access Key ID for log uploads.
    --aws-secret SECRET    Secret for for log uploads.
    --aws-bucket BUCKET[@REGION] Bucket name for log uploads. Optionally with a region.

  This will generate an OSX package with:
  (1) An example config /var/osquery/osquery.example.config
  (2) An optional config /var/osquery/osquery.config if [-c] is used
  (3) A LaunchDaemon plist /var/osquery/com.facebook.osqueryd.plist
  (4) A default TLS certificate bundle (provided by cURL)
  (5) The osquery toolset /usr/local/bin/osquery*
  (6) A LaunchDaemon plist /var/osquery/com.centerdevice.osqueryupload.plist

  To enable osqueryd to run at boot using Launchd, pass the -a flag.
  This also enables a LaunchDaemon that uploads the logs to S3.
  If the LaunchDaemon was previously installed a newer version of this package
  will reload (unload/load) the daemon."
}

function parse_args() {
  while [ "$1" != "" ]; do
    case $1 in
      -c | --config )         shift
                              OSQUERY_CONFIG_SRC=$1
                              ;;
      -l | --launchd )        shift
                              LAUNCHD_SRC=$1
                              ;;
      -t | --cert-chain )     shift
                              TLS_CERT_CHAIN_SRC=$1
                              ;;
      -i | --include-dir )    shift
                              OSQUERY_PKG_INCLUDE_DIRS[${#OSQUERY_PKG_INCLUDE_DIRS}]=$1
                              ;;
      -n | --name)            shift
                              OUTPUT_PKG_PATH="$BUILD_DIR/osquery-$APP_VERSION-$1.pkg"
                              OUTPUT_DEBUG_PKG_PATH="$BUILD_DIR/osquery-debug-$APP_VERSION-$1.pkg"
                              KERNEL_OUTPUT_PKG_PATH="$BUILD_DIR/osquery-kernel-${APP_VERSION}-$1.pkg"
                              ;;
      -o | --output )         shift
                              OUTPUT_PKG_PATH=$1
                              ;;
      -s | --sign )           SIGN=1
                              ;;
      -k | --keychain )       shift
                              KEYCHAIN_IDENTITY=$1
                              KEYCHAIN_IDENTITY_COMMAND="--keychain "$1
                              ;;
      -a | --autostart )      AUTOSTART=true
                              ;;
      -x | --clean )          CLEAN=true
                              ;;

      --aws-key )             shift
                              AWS_KEY=$1
                              ;;

      --aws-secret )          shift
                              AWS_SECRET=$1
                              ;;

      --aws-bucket )          shift
                              AWS_BUCKET=$1
                              ;;

      -h | --help )           usage
                              ;;
      * )                     usage
    esac
    shift
  done
}

function check_parsed_args() {
  if [[ $OSQUERY_CONFIG_SRC = "" ]]; then
    log "notice: no config source specified"
  else
    log "using $OSQUERY_CONFIG_SRC as the config source"
  fi

  log "using $LAUNCHD_SRC as the launchd source"

  if [ "$OSQUERY_CONFIG_SRC" != "" ] && [ ! -f $OSQUERY_CONFIG_SRC ]; then
    log "$OSQUERY_CONFIG_SRC is not a file."
    usage
  fi

  if [[ -z "${AWS_KEY}" || -z "${AWS_SECRET}" || -z "{$AWS_BUCKET}" ]]; then
    log "Missing one or more AWS parameters."
    usage
  fi
}

function main() {
  parse_args $@
  check_parsed_args

  platform OS
  if [[ ! "$OS" = "darwin" ]]; then
    fatal "This script must be run on macOS"
  fi

  rm -rf $WORKING_DIR
  rm -f $OUTPUT_PKG_PATH
  mkdir -p $INSTALL_PREFIX
  mkdir -p $SCRIPT_ROOT
  # we don't need the preinstall for anything so let's skip it until we do
  # echo "$SCRIPT_PREFIX_TEXT" > $PREINSTALL
  # chmod +x $PREINSTALL

  log "copying osquery binaries"
  BINARY_INSTALL_DIR="$INSTALL_PREFIX/usr/local/bin/"
  mkdir -p $BINARY_INSTALL_DIR
  cp "$BUILD_DIR/osquery/osqueryd" $BINARY_INSTALL_DIR
  ln -s osqueryd $BINARY_INSTALL_DIR/osqueryi
  strip $BINARY_INSTALL_DIR/*
  cp "$OSQUERYCTL_PATH" $BINARY_INSTALL_DIR

  if [[ "$SIGN" = "1" ]]; then
    log "signing release binaries"
    codesign -s "$SIGNING_IDENTITY" --keychain \"$KEYCHAIN_IDENTITY\" $BINARY_INSTALL_DIR/osqueryd
  fi

  BINARY_DEBUG_DIR="$DEBUG_PREFIX/private/var/osquery/debug"
  mkdir -p "$BINARY_DEBUG_DIR"
  cp "$BUILD_DIR/osquery/osqueryd" $BINARY_DEBUG_DIR/osqueryd.debug
  ln -s osqueryd.debug $BINARY_DEBUG_DIR/osqueryi.debug

  # Create the prefix log dir and copy source configs.
  mkdir -p $INSTALL_PREFIX/$OSQUERY_LOG_DIR
  mkdir -p `dirname $INSTALL_PREFIX$OSQUERY_CONFIG_DST`
  if [[ "$OSQUERY_CONFIG_SRC" != "" ]]; then
    cp $OSQUERY_CONFIG_SRC $INSTALL_PREFIX$OSQUERY_CONFIG_DST
  fi

  # Move configurations into the packaging root.
  log "copying osquery configurations"
  mkdir -p `dirname $INSTALL_PREFIX$LAUNCHD_DST`
  mkdir -p $INSTALL_PREFIX$PACKS_DST
  mkdir -p $INSTALL_PREFIX$LENSES_DST
  cp $LAUNCHD_SRC $INSTALL_PREFIX$LAUNCHD_DST
  cp $NEWSYSLOG_SRC $INSTALL_PREFIX$NEWSYSLOG_DST
  cp $OSQUERY_EXAMPLE_CONFIG_SRC $INSTALL_PREFIX$OSQUERY_EXAMPLE_CONFIG_DST
  cp $PACKS_SRC/* $INSTALL_PREFIX$PACKS_DST
  cp $LENSES_LICENSE $INSTALL_PREFIX/$LENSES_DST
  cp $LENSES_SRC/*.aug $INSTALL_PREFIX$LENSES_DST
  if [[ "$TLS_CERT_CHAIN_SRC" != "" && -f "$TLS_CERT_CHAIN_SRC" ]]; then
    cp $TLS_CERT_CHAIN_SRC $INSTALL_PREFIX$TLS_CERT_CHAIN_DST
  fi

  if [[ $OSQUERY_TLS_CERT_CHAIN_BUILTIN_SRC != "" ]] && [[ -f $OSQUERY_TLS_CERT_CHAIN_BUILTIN_SRC ]]; then
    mkdir -p `dirname $INSTALL_PREFIX/$OSQUERY_TLS_CERT_CHAIN_BUILTIN_DST`
    cp $OSQUERY_TLS_CERT_CHAIN_BUILTIN_SRC $INSTALL_PREFIX/$OSQUERY_TLS_CERT_CHAIN_BUILTIN_DST
  fi

  sed "s/AWS_KEY_PLACEHOLDER/${AWS_KEY}/g; s/AWS_SECRET_PLACEHOLDER/${AWS_SECRET}/g; s/AWS_BUCKET_PLACEHOLDER/${AWS_BUCKET}/g" $LAUNCHD_SRC_UPLOADER > $INSTALL_PREFIX$LAUNCHD_DST_UPLOADER

  # Move/install pre/post install scripts within the packaging root.
  log "finalizing preinstall and postinstall scripts"
  if [ $AUTOSTART == true ]  || [ $CLEAN == true ]; then
    echo "$SCRIPT_PREFIX_TEXT" > $POSTINSTALL
    chmod +x $POSTINSTALL
    if [ $CLEAN == true ]; then
        echo "$POSTINSTALL_CLEAN_TEXT" >> $POSTINSTALL
    fi
    if [ $AUTOSTART == true ]; then
        echo "$POSTINSTALL_UNLOAD_TEXT" >> $POSTINSTALL
        echo "$POSTINSTALL_AUTOSTART_TEXT" >> $POSTINSTALL
        echo "$POSTINSTALL_LOGROTATE_TEXT" >> $POSTINSTALL
    fi
  fi

  # Copy extra files to the install prefix so that they get packaged too.
  # NOTE: Files will be overwritten.
  for include_dir in ${OSQUERY_PKG_INCLUDE_DIRS[*]}; do
    log "adding $include_dir in the package prefix to be included in the package"
    cp -fR $include_dir/* $INSTALL_PREFIX/
  done
  chmod -fR o-rwx $INSTALL_PREFIX/*
  if [[ "$SIGN" = "1" ]]; then
    log "creating signed release package"
    pkgbuild --root $INSTALL_PREFIX       \
             --scripts $SCRIPT_ROOT       \
             --identifier $APP_IDENTIFIER \
             --version $APP_VERSION       \
             --sign "$INSTALLER_SIGNING_IDENTITY" \
             $KEYCHAIN_IDENTITY_COMMAND   \
             $OUTPUT_PKG_PATH 2>&1  1>/dev/null
  else
    log "creating package"
    pkgbuild --root $INSTALL_PREFIX       \
             --scripts $SCRIPT_ROOT       \
             --identifier $APP_IDENTIFIER \
             --version $APP_VERSION       \
             $OUTPUT_PKG_PATH 2>&1  1>/dev/null
  fi
  log "package created at $OUTPUT_PKG_PATH"

  log "creating debug package"
  pkgbuild --root $DEBUG_PREFIX               \
           --identifier $APP_IDENTIFIER.debug \
           --version $APP_VERSION             \
           $OUTPUT_DEBUG_PKG_PATH 2>&1  1>/dev/null
  log "package created at $OUTPUT_DEBUG_PKG_PATH"

}

main $@
