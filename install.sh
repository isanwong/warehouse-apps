#!/bin/bash

set -e

if [ "$1" = "" ]
then
  echo >&2 usage: $0 install_base_dir
  exit 1
fi

(
 cd libwarehouse-perl
 ./build_deb.sh
)

(
 ln -sfn "$1" install
 ./projects/polony/tests/autotests.sh
)
