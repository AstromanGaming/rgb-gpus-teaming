##

# <p align="center"><strong>![RGB GPUs Teaming](logo.png)</strong></p>

###

# <p align="center">The software for work Multi-GPUs “Red team, Green team and Blue team” setup together!</p>

## $${\color{blue}Info:}$$
<p align="left"><em>For an eGPU setup, I strongly recommend using specialized software (such as <a href="https://github.com/ewagner12/all-ways-egpu" target="_blank">all-ways-egpu</a>) with this software.</em></p>

#

## $${\color{red}Warning:}$$ 
<p align="left"><em>Native support for X11 and Wayland is unknown at this time; only tested for Wayland with Xwayland.</em></p>

#

### Installation

##

#### To begin:

##### Per Linux Distro

###### Debian/Ubuntu/Linux Mint
```
sudo apt update
sudo apt install git mesa-utils 
```

###### Arch Linux/Manjaro/SteamOS (Experimental)
```
sudo pacman -Syu
sudo pacman -S git mesa-utils
```

###### Fedora/RHEL (Experimental)
```
sudo dnf update
sudo dnf install git mesa-demos
```

##### Downloading Methodes

###### Git
```
git clone https://github.com/AstromanGaming/RGB-GPUs-Teaming.OP.git
cd ./RGB-GPUs-Teaming.OP
```
#### For installing:
```
./install-rgb-gpus-teaming.sh
sudo pkill -KILL -u your_username
```
#### For upgrade:
```
./update-rgb-gpus-teaming.sh
sudo pkill -KILL -u your_username
```
#### For uninstalling:
```
./uninstall-rgb-gpus-teaming.sh
sudo pkill -KILL -u your_username
```

#### For specific uses:

##

##### Definitions

## 

###### Advisor:

- This tool provides insight into the installed GPUs by listing them according to their PCIe bus hierarchy, allowing users to understand which card is primary, secondary, or tertiary, and configure usage modes accordingly.

###

###### Manual Setup:
  
- This manual method use to choose exactly which GPU runs your app or command. Perfect when you’ve got multiple graphics cards and want to decide who does the heavy lifting.

###

###### Gnome Setup:
  
- This method lets you select which graphics card to use for a specific application within the GNOME desktop environment. It integrates seamlessly with GNOME’s interface, making GPU assignment simple and intuitive for everyday use.

###

##

##### CLI/Shell

##

###### Advisor:
```
~/RGB-GPUs-Teaming.OP/advisor.sh
```
###### Manual Setup:
```
~/RGB-GPUs-Teaming.OP/manual-setup.sh
```
###### Gnome Setup:
```
~/RGB-GPUs-Teaming.OP/gnome-setup.sh
```

##

##### GUI

##

###### For GNOME:
- Click on the relevant .desktop icons to use them.
- Right-click on a .desktop application and click “Launch with RGB GPUs Teaming”.

###### For KDE:
- N/A

###### For Cinnamon:
- N/A

###### For LXQt:
- N/A

##

##### File Manager

##

###### For Nautilus:
- Right-click on a file, click Scripts, then click “Launch with RGB GPUs Teaming”.

###### For Nemo:
- N/A

##

### Notes
- ```sudo pkill -KILL -u your_username``` is important for refresh the new or the upgraded installation!
- With the GUI, just click “Sign out”.

##

# <p align="center"><strong>![Thanks you for reading this project!](logo2.png)</strong></p>
