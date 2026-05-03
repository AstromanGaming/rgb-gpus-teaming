sudo fpm -s dir -t deb \
  -n rgb-gpus-teaming \
  -v 1.0.0-main \
  --vendor "AstromanGaming" \
  --maintainer "Sam Bélanger <contact@astromangaming.ca>" \
  --license "MIT" \
  --url "https://github.com/AstromanGaming/rgb-gpus-teaming" \
  --description "A software for Multi-GPUs setup" \
  --architecture amd64 \
  --depends mesa-utils \
  --depends vulkan-tools \
  ./advisor.desktop=/usr/share/applications/ \
  ./advisor.sh=/opt/rgb-gpus-teaming/ \
  ./gnome-launcher.sh=/opt/rgb-gpus-teaming/ \
  ./gnome-setup.desktop=/usr/share/applications/ \
  ./gnome-setup.sh=/opt/rgb-gpus-teaming/ \
  ./LICENSE=/opt/rgb-gpus-teaming/ \
  ./manual-setup.desktop=/usr/share/applications/ \
  ./manual-setup.sh=/opt/rgb-gpus-teaming/ \
  ./gnome-extension=/usr/share/gnome-shell/extensions/ \
  ./nautilus-scripts=/usr/share/nautilus/scripts/

sudo fpm -s dir -t deb \
  -n rgb-gpus-teaming-egpu \
  -v 1.0.0-main \
  --after-install ./postinst.sh \
  --vendor "AstromanGaming" \
  --maintainer "Sam Bélanger <contact@astromangaming.ca>" \
  --license "MIT" \
  --url "https://github.com/AstromanGaming/rgb-gpus-teaming" \
  --description "A software for Multi-GPUs setup (all-ways-egpu Addon)" \
  --architecture amd64 \
  --depends rgb-gpus-teaming \
  --depends curl \
  --depends unzip \
  ./postinst.sh=/opt/rgb-gpus-teaming/ \
  ./all-ways-egpu-auto-setup.desktop=/usr/share/applications/ \
  ./all-ways-egpu-auto-setup.sh=/opt/rgb-gpus-teaming/
