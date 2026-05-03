#!/bin/bash
set -e

cd /tmp
curl -qLs https://github.com/ewagner12/all-ways-egpu/releases/latest/download/all-ways-egpu.zip -o all-ways-egpu.zip
unzip -o all-ways-egpu.zip
cd all-ways-egpu-main
chmod +x install.sh
./install.sh

cd /tmp
rm -rf all-ways-egpu.zip all-ways-egpu-main
