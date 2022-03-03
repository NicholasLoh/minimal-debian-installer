#!/usr/bin/env bash
Name="not-so-minimal-debian.sh"

# Copyright (c) 2021 Daniel Wayne Armstrong. All rights reserved.

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE. See the LICENSE file for more details.

set -euo pipefail # run `bash -x not-so-minimal-debian.sh` for debugging

Version="11"
Release="bullseye" 

USER_HOME="/home/$USER"

hello_world() {
clear
banner "START"
cat << _EOF_
*$Name* is a script for configuring Debian GNU/Linux.
It is ideally run after the first boot into a minimal install [1] of
Debian $Version aka "$Release".

[1] https://www.dwarmstrong.org/minimal-debian/

_EOF_
}

run_options() {
    while getopts ":h" OPT
    do
        case $OPT in
        h)
            hello_world
            exit
            ;;
        ?)
            err "Invalid option ${OPTARG}."
            exit 1
            ;;
        esac
    done
}

invalid_reply() {
  printf "\nInvalid reply.\n\n"
}

run_script() {
while :
  do
      read -r -n 1 -p "Run script now? [yN] > "
      if [[ "$REPLY" == [yY] ]]; then
          break
      elif [[ "$REPLY" == [nN] || "$REPLY" == "" ]]; then
          echo ""
          exit
      else
          invalid_reply
      fi
  done
}

# ANSI escape codes
RED="\\033[1;31m"
GREEN="\\033[1;32m"
YELLOW="\\033[1;33m"
PURPLE="\\033[1;35m"
NC="\\033[0m" # no colour

echo_red() {
  echo -e "${RED}$1${NC}"
}

echo_green() {
  echo -e "${GREEN}$1${NC}"
}

echo_yellow() {
  echo -e "${YELLOW}$1${NC}"
}

echo_purple() {
  echo -e "${PURPLE}$1${NC}"
}

banner() {
  printf "\n\n========> $1\n\n"
}

bak_file() {
  for f in "$@"; do cp "$f" "$f.$(date +%FT%H%M%S).bak"; done
}

verify_root() {
  if (( EUID != 0 )); then
      printf "\n\nScript must be run with root privileges. Abort.\n"
      exit 1
  fi
}

verify_version() {
  local version
  version="$(grep VERSION_ID /etc/os-release | egrep -o '[[:digit:]]{2}')"
  if [[ $version == "$Version" ]]; then
      :
  else
      echo $version
      printf "\n\nScript for Debian $Version stable/$Release only. Abort.\n"
      exit 1
  fi
}

verify_homedir() {
# $1 is $USER
  if [[ "$#" -eq 0 ]]; then
      printf "\n\nNo username provided. Abort.\n"
      exit 1
  elif [[ ! -d "/home/$1" ]]; then
      printf "\n\nA home directory for $1 not found. Abort.\n"
      exit 1
  fi
}


config_consolefont() {
banner "Configure console font"
local file
file="/etc/default/console-setup"
dpkg-reconfigure console-setup
grep FONTFACE $file
grep FONTSIZE $file
}

config_keyboard() {
banner "Configure keyboard"
local file
file="/etc/default/keyboard"
dpkg-reconfigure keyboard-configuration
setupcon
grep XKB $file
}

config_apt_sources() {
banner "Configure apt sources.list"
# Add backports repository, update package list, upgrade packages.
local file
file="/etc/apt/sources.list"
local mirror
mirror="http://deb.debian.org/debian/"
local sec_mirror
sec_mirror="http://security.debian.org/debian-security"
local repos
repos="main contrib non-free"
# Backup previous config
bak_file $file
# Create a new config
cat << _EOL_ > $file
deb $mirror $Release $repos
#deb-src $mirror $Release $repos

deb $sec_mirror ${Release}-security $repos
#deb-src $sec_mirror ${Release}-security $repos

deb $mirror ${Release}-updates $repos
#deb-src $mirror ${Release}-updates $repos

deb $mirror ${Release}-backports $repos
#deb-src $mirror ${Release}-backports $repos
_EOL_
# Update/upgrade
cat $file
echo ""
echo "Update list of packages available and upgrade $HOSTNAME ..."
apt-get update && apt-get -y dist-upgrade
}

config_ssh() {
banner "Create SSH directory for $User"
apt-get -y install openssh-server keychain
# Install SSH server and create $HOME/.ssh.
# See https://www.dwarmstrong.org/ssh-keys/
local ssh_dir
ssh_dir="/home/${User}/.ssh"
local auth_key
auth_key="${ssh_dir}/authorized_keys"
# Create ~/.ssh
if [[ -d "$ssh_dir" ]]; then
    echo ""
    echo "SSH directory $ssh_dir already exists. Skipping ..."
else
    mkdir $ssh_dir && chmod 700 $ssh_dir && touch $auth_key
    chmod 600 $auth_key && chown -R ${User}: $ssh_dir
fi
}

config_sudo() {
banner "Configure sudo"
apt-get -y install sudo
# Add config file to /etc/sudoers.d/ to allow $User to
# run any command without a password.
local file
file="/etc/sudoers.d/sudoers_${User}"
if [[ -f "$file" ]]; then
    echo ""
    echo "$file already exists. Skipping ..."
else
    echo "$User ALL=(ALL) NOPASSWD: ALL" > $file
    usermod -aG sudo $User
fi
}

config_sysctl() {
banner "Configure sysctl"
local sysctl
sysctl="/etc/sysctl.conf"
local dmesg
dmesg="kernel.dmesg_restrict = 0"
if grep -q "$dmesg" "$sysctl"; then
    echo "Option $dmesg already set. Skipping ..."
else
    bak_file $sysctl
    cat << _EOL_ >> $sysctl

# Allow non-root access to dmesg
$dmesg
_EOL_
    # Reload configuration.
    sysctl -p
fi
}

config_grub() {
banner "Configure GRUB"
local file
file="/etc/default/grub"
local custom_cfg
custom_cfg="/boot/grub/custom.cfg"
# Backup configs
bak_file $file
if [[ -f "$custom_cfg" ]]; then
    bak_file $custom_cfg
fi
# Configure default/grub
if ! grep -q ^GRUB_DISABLE_SUBMENU "$file"; then
    cat << _EOL_ >> $file

# Kernel list as a single menu
GRUB_DISABLE_SUBMENU=y
_EOL_
fi
# Menu colours
cat << _EOL_ > $custom_cfg
set color_normal=white/black
set menu_color_normal=white/black
set menu_color_highlight=white/green
_EOL_
# Apply changes
update-grub
}

config_trim() {
banner "TRIM"
# Enable a weekly task that discards unused blocks on the drive.
systemctl enable fstrim.timer
systemctl status fstrim.timer | grep Active
}

install_microcode() {
banner "Install microcode"
# Intel and AMD processors may periodically need updates to their microcode
# firmware. Microcode can be updated (and kept in volatile memory) during
 # boot by installing either intel-microcode or amd64-microcode (AMD).
local file
file="/proc/cpuinfo"
if grep -q GenuineIntel "$file"; then
    apt-get -y install intel-microcode
elif grep -q AuthenticAMD "$file"; then
    apt-get -y install amd64-microcode
fi
}

install_console_pkgs() {
banner "Install console packages"
local pkg_tools
pkg_tools="apt-file apt-show-versions apt-utils aptitude command-not-found "
local build_tools
build_tools="build-essential meson ninja-build autoconf automake checkinstall libtool "
local console
console="zsh cryptsetup curl firmware-misc-nonfree git gnupg stow "
console+="keychain libncurses-dev neofetch "
console+="net-tools nmap openssh-server rsync wireshark "
console+="unzip wget whois zram-tools "
apt-get -y install $pkg_tools $build_tools $console
apt-file update && update-command-not-found
 
banner "Install youtube downloader"
sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp
sudo chmod a+rx /usr/local/bin/yt-dlp

banner "Setting zsh as default shell"
chsh -s /bin/zsh
}

install_unattended_upgrades() {
banner "Configure unattend-upgrades"
# Install security updates automatically courtesy of `unattended-upgrades`.
# See https://www.dwarmstrong.org/unattended-upgrades/
local file
file="/etc/apt/apt.conf.d/50unattended-upgrades"
local auto_file
auto_file="/etc/apt/apt.conf.d/20auto-upgrades"
# Install
apt-get -y install unattended-upgrades
# Enable *-updates and *-proposed-updates.
sed -i '29,30 s://::' $file
# Enable *-backports.
sed -i '42 s://::' $file
# Send email to root concerning any problems or packages upgrades.
sed -i \
's#//Unattended-Upgrade::Mail \"\";#Unattended-Upgrade::Mail \"root\";#' $file
# Remove unused packages after the upgrade (equivalent to apt-get autoremove).
sed -i '111 s://::' $file
sed -i '111 s:false:true:' $file
# If an upgrade needs to reboot the device, reboot at a specified time
# instead of immediately.
sed -i '124 s://::' $file
# Automatically download and install stable updates (0=disabled, 1=enabled).
cat << _EOL_ > $auto_file
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
_EOL_
}

install_xorg() {
  banner "Install Xorg"
  local xorg
  xorg="xorg xbacklight xbindkeys xvkbd xinput xserver-xorg-input-all "
  local fonts
  fonts="fonts-dejavu fonts-firacode fonts-liberation2 fonts-jetbrains-mono fonts-noto-cjk fonts-font-awesome "
  apt-get -y install $xorg $fonts

}

install_i3() {
  banner "Install LightDM"
  apt-get -y install lightdm

  banner "Install i3 window manager "
  local pkgs
  pkgs="dh-autoreconf libxcb-keysyms1-dev libpango1.0-dev libxcb-util0-dev xcb libxcb1-dev libxcb-icccm4-dev libyajl-dev libev-dev libxcb-xkb-dev libxcb-cursor-dev libxkbcommon-dev libxcb-xinerama0-dev libxkbcommon-x11-dev libstartup-notification0-dev libxcb-randr0-dev libxcb-xrm0 libxcb-xrm-dev libxcb-shape0 libxcb-shape0-dev"
    apt-get -y install $pkgs

    git clone https://www.github.com/Airblader/i3 i3-gaps
    cd i3-gaps

    mkdir -p build && cd build
    meson --prefix /usr/local
    ninja
    ninja install
    cd ~
}

install_desktop_env_pkgs() {
    local pkgs
    pkgs+="dunst dbus-x11 feh nitrogen xdotool xclip "
    pkgs+="pavucontrol-qt network-manager gir1.2-nm-1.0 "
    pkgs+="pulseaudio pulseaudio-utils rofi polybar starship ranger "
    apt-get -y install $pkgs
  }


install_desktop_pkgs() {
  banner "Install desktop packages"
  local pkgs
  pkgs="build-essential firefox-esr "
  pkgs+="ffmpeg gimp gimp-help-en gimp-data-extras audacity jmtpfs "
  pkgs+="lm-sensors htop "
  pkgs+="vlc kitty yad thunar "
  apt-get -y install $pkgs
 }

install_devtools() {
  banner "Install dev tools"    
  local pkgs
  pkgs="default-jre python3 python3-pip nodejs yarn neovim "
  banner "Install nodejs"    
  curl -fsSL https://deb.nodesource.com/setup_16.x | bash -
  banner "Install yarn"    
  curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
  apt-get -y install $pkgs
}

install_bluetooth() {
  git clone https://github.com/linuxmint/blueberry.git
  cd blueberry && mint-build
  cd .. && sudo dpkg -i blueberry\*.deb
  
  rm -rf blueberry
  }

install_dotfiles() {

  su ${User}

  cd /home/${User}
  banner "Install DeJavuSansMono Nerd Font"
  wget 'https://github.com/ryanoasis/nerd-fonts/releases/download/v2.1.0/DejaVuSansMono.zip'
  unzip DejaVuSansMono.zip -d DejaVuSansMono 
  mkdir -p ~/.local/share/fonts
  cp -r DejaVuSansMono ~/.local/share/fonts/
  rm -rf DejaVuSansMono
  rm DejaVuSansMono.zip

  banner "Installing dotfiles"
  git clone https://github.com/NicholasLoh/.dotfiles.git
  cd .dotfiles
  chmod +x install.sh
  ./install.sh
  }

i3_profile() {
install_xorg
install_i3
install_devtools
install_desktop_env_pkgs
install_desktop_pkgs
install_dotfiles
}

config_update_alternatives() {
banner "Configure default commands"
update-alternatives --config editor
}

go_or_no_go() {
local Num
Num="5"
local User
User="foo"
local Sudo
Sudo="no"
local Profile
Profile="i3"
local Auto_update
Auto_update="no"
local Kbd
Kbd="no"
local Font
Font="no"
local Ssd
Ssd="no"
local Grub
Grub="no"
local Sync
Sync="no"

while :
do
    banner "Question 1 of $Num"
    read -r -p "What is your non-root username? > "
    User=$REPLY
    verify_homedir $User

    banner "Question 2 of $Num"
    local sudo_msg
    sudo_msg="Allow $User to use 'sudo' to execute any command "
    sudo_msg+="without a password?"
    while :
    do
        read -r -n 1 -p "$sudo_msg [Yn] > "
        if [[ "$REPLY" == [nN] ]]; then
            break
        elif [[ "$REPLY" == [yY] || "$REPLY" == "" ]]; then
            Sudo="yes"
            break
        else
            invalid_reply
        fi
    done

    banner "Question 3 of $Num"
    while :
    do
        echo "Automatically fetch and install the latest security fixes "
        echo "(unattended-upgrades(8)). Useful especially on servers."
        echo ""
        read -r -n 1 -p "Auto-install security updates? [Yn] > "
        if [[ "$REPLY" == [nN] ]]; then
            break
        elif [[ "$REPLY" == [yY] || "$REPLY" == "" ]]; then
            Auto_update="yes"
            break
        else
            invalid_reply
        fi
    done

   banner "Question 4 of $Num"
    while :
    do
        echo "Periodic TRIM optimizes performance on solid-state"
        echo "storage. If this machine has an SSD drive, you"
        echo "should enable this task."
        echo ""
        read -r -n 1 -p "Discard unused blocks? [Yn] > "
        if [[ "$REPLY" == [nN] ]]; then
            break
        elif [[ "$REPLY" == [yY] || "$REPLY" == "" ]]; then
            Ssd="yes"
            break
        else
            invalid_reply_yn
        fi
    done

    banner "Question 5 of $Num"
    echo_purple "Username: $User"
    echo_purple "Profile: $Profile"
    if [[ "$Sudo" == "yes" ]]; then
        echo_green "Sudo without password: $Sudo"
    else
        echo_red "Sudo without password: $Sudo"
    fi
    if [[ "$Auto_update" == "yes" ]]; then
        echo_green "Automatic Updates: $Auto_update"
    else
        echo_red "Automatic Updates: $Auto_update"
    fi
    if [[ "$Kbd" == "yes" ]]; then
        echo_green "Configure Keyboard: $Kbd"
    else
        echo_red "Configure Keyboard: $Kbd"
    fi
    if [[ "$Font" == "yes" ]]; then
        echo_green "Configure Font: $Font"
    else
        echo_red "Configure Font: $Font"
    fi
    if [[ "$Ssd" == "yes" ]]; then
        echo_green "TRIM: $Ssd"
    else
        echo_red "TRIM: $Ssd"
    fi
    if [[ "$Grub" == "yes" ]]; then
        echo_green "Custom GRUB: $Grub"
    else
        echo_red "Custom GRUB: $Grub"
    fi
    if [[ "$Sync" == "yes" ]]; then
        echo_green "Syncthing: $Sync"
    else
        echo_red "Syncthing: $Sync"
    fi
    echo ""
    read -r -n 1 -p "Is this correct? [Yn] > "
    if [[ "$REPLY" == [yY] || "$REPLY" == "" ]]; then
        printf "\n\nOK ... Let's roll ...\n"
        break
    elif [[ "$REPLY" == [nN] ]]; then
        printf "\n\nOK ... Let's try again ...\n"
    else
        invalid_reply
    fi
done

if [[ "$Font" == "yes" ]]; then
    config_consolefont || true # continue even if exit is not 0
fi
if [[ "$Kbd" == "yes" ]]; then
    config_keyboard || true
fi
config_apt_sources
config_ssh
if [[ "$Sudo" == "yes" ]]; then
    config_sudo
fi
config_sysctl
if [[ "$Grub" == "yes" ]]; then
    config_grub
fi
if [[ "$Ssd" == "yes" ]]; then
    config_trim
fi
install_microcode
install_console_pkgs
if [[ "$Auto_update" == "yes" ]]; then
    install_unattended_upgrades
fi
i3_profile
config_update_alternatives
}

au_revoir() {
local message
message="Done! Debian is ready. Happy hacking!"
}

# (O<  Let's go!
# (/)_
run_options "$@"
verify_root
hello_world
run_script
verify_version
go_or_no_go
au_revoir
exit 0
