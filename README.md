# rgb-gpus-teaming
The software for Multi-GPUs "Red team, Green team and Blue team" setup.

Info: For an eGPU setup, I strongly recommend using specialized software (such as all-ways-egpu) with this software.

Warning: Native support for X11 and Wayland is unknown at this time; only tested for Wayland with Xwayland.

### Installation (Tested on a Ubuntu 25.10):
```
sudo apt update
sudo apt install git mesa-utils 
```
```
git clone https://github.com/AstromanGaming/rgb-gpus-teaming.git
cd ./rgb-gpus-teaming
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
Note: 

- "sudo pkill -KILL -u your_username" is important for refresh the new or the upgraded installation! 
- With the GUI, just click "logout".

# Usages

Advisor: 
It's a tool that provides advice for graphics cards and how to use them.

Manual Setup:
This is the manual method for selecting your graphics card for an application or command.

Gnome Setup:
This is the method for choosing your graphics card for an application in the GNOME desktop environment.

## CLI/Shell

### Advisor:
```
~/rgb-gpus-teaming/advisor.sh
```
### Manual Setup:
```
~/rgb-gpus-teaming/manual-setup.sh
```
### Gnome Setup:
```
~/rgb-gpus-teaming/gnome-setup.sh
```

## GUI
### For GNOME:
- Click on the relevant .desktop icons to use them.
- Right-click on a .desktop application and click “Launch with RGB GPUs Teaming”.

### For Nautilus:
- Right-click on a file, click Scripts, then click “Launch with RGB GPUs Teaming”.
